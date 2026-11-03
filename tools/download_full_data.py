#!/usr/bin/env python3
"""
Optional helper script to download the full KANJIDIC2 XML and KanjiVG release archive
when setting up on an internet-connected PC.
After running this script, run `python3 tools/build_content_db.py --scope joyo`
to compile all ~2,136 Joyo kanji (or `--scope all` for all ~6,355 KANJIDIC2 characters).
"""

import gzip
import io
import shutil
import urllib.request
import zipfile
from pathlib import Path

KANJIDIC2_URL = "https://www.edrdg.org/kanjidic/kanjidic2.xml.gz"
KANJIVG_URL = "https://github.com/KanjiVG/kanjivg/releases/download/r20250816/kanjivg-20250816-main.zip"

def download_datasets(raw_dir: Path):
    raw_dir.mkdir(parents=True, exist_ok=True)
    kanjidic_out = raw_dir / "kanjidic2.xml"
    kanjivg_dir = raw_dir / "kanjivg"

    print(f"Downloading KANJIDIC2 from {KANJIDIC2_URL} ...")
    with urllib.request.urlopen(KANJIDIC2_URL) as resp:
        compressed = resp.read()
    with gzip.GzipFile(fileobj=io.BytesIO(compressed)) as gz:
        kanjidic_out.write_bytes(gz.read())
    print(f"Saved {kanjidic_out} ({kanjidic_out.stat().st_size / (1024*1024):.2f} MB)")

    print(f"Downloading KanjiVG from {KANJIVG_URL} ...")
    with urllib.request.urlopen(KANJIVG_URL) as resp:
        zip_bytes = resp.read()
    with zipfile.ZipFile(io.BytesIO(zip_bytes)) as zf:
        zf.extractall(kanjivg_dir)
    print(f"Extracted KanjiVG to {kanjivg_dir}")

if __name__ == "__main__":
    target = Path(__file__).resolve().parent.parent / "data" / "raw"
    download_datasets(target)
