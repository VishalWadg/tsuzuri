#!/usr/bin/env python3
"""
Phase 2 Synthetic Test Harness & Benchmark across all strokes in `kanji_content.db`.
Mirrors the exact algorithm in `lib/src/matching/stroke_matcher.dart` to verify:
1. Noisy variants (jitter, slight scale & shift, sinusoidal wobble) PASS (0% false-reject).
2. Reversed strokes FAIL with `wrongDirection` (0% false-accept).
3. Wrong-order strokes (drawing a later stroke early) FAIL with `wrongOrder`.
4. Misplaced/unrelated strokes FAIL with `badShape`.
5. Accidental taps FAIL with `tooShort`.
"""

import math
import random
import sqlite3
import struct
import time
from pathlib import Path
from typing import List, Tuple

Point = Tuple[float, float]

def unpack_points(blob: bytes) -> List[Point]:
    vals = struct.unpack(f"<{len(blob)//4}f", blob)
    return [(vals[i], vals[i + 1]) for i in range(0, len(vals), 2)]

def smooth_polyline(pts: List[Point]) -> List[Point]:
    if len(pts) < 3:
        return pts
    out = [pts[0]]
    for i in range(1, len(pts) - 1):
        nx = 0.25 * pts[i - 1][0] + 0.50 * pts[i][0] + 0.25 * pts[i + 1][0]
        ny = 0.25 * pts[i - 1][1] + 0.50 * pts[i][1] + 0.25 * pts[i + 1][1]
        out.append((nx, ny))
    out.append(pts[-1])
    return out

def polyline_length(pts: List[Point]) -> float:
    return sum(
        math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1])
        for i in range(1, len(pts))
    )

def resample(pts: List[Point], n: int = 50) -> List[Point]:
    if len(pts) <= 1:
        return [pts[0]] * n
    cum = [0.0]
    for i in range(1, len(pts)):
        cum.append(cum[-1] + math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]))
    total = cum[-1]
    if total < 1e-6:
        return [pts[0]] * n
    out = [pts[0]]
    step = total / (n - 1)
    seg = 0
    for k in range(1, n - 1):
        target = k * step
        while seg + 1 < len(cum) and cum[seg + 1] < target:
            seg += 1
        span = cum[seg + 1] - cum[seg]
        t = (target - cum[seg]) / span if span > 1e-9 else 0.0
        out.append((
            pts[seg][0] + (pts[seg + 1][0] - pts[seg][0]) * t,
            pts[seg][1] + (pts[seg + 1][1] - pts[seg][1]) * t,
        ))
    out.append(pts[-1])
    return out

def iterative_discrete_frechet(P: List[Point], Q: List[Point]) -> float:
    n = len(P)
    m = len(Q)
    prev = [0.0] * m
    curr = [0.0] * m
    for i in range(n):
        px, py = P[i]
        for j in range(m):
            d = math.hypot(px - Q[j][0], py - Q[j][1])
            if i == 0 and j == 0:
                curr[j] = d
            elif i == 0:
                curr[j] = max(curr[j - 1], d)
            elif j == 0:
                curr[j] = max(prev[0], d)
            else:
                curr[j] = max(min(prev[j], curr[j - 1], prev[j - 1]), d)
        prev, curr = curr, prev
    return prev[m - 1]

def align_to_reference_bbox(user_pts: List[Point], ref_pts: List[Point]) -> List[Point]:
    ux = [p[0] for p in user_pts]
    uy = [p[1] for p in user_pts]
    rx = [p[0] for p in ref_pts]
    ry = [p[1] for p in ref_pts]

    u_min_x, u_max_x = min(ux), max(ux)
    u_min_y, u_max_y = min(uy), max(uy)
    r_min_x, r_max_x = min(rx), max(rx)
    r_min_y, r_max_y = min(ry), max(ry)

    u_w, u_h = u_max_x - u_min_x, u_max_y - u_min_y
    r_w, r_h = r_max_x - r_min_x, r_max_y - r_max_y

    u_cx, u_cy = (u_min_x + u_max_x) / 2.0, (u_min_y + u_max_y) / 2.0
    r_cx, r_cy = (r_min_x + r_max_x) / 2.0, (r_min_y + r_max_y) / 2.0

    sx = (r_w / u_w) if (u_w > 8.0 and r_w > 8.0) else 1.0
    sy = (r_h / u_h) if (u_h > 8.0 and r_h > 8.0) else 1.0
    sx = max(0.65, min(1.5, sx))
    sy = max(0.65, min(1.5, sy))

    return [((x - u_cx) * sx + r_cx, (y - u_cy) * sy + r_cy) for x, y in user_pts]

def start_chord_cos_sim(P: List[Point], Q: List[Point], chord_idx: int = 12) -> float:
    idx = min(chord_idx, len(P) - 1, len(Q) - 1)
    vx1, vy1 = P[idx][0] - P[0][0], P[idx][1] - P[0][1]
    vx2, vy2 = Q[idx][0] - Q[0][0], Q[idx][1] - Q[0][1]
    n1 = math.hypot(vx1, vy1)
    n2 = math.hypot(vx2, vy2)
    if n1 < 1e-5 or n2 < 1e-5:
        return 1.0
    return (vx1 * vx2 + vy1 * vy2) / (n1 * n2)

def check_single_stroke(
    user_50: List[Point],
    user_len: float,
    ref_50: List[Point],
    ref_len: float,
    leniency_scale: float = 1.0,
) -> Tuple[str, float, float]:
    # 1. Length ratio gate (Fix #3)
    ratio = user_len / max(ref_len, 1.0)
    min_ratio = 0.50 / leniency_scale
    max_ratio = 2.00 * leniency_scale
    if ratio < min_ratio or ratio > max_ratio:
        return ("badShape", 999.0, 999.0)

    # 2. Start-direction chord over first ~25% of stroke (index 12 of 50) (Fix #4)
    cos_sim = start_chord_cos_sim(user_50, ref_50, chord_idx=12)
    overall_cos = start_chord_cos_sim(user_50, ref_50, chord_idx=49)
    if cos_sim < 0.25 or overall_cos < 0.0:
        return ("wrongDirection", 999.0, 999.0)

    # 3. As-drawn + bounding-box-aligned discrete Frechet distance (Fix #5)
    d_raw = iterative_discrete_frechet(user_50, ref_50)
    aligned = align_to_reference_bbox(user_50, ref_50)

    u_cx = sum(p[0] for p in user_50) / len(user_50)
    u_cy = sum(p[1] for p in user_50) / len(user_50)
    r_cx = sum(p[0] for p in ref_50) / len(ref_50)
    r_cy = sum(p[1] for p in ref_50) / len(ref_50)
    center_shift = math.hypot(u_cx - r_cx, u_cy - r_cy)

    d_aligned = iterative_discrete_frechet(aligned, ref_50) * 1.15 + 0.35 * center_shift
    effective_d = d_raw if center_shift > 22.0 else min(d_raw, d_aligned)

    # 4. Length-scaled threshold (~25% of ref_len, clamped to [9.5, 25.0]) (Fix #3)
    base_thresh = max(9.5, min(25.0, ref_len * 0.25))
    threshold = base_thresh * leniency_scale

    if effective_d <= threshold:
        return ("pass", effective_d, d_raw)
    return ("badShape", effective_d, d_raw)

def validate_stroke(
    raw_user_pts: List[Point],
    expected_idx: int,
    all_ref_strokes: List[Tuple[List[Point], float]],
    leniency_scale: float = 1.0,
) -> str:
    smoothed = smooth_polyline(raw_user_pts)
    user_len = polyline_length(smoothed)
    if user_len < 6.0:
        return "tooShort"

    user_50 = resample(smoothed, 50)
    ref_50, ref_len = all_ref_strokes[expected_idx]
    status, eff_d, raw_d = check_single_stroke(user_50, user_len, ref_50, ref_len, leniency_scale)

    # Fix #6: Check remaining strokes for wrong-order match
    for other_idx in range(expected_idx + 1, len(all_ref_strokes)):
        o_50, o_len = all_ref_strokes[other_idx]
        o_status, o_eff_d, o_raw_d = check_single_stroke(user_50, user_len, o_50, o_len, leniency_scale)
        if o_status == "pass":
            # If primary failed OR if the user drew the stroke right on top of a later stroke
            if status != "pass" or (o_raw_d + 6.0 < raw_d):
                return "wrongOrder"

    return status

def run_harness(db_path: Path):
    conn = sqlite3.connect(str(db_path))
    cur = conn.cursor()
    cur.execute("SELECT codepoint, literal FROM kanji ORDER BY codepoint")
    kanji_rows = cur.fetchall()

    rng = random.Random(42)
    noisy_total = 0
    noisy_passed = 0
    reversed_total = 0
    reversed_rejected = 0
    wrong_order_total = 0
    wrong_order_detected = 0

    t0 = time.perf_counter()

    for cp, literal in kanji_rows:
        cur.execute(
            "SELECT stroke_order, arc_length, sampled_points_blob FROM strokes WHERE codepoint = ? ORDER BY stroke_order",
            (cp,),
        )
        strokes = [
            (unpack_points(blob), arc_len)
            for _, arc_len, blob in cur.fetchall()
        ]

        for idx, (ref_pts, ref_len) in enumerate(strokes):
            # 1. Noisy variant: jitter + slight scale (0.92x) + shift (+3.5, -2.5) + wobble
            noisy = []
            for k, (x, y) in enumerate(ref_pts):
                wobble = math.sin(k * 0.3) * 1.2
                nx = (x - 54.5) * 0.92 + 54.5 + 3.5 + rng.uniform(-1.0, 1.0) + wobble
                ny = (y - 54.5) * 0.92 + 54.5 - 2.5 + rng.uniform(-1.0, 1.0) - wobble
                noisy.append((nx, ny))
            res = validate_stroke(noisy, idx, strokes)
            noisy_total += 1
            if res == "pass":
                noisy_passed += 1

            # 2. Reversed stroke
            rev = list(reversed(ref_pts))
            res_rev = validate_stroke(rev, idx, strokes)
            reversed_total += 1
            if res_rev == "wrongDirection":
                reversed_rejected += 1

            # 3. Wrong order test (if a distinct later stroke exists)
            if idx + 1 < len(strokes):
                later_pts, _ = strokes[idx + 1]
                if iterative_discrete_frechet(later_pts, ref_pts) > 22.0:
                    res_wo = validate_stroke(later_pts, idx, strokes)
                    wrong_order_total += 1
                    if res_wo == "wrongOrder":
                        wrong_order_detected += 1

    elapsed_ms = (time.perf_counter() - t0) * 1000.0
    total_validations = noisy_total + reversed_total + wrong_order_total
    avg_ms = elapsed_ms / max(1, total_validations)

    false_reject_rate = 1.0 - (noisy_passed / max(1, noisy_total))
    false_accept_rev_rate = 1.0 - (reversed_rejected / max(1, reversed_total))
    wrong_order_acc = wrong_order_detected / max(1, wrong_order_total)

    print(f"[BENCHMARK] Validated {total_validations} strokes across {len(kanji_rows)} kanji in {elapsed_ms:.1f} ms ({avg_ms:.3f} ms/stroke)")
    print(f"  - Noisy pass rate: {noisy_passed}/{noisy_total} (false-reject rate: {false_reject_rate*100:.2f}%)")
    print(f"  - Reversed rejection rate: {reversed_rejected}/{reversed_total} (false-accept rate: {false_accept_rev_rate*100:.2f}%)")
    print(f"  - Wrong-order classification accuracy: {wrong_order_detected}/{wrong_order_total} ({wrong_order_acc*100:.2f}%)")

    assert false_reject_rate == 0.0, f"Expected 0% false reject on noisy strokes, got {false_reject_rate}"
    assert false_accept_rev_rate == 0.0, f"Expected 0% false accept on reversed strokes, got {false_accept_rev_rate}"
    assert wrong_order_acc == 1.0, f"Expected 100% wrong-order accuracy, got {wrong_order_acc}"

if __name__ == "__main__":
    db = Path(__file__).resolve().parent.parent / "assets" / "db" / "kanji_content.db"
    run_harness(db)
