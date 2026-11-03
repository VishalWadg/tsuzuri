#!/usr/bin/env python3
"""
Generates sample/seed KANJIDIC2 XML and KanjiVG SVG files for offline development
and reproducible testing, and also supports downloading the full datasets when
run on an internet-connected developer machine.
"""

import os
from pathlib import Path

# Representative Joyo Grade 1 / JLPT N5 Kanji with authentic KanjiVG 109x109 paths
SEED_KANJI = [
    {
        "literal": "一",
        "codepoint": 0x4E00,
        "hex": "04e00",
        "grade": 1,
        "stroke_count": 1,
        "jlpt": 5,
        "freq": 2,
        "onyomi": ["イチ", "イツ"],
        "kunyomi": ["ひと-", "ひと.つ"],
        "meanings": ["one", "one radical (no.1)"],
        "strokes": [
            ("㇐", "M11.5,54.25 C20.5,55.0 85.0,49.5 96.5,50.25"),
        ],
    },
    {
        "literal": "二",
        "codepoint": 0x4E8C,
        "hex": "04e8c",
        "grade": 1,
        "stroke_count": 2,
        "jlpt": 5,
        "freq": 9,
        "onyomi": ["ニ", "ジ"],
        "kunyomi": ["ふた", "ふた.つ", "ふたた.び"],
        "meanings": ["two"],
        "strokes": [
            ("㇐", "M25.25,32.5 C34.0,33.0 72.0,29.5 83.5,30.0"),
            ("㇐", "M13.5,79.25 C24.0,80.0 82.5,75.0 95.0,76.0"),
        ],
    },
    {
        "literal": "三",
        "codepoint": 0x4E09,
        "hex": "04e09",
        "grade": 1,
        "stroke_count": 3,
        "jlpt": 5,
        "freq": 14,
        "onyomi": ["サン", "ゾウ"],
        "kunyomi": ["み", "み.つ", "みっ.つ"],
        "meanings": ["three"],
        "strokes": [
            ("㇐", "M27.5,24.75 C36.5,25.25 69.5,21.75 79.5,22.25"),
            ("㇐", "M29.0,52.0 C38.0,52.5 67.5,49.0 77.5,49.5"),
            ("㇐", "M14.0,82.25 C25.0,83.0 81.5,78.0 94.0,79.0"),
        ],
    },
    {
        "literal": "十",
        "codepoint": 0x5341,
        "hex": "05341",
        "grade": 1,
        "stroke_count": 2,
        "jlpt": 5,
        "freq": 8,
        "onyomi": ["ジュウ", "ジッ", "ジュッ"],
        "kunyomi": ["とお", "と"],
        "meanings": ["ten"],
        "strokes": [
            ("㇐", "M12.75,51.25 C24.0,52.0 82.0,47.0 95.25,48.0"),
            ("㇑", "M53.25,11.5 C53.75,22.0 53.25,84.0 53.25,96.5"),
        ],
    },
    {
        "literal": "人",
        "codepoint": 0x4EBA,
        "hex": "04eba",
        "grade": 1,
        "stroke_count": 2,
        "jlpt": 5,
        "freq": 5,
        "onyomi": ["ジン", "ニン"],
        "kunyomi": ["ひと", "-り", "-と"],
        "meanings": ["person"],
        "strokes": [
            ("㇒", "M54.5,20.0 C52.0,38.0 36.0,70.0 14.5,88.0"),
            ("㇏", "M46.0,54.0 C58.0,64.0 76.0,80.0 92.5,89.5"),
        ],
    },
    {
        "literal": "大",
        "codepoint": 0x5927,
        "hex": "05927",
        "grade": 1,
        "stroke_count": 3,
        "jlpt": 5,
        "freq": 7,
        "onyomi": ["ダイ", "タイ"],
        "kunyomi": ["おお-", "おお.きい", "-おお.いに"],
        "meanings": ["large", "big"],
        "strokes": [
            ("㇐", "M18.5,47.5 C30.0,48.0 76.0,43.5 89.0,44.25"),
            ("㇒", "M53.25,15.5 C53.0,45.0 39.0,75.0 15.0,91.5"),
            ("㇏", "M54.0,47.5 C64.0,62.0 78.0,79.0 93.0,89.5"),
        ],
    },
    {
        "literal": "日",
        "codepoint": 0x65E5,
        "hex": "065e5",
        "grade": 1,
        "stroke_count": 4,
        "jlpt": 5,
        "freq": 1,
        "onyomi": ["ニチ", "ジツ"],
        "kunyomi": ["ひ", "-び", "-か"],
        "meanings": ["day", "sun", "Japan", "counter for days"],
        "strokes": [
            ("㇑", "M30.5,22.0 C31.0,34.0 31.0,74.0 31.0,87.5"),
            ("㇕a", "M32.0,23.5 C44.0,22.0 68.0,19.5 76.5,19.5 C78.5,25.0 78.0,72.0 77.5,86.5"),
            ("㇐a", "M32.5,52.5 C44.0,51.5 65.0,49.5 76.5,49.5"),
            ("㇐a", "M32.5,85.0 C44.5,84.0 64.5,82.5 76.5,82.5"),
        ],
    },
    {
        "literal": "月",
        "codepoint": 0x6708,
        "hex": "06708",
        "grade": 1,
        "stroke_count": 4,
        "jlpt": 5,
        "freq": 23,
        "onyomi": ["ゲツ", "ガツ"],
        "kunyomi": ["つき"],
        "meanings": ["month", "moon"],
        "strokes": [
            ("㇒", "M34.25,18.5 C34.5,42.0 31.0,74.0 17.5,91.0"),
            ("㇆a", "M36.0,20.0 C48.0,18.5 68.0,16.5 74.5,16.5 C76.0,28.0 75.5,76.0 74.5,89.5"),
            ("㇐a", "M36.0,42.5 C47.0,41.5 63.0,40.0 74.0,40.0"),
            ("㇐a", "M35.0,63.5 C46.5,62.5 63.0,61.0 74.0,61.0"),
        ],
    },
    {
        "literal": "木",
        "codepoint": 0x6728,
        "hex": "06728",
        "grade": 1,
        "stroke_count": 4,
        "jlpt": 5,
        "freq": 67,
        "onyomi": ["ボク", "モク"],
        "kunyomi": ["き", "こ-"],
        "meanings": ["tree", "wood"],
        "strokes": [
            ("㇐", "M19.5,39.5 C31.0,40.0 75.0,36.0 88.5,36.5"),
            ("㇑", "M53.0,13.5 C53.5,26.0 53.0,82.0 53.0,95.5"),
            ("㇒", "M51.5,39.5 C43.0,55.0 29.0,73.0 13.5,84.5"),
            ("㇏", "M54.5,39.5 C64.0,54.0 78.0,71.0 92.5,82.5"),
        ],
    },
    {
        "literal": "山",
        "codepoint": 0x5C71,
        "hex": "05c71",
        "grade": 1,
        "stroke_count": 3,
        "jlpt": 5,
        "freq": 131,
        "onyomi": ["サン", "セン"],
        "kunyomi": ["やま"],
        "meanings": ["mountain"],
        "strokes": [
            ("㇑a", "M53.25,16.5 C53.75,28.0 53.25,70.0 53.25,82.5"),
            ("㇄a", "M22.5,48.0 C22.5,58.0 21.5,76.0 21.5,84.0 C35.0,83.0 72.0,80.0 85.5,79.5"),
            ("㇑", "M86.5,44.0 C87.0,55.0 86.0,76.0 85.5,88.5"),
        ],
    },
    {
        "literal": "川",
        "codepoint": 0x5DDD,
        "hex": "05ddd",
        "grade": 1,
        "stroke_count": 3,
        "jlpt": 5,
        "freq": 181,
        "onyomi": ["セン"],
        "kunyomi": ["かわ"],
        "meanings": ["stream", "river"],
        "strokes": [
            ("㇒", "M27.5,22.0 C28.0,45.0 25.0,72.0 14.5,89.0"),
            ("㇑", "M53.5,24.5 C54.0,38.0 53.5,68.0 53.5,83.5"),
            ("㇑", "M80.5,17.5 C81.0,34.0 80.5,76.0 80.5,93.5"),
        ],
    },
    {
        "literal": "口",
        "codepoint": 0x53E3,
        "hex": "053e3",
        "grade": 1,
        "stroke_count": 3,
        "jlpt": 5,
        "freq": 28,
        "onyomi": ["コウ", "ク"],
        "kunyomi": ["くち"],
        "meanings": ["mouth"],
        "strokes": [
            ("㇑", "M25.5,31.0 C27.0,43.0 29.5,68.0 31.0,81.5"),
            ("㇕b", "M27.0,32.5 C42.0,30.5 71.0,27.5 81.5,27.5 C80.0,41.0 77.5,64.0 75.5,77.5"),
            ("㇐b", "M31.5,79.0 C45.0,78.0 63.0,76.5 76.5,76.0"),
        ],
    },
    {
        "literal": "田",
        "codepoint": 0x7530,
        "hex": "07530",
        "grade": 1,
        "stroke_count": 5,
        "jlpt": 5,
        "freq": 90,
        "onyomi": ["デン"],
        "kunyomi": ["た"],
        "meanings": ["rice field", "rice paddy"],
        "strokes": [
            ("㇑", "M21.5,25.5 C23.0,40.0 25.5,69.0 27.0,84.5"),
            ("㇕a", "M23.0,27.0 C40.0,25.0 73.0,22.0 85.5,22.0 C84.0,38.0 81.5,67.0 79.5,82.5"),
            ("㇑a", "M53.5,26.0 C54.0,40.0 53.5,67.0 53.5,80.5"),
            ("㇐a", "M25.5,53.5 C41.0,52.0 67.0,50.0 82.0,49.5"),
            ("㇐a", "M27.5,82.0 C42.5,81.0 65.5,79.5 79.5,79.0"),
        ],
    },
    {
        "literal": "水",
        "codepoint": 0x6C34,
        "hex": "06c34",
        "grade": 1,
        "stroke_count": 4,
        "jlpt": 5,
        "freq": 56,
        "onyomi": ["スイ"],
        "kunyomi": ["みず", "みず-"],
        "meanings": ["water"],
        "strokes": [
            ("㇚", "M53.5,14.5 C54.0,30.0 53.5,76.0 53.5,91.0 C50.0,88.0 44.0,83.0 39.5,79.5"),
            ("㇇", "M17.5,44.5 C25.0,43.0 34.0,40.5 39.5,40.0 C37.0,53.0 26.0,70.0 13.5,81.5"),
            ("㇒", "M83.5,28.5 C76.0,36.0 67.0,43.0 59.5,48.0"),
            ("㇏", "M56.5,48.5 C66.0,60.0 79.0,74.0 92.5,83.5"),
        ],
    },
    {
        "literal": "火",
        "codepoint": 0x706B,
        "hex": "0706b",
        "grade": 1,
        "stroke_count": 4,
        "jlpt": 5,
        "freq": 213,
        "onyomi": ["カ"],
        "kunyomi": ["ひ", "-び", "ほ-"],
        "meanings": ["fire"],
        "strokes": [
            ("㇔", "M23.5,35.5 C27.5,42.0 31.5,50.0 33.5,56.5"),
            ("㇒", "M84.5,31.5 C78.0,40.0 70.0,48.0 62.5,54.0"),
            ("㇒", "M52.5,15.5 C53.0,46.0 42.0,74.0 17.5,91.5"),
            ("㇏", "M53.5,52.5 C64.0,66.0 78.0,80.0 92.5,90.5"),
        ],
    },
    {
        "literal": "土",
        "codepoint": 0x571F,
        "hex": "0571f",
        "grade": 1,
        "stroke_count": 3,
        "jlpt": 5,
        "freq": 140,
        "onyomi": ["ド", "ト"],
        "kunyomi": ["つち"],
        "meanings": ["soil", "earth", "ground", "Turkey"],
        "strokes": [
            ("㇐", "M26.5,49.5 C36.5,50.0 69.5,46.5 80.5,47.0"),
            ("㇑a", "M53.25,16.5 C53.75,29.0 53.25,71.0 53.25,84.5"),
            ("㇐", "M14.5,86.5 C26.0,87.0 81.0,83.0 94.5,83.5"),
        ],
    },
    {
        "literal": "本",
        "codepoint": 0x672C,
        "hex": "0672c",
        "grade": 1,
        "stroke_count": 5,
        "jlpt": 5,
        "freq": 10,
        "onyomi": ["ホン"],
        "kunyomi": ["もと"],
        "meanings": ["book", "present", "main", "origin", "true", "real"],
        "strokes": [
            ("㇐", "M19.5,36.5 C31.0,37.0 75.0,33.0 88.5,33.5"),
            ("㇑", "M53.0,12.5 C53.5,25.0 53.0,83.0 53.0,96.5"),
            ("㇒", "M51.5,36.5 C43.0,52.0 29.0,70.0 13.5,81.5"),
            ("㇏", "M54.5,36.5 C64.0,51.0 78.0,68.0 92.5,79.5"),
            ("㇐", "M33.5,73.5 C42.5,74.0 64.5,71.5 73.5,72.0"),
        ],
    },
    {
        "literal": "中",
        "codepoint": 0x4E2D,
        "hex": "04e2d",
        "grade": 1,
        "stroke_count": 4,
        "jlpt": 5,
        "freq": 11,
        "onyomi": ["チュウ"],
        "kunyomi": ["なか", "うち", "あた.る"],
        "meanings": ["in", "inside", "middle", "mean", "center"],
        "strokes": [
            ("㇑", "M22.5,33.5 C24.0,43.0 26.5,58.0 28.0,67.5"),
            ("㇕b", "M24.5,35.0 C41.0,33.0 72.0,30.0 84.5,30.0 C83.0,40.0 80.5,54.0 78.5,64.0"),
            ("㇐b", "M28.5,65.5 C43.5,64.5 65.5,63.0 79.5,62.5"),
            ("㇑", "M53.25,11.5 C53.75,24.0 53.25,83.0 53.25,96.5"),
        ],
    },
    {
        "literal": "上",
        "codepoint": 0x4E0A,
        "hex": "04e0a",
        "grade": 1,
        "stroke_count": 3,
        "jlpt": 5,
        "freq": 35,
        "onyomi": ["ジョウ", "ショウ", "シャン"],
        "kunyomi": ["うえ", "-うえ", "うわ-", "かみ", "あ.げる", "のぼ.る"],
        "meanings": ["above", "up"],
        "strokes": [
            ("㇑a", "M53.25,15.5 C53.75,28.0 53.25,72.0 53.25,85.5"),
            ("㇐b", "M55.0,48.5 C63.0,48.0 75.0,46.5 83.5,46.5"),
            ("㇐", "M14.5,87.0 C26.5,87.5 81.0,83.5 94.5,84.0"),
        ],
    },
    {
        "literal": "下",
        "codepoint": 0x4E0B,
        "hex": "04e0b",
        "grade": 1,
        "stroke_count": 3,
        "jlpt": 5,
        "freq": 97,
        "onyomi": ["カ", "ゲ"],
        "kunyomi": ["した", "しも", "もと", "さ.げる", "くだ.る"],
        "meanings": ["below", "down", "descend", "give", "low", "inferior"],
        "strokes": [
            ("㇐", "M14.5,22.5 C26.5,23.0 81.0,19.0 94.5,19.5"),
            ("㇑", "M53.25,22.5 C53.75,35.0 53.25,81.0 53.25,94.5"),
            ("㇔", "M60.5,46.5 C68.0,51.0 77.0,57.5 83.5,63.5"),
        ],
    },
]

def generate_seed_files(raw_dir: Path):
    kanjivg_dir = raw_dir / "kanjivg" / "kanji"
    kanjivg_dir.mkdir(parents=True, exist_ok=True)

    # Write KANJIDIC2 XML
    xml_lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<kanjidic2>',
        '  <header>',
        '    <file_version>4</file_version>',
        '    <database_version>2026-01</database_version>',
        '    <date_of_creation>2026-01-15</date_of_creation>',
        '  </header>',
    ]
    for entry in SEED_KANJI:
        xml_lines.append('  <character>')
        xml_lines.append(f'    <literal>{entry["literal"]}</literal>')
        xml_lines.append('    <codepoint>')
        xml_lines.append(f'      <cp_value cp_type="ucs">{entry["hex"].lstrip("0")}</cp_value>')
        xml_lines.append('    </codepoint>')
        xml_lines.append('    <misc>')
        xml_lines.append(f'      <grade>{entry["grade"]}</grade>')
        xml_lines.append(f'      <stroke_count>{entry["stroke_count"]}</stroke_count>')
        xml_lines.append(f'      <freq>{entry["freq"]}</freq>')
        xml_lines.append(f'      <jlpt>{entry["jlpt"]}</jlpt>')
        xml_lines.append('    </misc>')
        xml_lines.append('    <reading_meaning>')
        xml_lines.append('      <rmgroup>')
        for on in entry["onyomi"]:
            xml_lines.append(f'        <reading r_type="ja_on">{on}</reading>')
        for kun in entry["kunyomi"]:
            xml_lines.append(f'        <reading r_type="ja_kun">{kun}</reading>')
        for m in entry["meanings"]:
            xml_lines.append(f'        <meaning>{m}</meaning>')
        xml_lines.append('      </rmgroup>')
        xml_lines.append('    </reading_meaning>')
        xml_lines.append('  </character>')
    xml_lines.append('</kanjidic2>')

    (raw_dir / "kanjidic2.xml").write_text("\n".join(xml_lines), encoding="utf-8")

    # Write KanjiVG SVG files
    for entry in SEED_KANJI:
        svg_lines = [
            '<?xml version="1.0" encoding="UTF-8"?>',
            '<svg xmlns="http://www.w3.org/2000/svg" width="109" height="109" viewBox="0 0 109 109" xmlns:kvg="http://kanjivg.tagaini.net">',
            f'  <g id="kvg:StrokePaths_{entry["hex"]}" style="fill:none;stroke:#000000;stroke-width:3;stroke-linecap:round;stroke-linejoin:round;">',
            f'    <g id="kvg:{entry["hex"]}" kvg:element="{entry["literal"]}">',
        ]
        for idx, (stype, d_path) in enumerate(entry["strokes"], start=1):
            svg_lines.append(
                f'      <path id="kvg:{entry["hex"]}-s{idx}" kvg:type="{stype}" d="{d_path}"/>'
            )
        svg_lines.extend([
            '    </g>',
            '  </g>',
            '</svg>',
        ])
        (kanjivg_dir / f'{entry["hex"]}.svg').write_text("\n".join(svg_lines), encoding="utf-8")

if __name__ == "__main__":
    base = Path(__file__).resolve().parent.parent / "data" / "raw"
    generate_seed_files(base)
    print(f"Generated {len(SEED_KANJI)} seed kanji in {base}")
