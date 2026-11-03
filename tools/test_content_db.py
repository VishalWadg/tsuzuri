#!/usr/bin/env python3
"""
Phase 1 Automated Validation Suite for `assets/db/kanji_content.db`.
Verifies:
1. Database exists and has a valid `content_version` stamp matching `assets/db/content_version.txt`.
2. Every kanji has >= 1 strokes and `kanji.stroke_count == COUNT(strokes)`.
3. Every stroke has a valid non-empty SVG path and a 400-byte (50 x 2 x float32) sampled points blob.
4. No NaN, Inf, or out-of-bounds coordinates exist in any sampled point.
5. Readings and meanings JSON arrays parse cleanly.
"""

import json
import math
import sqlite3
import struct
import unittest
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
DB_PATH = ROOT_DIR / "assets" / "db" / "kanji_content.db"
VERSION_TXT = ROOT_DIR / "assets" / "db" / "content_version.txt"

class TestContentDatabase(unittest.TestCase):
    def setUp(self):
        self.assertTrue(DB_PATH.exists(), f"Missing content DB: {DB_PATH}")
        self.assertTrue(VERSION_TXT.exists(), f"Missing version stamp file: {VERSION_TXT}")
        self.conn = sqlite3.connect(str(DB_PATH))
        self.cur = self.conn.cursor()

    def tearDown(self):
        self.conn.close()

    def test_version_stamp_matches(self):
        txt_version = int(VERSION_TXT.read_text(encoding="utf-8").strip())
        self.cur.execute("SELECT value FROM meta WHERE key = 'content_version'")
        row = self.cur.fetchone()
        self.assertIsNotNone(row)
        self.assertEqual(int(row[0]), txt_version)

        self.cur.execute("PRAGMA user_version;")
        pragma_version = self.cur.fetchone()[0]
        self.assertEqual(pragma_version, txt_version)

    def test_no_kanji_without_strokes_and_counts_match(self):
        self.cur.execute(
            """
            SELECT k.codepoint, k.literal, k.stroke_count, COUNT(s.stroke_order)
            FROM kanji k
            LEFT JOIN strokes s ON k.codepoint = s.codepoint
            GROUP BY k.codepoint
            """
        )
        rows = self.cur.fetchall()
        self.assertGreater(len(rows), 0)
        for cp, literal, expected_sc, actual_sc in rows:
            self.assertGreater(actual_sc, 0, f"Kanji {literal} (U+{cp:04X}) has no strokes")
            self.assertEqual(
                expected_sc,
                actual_sc,
                f"Stroke count mismatch for {literal} (U+{cp:04X}): {expected_sc} vs {actual_sc}",
            )

    def test_sampled_points_blobs_have_no_nan_or_empty_points(self):
        self.cur.execute("SELECT codepoint, stroke_order, svg_path, arc_length, sampled_points_blob FROM strokes")
        rows = self.cur.fetchall()
        self.assertGreater(len(rows), 0)
        for cp, order, svg_path, arc_len, blob in rows:
            self.assertTrue(svg_path.startswith("M") or svg_path.startswith("m"))
            self.assertGreater(arc_len, 1.0)
            self.assertFalse(math.isnan(arc_len))
            self.assertEqual(len(blob), 400, f"Expected 400 bytes for 50 float32 pairs in U+{cp:04X}")
            floats = struct.unpack("<100f", blob)
            for val in floats:
                self.assertFalse(math.isnan(val) or math.isinf(val))
                self.assertTrue(-20.0 <= val <= 130.0, f"Coordinate {val} out of bounds")

    def test_readings_and_meanings_valid_json(self):
        self.cur.execute("SELECT codepoint, literal, onyomi_json, kunyomi_json, meanings_json FROM kanji")
        for cp, literal, on_j, kun_j, mean_j in self.cur.fetchall():
            on_list = json.loads(on_j)
            kun_list = json.loads(kun_j)
            mean_list = json.loads(mean_j)
            self.assertIsInstance(on_list, list)
            self.assertIsInstance(kun_list, list)
            self.assertIsInstance(mean_list, list)
            self.assertGreater(len(mean_list), 0, f"Kanji {literal} has no meanings")

if __name__ == "__main__":
    unittest.main(verbosity=2)
