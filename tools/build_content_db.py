#!/usr/bin/env python3
"""
Phase 1 Content Pipeline: Parses KANJIDIC2 XML and KanjiVG SVG files into a
prebuilt, version-stamped SQLite database (`assets/db/kanji_content.db`).

Fixes implemented from the Approach Plan:
- Fix #1 & #2: Read-only content DB separate from user progress DB; keyed by Unicode codepoint.
- Fix #7: Precomputes 50 arc-length-sampled points per stroke at build time and stores them
  as a compact 400-byte float32 binary blob alongside the raw SVG path string.
- Fix #12 & #13: Stamps the content DB with a deterministic version + build metadata, and
  runs validation checks (no kanji without strokes, stroke count matches KANJIDIC2, no NaN/empty points).
"""

import argparse
import json
import math
import os
import re
import sqlite3
import struct
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import List, Tuple, Dict, Optional

CONTENT_DB_VERSION = 20260101
NUM_SAMPLE_POINTS = 50
CANVAS_BOX_SIZE = 109.0

# ---------------------------------------------------------------------------
# SVG Path Parser & Cubic Bezier Arc-Length Sampler (Pure Python, Zero Deps)
# ---------------------------------------------------------------------------

TOKEN_RE = re.compile(r"([MmLlHhVvCcSsZz])|([-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)")

def tokenize_svg_path(d: str) -> List[str]:
    tokens = []
    for match in TOKEN_RE.finditer(d):
        cmd, num = match.groups()
        tokens.append(cmd if cmd is not None else num)
    return tokens

def eval_cubic_bezier(
    p0: Tuple[float, float],
    p1: Tuple[float, float],
    p2: Tuple[float, float],
    p3: Tuple[float, float],
    t: float,
) -> Tuple[float, float]:
    u = 1.0 - t
    tt = t * t
    uu = u * u
    uuu = uu * u
    ttt = tt * t
    x = uuu * p0[0] + 3.0 * uu * t * p1[0] + 3.0 * u * tt * p2[0] + ttt * p3[0]
    y = uuu * p0[1] + 3.0 * uu * t * p1[1] + 3.0 * u * tt * p2[1] + ttt * p3[1]
    return (x, y)

def densify_svg_path(d: str, steps_per_curve: int = 32) -> List[Tuple[float, float]]:
    """
    Evaluates an SVG path string (supporting M, m, L, l, H, h, V, v, C, c, S, s, Z, z)
    into a dense polyline in the 109x109 KanjiVG coordinate space.
    """
    tokens = tokenize_svg_path(d)
    points: List[Tuple[float, float]] = []
    cx, cy = 0.0, 0.0
    start_x, start_y = 0.0, 0.0
    prev_ctrl: Optional[Tuple[float, float]] = None
    i = 0
    cmd = ""

    def next_float() -> float:
        nonlocal i
        val = float(tokens[i])
        i += 1
        return val

    while i < len(tokens):
        if tokens[i].isalpha():
            cmd = tokens[i]
            i += 1
        if cmd in ("M", "m"):
            dx, dy = next_float(), next_float()
            cx = dx if cmd == "M" else cx + dx
            cy = dy if cmd == "M" else cy + dy
            start_x, start_y = cx, cy
            points.append((cx, cy))
            prev_ctrl = None
            cmd = "L" if cmd == "M" else "l"
        elif cmd in ("L", "l"):
            dx, dy = next_float(), next_float()
            nx = dx if cmd == "L" else cx + dx
            ny = dy if cmd == "L" else cy + dy
            for step in range(1, 9):
                t = step / 8.0
                points.append((cx + (nx - cx) * t, cy + (ny - cy) * t))
            cx, cy = nx, ny
            prev_ctrl = None
        elif cmd in ("H", "h"):
            dx = next_float()
            nx = dx if cmd == "H" else cx + dx
            for step in range(1, 9):
                t = step / 8.0
                points.append((cx + (nx - cx) * t, cy))
            cx = nx
            prev_ctrl = None
        elif cmd in ("V", "v"):
            dy = next_float()
            ny = dy if cmd == "V" else cy + dy
            for step in range(1, 9):
                t = step / 8.0
                points.append((cx, cy + (ny - cy) * t))
            cy = ny
            prev_ctrl = None
        elif cmd in ("C", "c"):
            x1, y1 = next_float(), next_float()
            x2, y2 = next_float(), next_float()
            x3, y3 = next_float(), next_float()
            if cmd == "c":
                x1, y1 = cx + x1, cy + y1
                x2, y2 = cx + x2, cy + y2
                x3, y3 = cx + x3, cy + y3
            p0 = (cx, cy)
            p1 = (x1, y1)
            p2 = (x2, y2)
            p3 = (x3, y3)
            for step in range(1, steps_per_curve + 1):
                points.append(eval_cubic_bezier(p0, p1, p2, p3, step / steps_per_curve))
            cx, cy = x3, y3
            prev_ctrl = p2
        elif cmd in ("S", "s"):
            x2, y2 = next_float(), next_float()
            x3, y3 = next_float(), next_float()
            if cmd == "s":
                x2, y2 = cx + x2, cy + y2
                x3, y3 = cx + x3, cy + y3
            if prev_ctrl is not None:
                x1 = 2.0 * cx - prev_ctrl[0]
                y1 = 2.0 * cy - prev_ctrl[1]
            else:
                x1, y1 = cx, cy
            p0 = (cx, cy)
            p1 = (x1, y1)
            p2 = (x2, y2)
            p3 = (x3, y3)
            for step in range(1, steps_per_curve + 1):
                points.append(eval_cubic_bezier(p0, p1, p2, p3, step / steps_per_curve))
            cx, cy = x3, y3
            prev_ctrl = p2
        elif cmd in ("Z", "z"):
            points.append((start_x, start_y))
            cx, cy = start_x, start_y
            prev_ctrl = None
        else:
            raise ValueError(f"Unsupported SVG path command: {cmd}")

    return points

def resample_by_arc_length(
    polyline: List[Tuple[float, float]], num_points: int = NUM_SAMPLE_POINTS
) -> Tuple[List[Tuple[float, float]], float]:
    """
    Resamples a dense polyline to `num_points` equidistant points along its arc length.
    Returns (resampled_points, total_arc_length).
    """
    if not polyline:
        raise ValueError("Cannot resample empty polyline")
    if len(polyline) == 1:
        return [polyline[0]] * num_points, 0.0

    cum_dist = [0.0]
    for i in range(1, len(polyline)):
        dx = polyline[i][0] - polyline[i - 1][0]
        dy = polyline[i][1] - polyline[i - 1][1]
        cum_dist.append(cum_dist[-1] + math.hypot(dx, dy))

    total_len = cum_dist[-1]
    if total_len < 1e-6:
        return [polyline[0]] * num_points, 0.0

    sampled: List[Tuple[float, float]] = [polyline[0]]
    step = total_len / (num_points - 1)
    seg_idx = 0

    for k in range(1, num_points - 1):
        target = k * step
        while seg_idx + 1 < len(cum_dist) and cum_dist[seg_idx + 1] < target:
            seg_idx += 1
        d0 = cum_dist[seg_idx]
        d1 = cum_dist[seg_idx + 1]
        span = d1 - d0
        t = (target - d0) / span if span > 1e-9 else 0.0
        p0 = polyline[seg_idx]
        p1 = polyline[seg_idx + 1]
        sampled.append((p0[0] + (p1[0] - p0[0]) * t, p0[1] + (p1[1] - p0[1]) * t))

    sampled.append(polyline[-1])
    return sampled, total_len

def pack_points_blob(points: List[Tuple[float, float]]) -> bytes:
    """Packs 50 (x, y) pairs as little-endian float32 (400 bytes total)."""
    flat = []
    for x, y in points:
        flat.extend([float(x), float(y)])
    return struct.pack(f"<{len(flat)}f", *flat)

def unpack_points_blob(blob: bytes) -> List[Tuple[float, float]]:
    count = len(blob) // 4
    vals = struct.unpack(f"<{count}f", blob)
    return [(vals[i], vals[i + 1]) for i in range(0, count, 2)]

# ---------------------------------------------------------------------------
# KANJIDIC2 & KanjiVG Parsing
# ---------------------------------------------------------------------------

def parse_kanjidic2(xml_path: Path, scope: str = "joyo") -> Dict[int, dict]:
    tree = ET.parse(xml_path)
    root = tree.getroot()
    kanji_map: Dict[int, dict] = {}

    for char_el in root.findall("character"):
        literal = char_el.findtext("literal")
        if not literal:
            continue
        codepoint = ord(literal[0])

        misc = char_el.find("misc")
        grade_text = misc.findtext("grade") if misc is not None else None
        grade = int(grade_text) if grade_text and grade_text.isdigit() else None

        # Joyo filter: grades 1..6 (Kyiku) and 8 (remaining Joyo)
        if scope == "joyo" and grade not in (1, 2, 3, 4, 5, 6, 8):
            continue

        sc_el = misc.find("stroke_count") if misc is not None else None
        if sc_el is None or not (sc_el.text and sc_el.text.isdigit()):
            continue
        stroke_count = int(sc_el.text)

        jlpt_text = misc.findtext("jlpt") if misc is not None else None
        jlpt = int(jlpt_text) if jlpt_text and jlpt_text.isdigit() else None

        freq_text = misc.findtext("freq") if misc is not None else None
        freq = int(freq_text) if freq_text and freq_text.isdigit() else None

        onyomi: List[str] = []
        kunyomi: List[str] = []
        meanings: List[str] = []

        rm = char_el.find("reading_meaning/rmgroup")
        if rm is not None:
            for r_el in rm.findall("reading"):
                rtype = r_el.attrib.get("r_type")
                if rtype == "ja_on" and r_el.text:
                    onyomi.append(r_el.text.strip())
                elif rtype == "ja_kun" and r_el.text:
                    kunyomi.append(r_el.text.strip())
            for m_el in rm.findall("meaning"):
                # Only English meanings (no m_lang attribute)
                if "m_lang" not in m_el.attrib and m_el.text:
                    meanings.append(m_el.text.strip())

        kanji_map[codepoint] = {
            "codepoint": codepoint,
            "literal": literal[0],
            "stroke_count": stroke_count,
            "grade": grade,
            "jlpt_level": jlpt,
            "frequency": freq,
            "onyomi": onyomi,
            "kunyomi": kunyomi,
            "meanings": meanings,
        }

    return kanji_map

def parse_kanjivg_svg(svg_path: Path) -> List[dict]:
    tree = ET.parse(svg_path)
    root = tree.getroot()
    kvg_ns = "{http://kanjivg.tagaini.net}"

    strokes: List[dict] = []
    for elem in root.iter():
        if elem.tag.endswith("path"):
            d = elem.attrib.get("d", "").strip()
            if not d:
                continue
            stype = elem.attrib.get(f"{kvg_ns}type") or elem.attrib.get("kvg:type") or ""
            dense = densify_svg_path(d)
            sampled, arc_len = resample_by_arc_length(dense, NUM_SAMPLE_POINTS)
            blob = pack_points_blob(sampled)
            strokes.append({
                "stroke_order": len(strokes),
                "stroke_type": stype,
                "svg_path": d,
                "arc_length": arc_len,
                "sampled_points_blob": blob,
                "sampled_points": sampled,
            })
    return strokes

# ---------------------------------------------------------------------------
# Database Creation & Validation
# ---------------------------------------------------------------------------

def build_database(
    kanjidic_path: Path,
    kanjivg_dir: Path,
    output_db_path: Path,
    scope: str = "joyo",
) -> Tuple[int, int, List[str]]:
    if output_db_path.exists():
        output_db_path.unlink()
    output_db_path.parent.mkdir(parents=True, exist_ok=True)

    kanji_map = parse_kanjidic2(kanjidic_path, scope=scope)

    import tempfile, shutil
    tmp_fd, tmp_sqlite_path = tempfile.mkstemp(suffix=".db")
    os.close(tmp_fd)
    conn = sqlite3.connect(tmp_sqlite_path)
    cur = conn.cursor()
    cur.execute(f"PRAGMA user_version = {CONTENT_DB_VERSION};")

    cur.executescript(
        """
        CREATE TABLE meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE TABLE kanji (
            codepoint INTEGER PRIMARY KEY,
            literal TEXT NOT NULL UNIQUE,
            stroke_count INTEGER NOT NULL,
            grade INTEGER,
            jlpt_level INTEGER,
            frequency INTEGER,
            onyomi_json TEXT NOT NULL,
            kunyomi_json TEXT NOT NULL,
            meanings_json TEXT NOT NULL
        );

        CREATE TABLE strokes (
            codepoint INTEGER NOT NULL,
            stroke_order INTEGER NOT NULL,
            stroke_type TEXT,
            svg_path TEXT NOT NULL,
            arc_length REAL NOT NULL,
            sampled_points_blob BLOB NOT NULL,
            PRIMARY KEY (codepoint, stroke_order),
            FOREIGN KEY (codepoint) REFERENCES kanji(codepoint) ON DELETE CASCADE
        );

        CREATE INDEX idx_kanji_grade_jlpt ON kanji(grade, jlpt_level, frequency);
        CREATE INDEX idx_strokes_codepoint ON strokes(codepoint);
        """
    )

    cur.executemany(
        "INSERT INTO meta (key, value) VALUES (?, ?)",
        [
            ("content_version", str(CONTENT_DB_VERSION)),
            ("scope", scope),
            ("kanjivg_license", "CC BY-SA 3.0 (Ulrich Apel)"),
            ("kanjidic2_license", "CC BY-SA 4.0 (EDRDG)"),
            ("sample_points_per_stroke", str(NUM_SAMPLE_POINTS)),
            ("coordinate_box", "109x109"),
        ],
    )

    inserted_kanji = 0
    inserted_strokes = 0
    warnings: List[str] = []

    for codepoint, kdata in sorted(kanji_map.items()):
        hex_code = f"{codepoint:05x}"
        svg_file = kanjivg_dir / f"{hex_code}.svg"
        if not svg_file.exists():
            continue

        strokes = parse_kanjivg_svg(svg_file)
        if not strokes:
            warnings.append(f"U+{codepoint:04X} ({kdata['literal']}): 0 strokes parsed, skipping")
            continue

        if len(strokes) != kdata["stroke_count"]:
            warnings.append(
                f"U+{codepoint:04X} ({kdata['literal']}): KanjiVG stroke count ({len(strokes)}) "
                f"!= KANJIDIC2 ({kdata['stroke_count']}); syncing stroke_count to KanjiVG"
            )
            kdata["stroke_count"] = len(strokes)

        cur.execute(
            """
            INSERT INTO kanji (
                codepoint, literal, stroke_count, grade, jlpt_level,
                frequency, onyomi_json, kunyomi_json, meanings_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                codepoint,
                kdata["literal"],
                kdata["stroke_count"],
                kdata["grade"],
                kdata["jlpt_level"],
                kdata["frequency"],
                json.dumps(kdata["onyomi"], ensure_ascii=False),
                json.dumps(kdata["kunyomi"], ensure_ascii=False),
                json.dumps(kdata["meanings"], ensure_ascii=False),
            ),
        )
        inserted_kanji += 1

        for s in strokes:
            cur.execute(
                """
                INSERT INTO strokes (
                    codepoint, stroke_order, stroke_type, svg_path, arc_length, sampled_points_blob
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    codepoint,
                    s["stroke_order"],
                    s["stroke_type"],
                    s["svg_path"],
                    s["arc_length"],
                    s["sampled_points_blob"],
                ),
            )
            inserted_strokes += 1

    conn.commit()
    cur.execute("VACUUM;")
    conn.close()
    shutil.move(tmp_sqlite_path, str(output_db_path))

    # Also write version stamp text file next to the DB asset for fast asset-version checks
    version_txt = output_db_path.parent / "content_version.txt"
    version_txt.write_text(f"{CONTENT_DB_VERSION}\n", encoding="utf-8")

    return inserted_kanji, inserted_strokes, warnings

def validate_database(db_path: Path) -> None:
    if not db_path.exists():
        raise AssertionError(f"Content DB not found at {db_path}")

    conn = sqlite3.connect(str(db_path))
    cur = conn.cursor()

    # 1. Check version stamp
    cur.execute("SELECT value FROM meta WHERE key = 'content_version'")
    row = cur.fetchone()
    assert row is not None and int(row[0]) == CONTENT_DB_VERSION, "Missing or invalid content_version"

    # 2. Check kanji count > 0
    cur.execute("SELECT COUNT(*) FROM kanji")
    kanji_count = cur.fetchone()[0]
    assert kanji_count > 0, "Content DB has 0 kanji"

    # 3. Check no kanji without strokes & stroke count matches
    cur.execute(
        """
        SELECT k.codepoint, k.literal, k.stroke_count, COUNT(s.stroke_order)
        FROM kanji k
        LEFT JOIN strokes s ON k.codepoint = s.codepoint
        GROUP BY k.codepoint
        """
    )
    for cp, literal, expected_sc, actual_sc in cur.fetchall():
        assert actual_sc > 0, f"Kanji {literal} (U+{cp:04X}) has 0 strokes"
        assert expected_sc == actual_sc, (
            f"Kanji {literal} (U+{cp:04X}) stroke count mismatch: {expected_sc} vs {actual_sc}"
        )

    # 4. Check every stroke blob has 50 valid points (400 bytes), no NaN/Inf, sensible bounds
    cur.execute("SELECT codepoint, stroke_order, arc_length, sampled_points_blob FROM strokes")
    for cp, s_order, arc_len, blob in cur.fetchall():
        assert len(blob) == NUM_SAMPLE_POINTS * 2 * 4, (
            f"Invalid blob size {len(blob)} for U+{cp:04X} stroke {s_order}"
        )
        assert arc_len > 1.0 and not math.isnan(arc_len), (
            f"Invalid arc_length {arc_len} for U+{cp:04X} stroke {s_order}"
        )
        pts = unpack_points_blob(blob)
        assert len(pts) == NUM_SAMPLE_POINTS
        for x, y in pts:
            assert not (math.isnan(x) or math.isnan(y) or math.isinf(x) or math.isinf(y)), (
                f"NaN/Inf coordinate in U+{cp:04X} stroke {s_order}"
            )
            assert -20.0 <= x <= 130.0 and -20.0 <= y <= 130.0, (
                f"Out-of-bounds point ({x:.2f}, {y:.2f}) in U+{cp:04X} stroke {s_order}"
            )

    conn.close()

def main():
    parser = argparse.ArgumentParser(description="Build Offline Kanji Practice Content DB")
    parser.add_argument(
        "--raw-dir",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "data" / "raw",
        help="Directory containing kanjidic2.xml and kanjivg/kanji/*.svg",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "assets" / "db" / "kanji_content.db",
        help="Output SQLite database path",
    )
    parser.add_argument(
        "--scope",
        choices=["joyo", "all"],
        default="joyo",
        help="Kanji scope to include (joyo or all)",
    )
    args = parser.parse_args()

    kanjidic_path = args.raw_dir / "kanjidic2.xml"
    kanjivg_dir = args.raw_dir / "kanjivg" / "kanji"

    if not kanjidic_path.exists() or not kanjivg_dir.exists():
        print("Raw data not found; generating seed dataset first...")
        from generate_seed_data import generate_seed_files
        generate_seed_files(args.raw_dir)

    k_count, s_count, warnings = build_database(
        kanjidic_path, kanjivg_dir, args.output, scope=args.scope
    )
    validate_database(args.output)
    size_kb = args.output.stat().st_size / 1024.0
    print(
        f"[OK] Built {args.output} (v{CONTENT_DB_VERSION}): "
        f"{k_count} kanji, {s_count} strokes, {size_kb:.1f} KB"
    )
    for w in warnings:
        print(f"[WARN] {w}")

if __name__ == "__main__":
    main()
