# Offline Kanji Practice App (v1 — Writing Module)

A complete, self-contained **Flutter + Python** implementation of **v1 (the Writing Module)** from the *Offline Kanji Practice App: Approach Plan*. Everything runs 100% offline with zero servers or accounts required.

---

## What Is Included & How All 13 Fixes from the Plan Are Implemented

1. **Dual Databases (Fix #1 & #12)**:
   - `assets/db/kanji_content.db`: Read-only prebuilt SQLite database containing KANJIDIC2 character metadata and KanjiVG stroke paths + pre-sampled 50-point binary blobs. Stamped with `content_version` (`20260101`). On app launch (`ContentDatabase.initialize`), if the bundled version is newer than the installed copy, the new file is written to `kanji_content.db.tmp` and atomically renamed into place without touching user data.
   - `user_progress.db`: Separate writable SQLite database in the app documents directory storing `srs_cards`, `review_logs`, and `user_settings`, with versioned schema migrations (`UserDatabase`).
2. **Unicode Codepoint Primary Keys & Per-Modality Cards (Fix #2 & #9)**:
   - Every kanji is keyed by its Unicode scalar value (`codepoint`, e.g., `0x65E5` for `日`), never an autoincrement ID.
   - FSRS cards in `srs_cards` are keyed by `(codepoint, mode)` (e.g., `(0x65E5, 'writing')`), isolating writing progress so future reading/audio modules can add their own cards cleanly.
3. **Pre-Sampled 50-Point Stroke Blobs at Build Time (Fix #7)**:
   - `tools/build_content_db.py` evaluates KanjiVG cubic Bézier paths at build time, resamples each stroke to 50 equidistant points by arc length in the `109×109` coordinate space, and stores a 400-byte little-endian `float32` binary blob (`sampled_points_blob`) beside `svg_path`. No runtime SVG parsing library is used on the hot path.
4. **Revised Stroke Checking Pipeline (Section 3 & Fixes #3, #4, #5, #6)**:
   - Implemented in pure Dart (`lib/src/matching/`) with zero UI dependencies:
     - Normalizes canvas coordinates to `109×109` and resamples user polyline $U$ to 50 points by arc length.
     - Rejects accidental taps (`tooShort`).
     - **Length-ratio gate (Fix #3)**: Rejects strokes under 50% or over 200% of reference length (scaled by leniency preset).
     - **Start-direction chord gate (Fix #4)**: Compares the chord over the first 25% of the stroke (points `0..12` of 50) plus overall start-to-end chord to catch reversed strokes (`wrongDirection`).
     - **Iterative Discrete Fréchet Distance + Bounding-Box Alignment (Fix #5)**: Computes discrete Fréchet distance iteratively ($O(N^2)$ with a 2-row rolling buffer) against both the as-drawn stroke and a bounding-box-translated/scaled variant (penalized mildly by `1.15×`).
     - **Length-Scaled Threshold (Fix #3)**: Scales threshold to ~25% of reference stroke length, clamped to `[9.5, 25.0]`, multiplied by the active leniency preset (`Strict`, `Normal`, `Forgiving`).
     - **Wrong-Order Detection (Fix #6)**: When a stroke fails against expected stroke $Q_i$, tests remaining strokes $Q_{i+1 \dots n-1}$ and returns `wrongOrder` if it matches a later stroke.
5. **Three-Layer CustomPainter Canvas (Phase 4)**:
   - Implemented in `lib/src/ui/canvas/kanji_canvas.dart` & `svg_path_parser.dart`:
     - **Layer 1**: Four-quadrant grid + verified strokes snapped to reference SVG paths (turns green on character completion).
     - **Layer 2**: Hint layer showing a faint outline of the next stroke and an animated progressive stroke demonstration after repeated errors or when tapping **Hint**.
     - **Layer 3**: Single-pointer live ink capture (ignores extra multi-touch pointers), haptic feedback, and red flash + fade-out with reason banner on failure.
6. **Automatic FSRS Grading & Daily Queue (Phase 5)**:
   - Implemented in `lib/src/scheduling/fsrs_scheduler.dart`: maps `(mistakes, hintsUsed)` directly to `Easy`, `Good`, `Hard`, or `Again` on completion, updates the `(codepoint, 'writing')` FSRS card, and builds the daily queue (due cards first, then new cards ordered by school grade & JLPT level up to the daily limit).
7. **Backup & Restore + Licensing Attributions (Fixes #10, #11, #13)**:
   - JSON snapshot export & import in `SettingsScreen` and `UserDatabase` (`exportBackupJson` / `importBackupJson`).
   - Full attributions in `DATA_SOURCES.md` and the in-app `AttributionsScreen` for KanjiVG (CC BY-SA 3.0) and KANJIDIC2 (EDRDG CC BY-SA 4.0).

---

## Quick Start on Your PC

### 1. Prerequisites
- **Flutter SDK**: `>=3.3.0` (run `flutter create . --platforms android,ios,linux,macos,windows` once inside the folder to generate the platform runner directories for your OS/device)
- **Python 3**: `>=3.9` (uses only the Python standard library — zero external pip packages required!)

### 2. Verify the Content Pipeline & Benchmark Harness (Python)
The zip archive already ships with a prebuilt `assets/db/kanji_content.db` (seeded with 20 core Joyo Grade 1 / JLPT N5 kanji and 65 pre-sampled strokes so it works immediately out of the box). You can rebuild and run the validation + synthetic stroke-matcher benchmark anytime:

```bash
# Rebuild assets/db/kanji_content.db from data/raw/
python3 tools/build_content_db.py --scope joyo

# Run Phase 1 DB integrity tests (stroke counts, 400-byte blobs, NaN checks, version stamp)
python3 tools/test_content_db.py

# Run Phase 2 synthetic stroke-matcher benchmark (noisy variants, reversed strokes, wrong-order strokes)
python3 tools/benchmark_matcher.py
```

### 3. Optional: Compile Full Joyo (2,136 Kanji) or Full KANJIDIC2 (6,355 Kanji)
When on an internet-connected PC, run the included downloader to fetch the complete official KANJIDIC2 and KanjiVG datasets and rebuild `assets/db/kanji_content.db`:

```bash
python3 tools/download_full_data.py
python3 tools/build_content_db.py --scope joyo
python3 tools/test_content_db.py
python3 tools/benchmark_matcher.py
```

### 4. Run the Flutter App & Unit Tests
```bash
# Generate platform runner folders (android, ios, windows, macos, linux) if not present
flutter create . --project-name offline_kanji_practice

# Fetch Dart packages
flutter pub get

# Run Phase 2, Phase 3, and Phase 5 Dart unit tests
flutter test

# Launch on your connected Android/iOS device or desktop
flutter run
```
