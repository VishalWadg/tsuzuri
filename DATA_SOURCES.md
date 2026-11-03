# Data Sources, Pinned Versions, and Licenses

This project bundles precompiled kanji dictionary metadata and stroke order vector paths for offline use. In accordance with Section 1 (Fixes #10 and #13) and Section 5 (Phase 0 & Phase 6) of the Approach Plan, all dataset versions, package versions, and share-alike attribution obligations are recorded here and surfaced in the in-app **Attributions** screen.

## 1. Bundled Datasets

| Dataset | Version / Snapshot | License | Author / Copyright Holder | Usage in v1 |
| :--- | :--- | :--- | :--- | :--- |
| **KanjiVG** | Release `20250816` (pinned tag `r20250816`) | [CC BY-SA 3.0](https://creativecommons.org/licenses/by-sa/3.0/) | © Ulrich Apel (<http://kanjivg.tagaini.net>) | Per-stroke SVG paths (`109x109` viewBox), stroke order, stroke types (`kvg:type`), and build-time 50-point arc-length samples. |
| **KANJIDIC2** | `2026-01` (file_version `4`) | [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) | © Electronic Dictionary Research and Development Group (EDRDG) — Jim Breen (<https://www.edrdg.org/wiki/index.php/KANJIDIC_Project>) | Kanji literals, Unicode codepoints, stroke counts, school grades, JLPT levels, frequency ranks, on'yomi/kun'yomi readings, and English meanings. |
| **JMdict** *(Post-v1 Backlog)* | Not bundled in v1 (deferred to Audio/Reading module per Section 2 & 6) | [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) | © EDRDG (<https://www.edrdg.org/wiki/index.php/JMdict-EDICT_Dictionary_Project>) | Reserved for post-v1 compound audio prompts (filtered to common words). |

### Share-Alike & Attribution Notice
- **KanjiVG**: Stroke order data and vector paths are derived from KanjiVG, copyright © Ulrich Apel, and are licensed under the Creative Commons Attribution-ShareAlike 3.0 Unported License.
- **KANJIDIC2**: Dictionary readings, meanings, and character metadata are derived from the KANJIDIC2 file, property of the Electronic Dictionary Research and Development Group (EDRDG), and are used in conformance with the Group's Creative Commons Attribution-ShareAlike 4.0 International license.

## 2. Pinned Core Package Versions

| Package | Version Constraint | License | Role |
| :--- | :--- | :--- | :--- |
| `flutter_riverpod` | `^2.6.1` | MIT | Reactive state management & dependency injection |
| `drift` / `sqlite3` | `^2.22.1` / `^2.5.0` | MIT | Dual-DB SQLite persistence (read-only Content DB + writable User DB) |
| `fsrs` | `^2.0.1` | MIT | Free Spaced Repetition Scheduler (one card per `(codepoint, mode)`) |
| `path_provider` | `^2.1.5` | BSD-3-Clause | Device storage paths for atomic content DB updates and user DB backups |

## 3. Reproducible Content DB Build

Run a single command from the repository root to regenerate `assets/db/kanji_content.db`, run all Phase 1 integrity checks, and run the Phase 2 stroke matcher benchmark harness:

```bash
make content-db
# or directly:
python3 tools/build_content_db.py --scope joyo
python3 tools/test_content_db.py
python3 tools/benchmark_matcher.py
```
