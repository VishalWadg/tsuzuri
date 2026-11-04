import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'models.dart';

/// Read-only Content Database manager with atomic version-stamped updates (Fix #1 & #12).
///
/// On app launch:
/// 1. Reads the bundled `assets/db/content_version.txt`.
/// 2. Checks if `kanji_content.db` exists in the app support/documents directory and
///    compares its `meta.content_version` stamp.
/// 3. If missing or older than the bundled asset, writes the new asset to
///    `kanji_content.db.tmp` and atomically renames it over `kanji_content.db`.
/// 4. Never touches `user_progress.db`, so user progress is 100% preserved across content updates.
class ContentDatabase {
  final Database _db;

  ContentDatabase._(this._db);

  static ContentDatabase openFromFile(File dbFile) {
    final db = sqlite3.open(dbFile.path, mode: OpenMode.readOnly);
    return ContentDatabase._(db);
  }

  static Future<ContentDatabase> initialize({
    required Directory appStorageDir,
    AssetBundle? bundle,
  }) async {
    final assetBundle = bundle ?? rootBundle;
    final targetFile = File(p.join(appStorageDir.path, 'kanji_content.db'));
    final tempFile = File(p.join(appStorageDir.path, 'kanji_content.db.tmp'));

    final bundledVersionStr =
        (await assetBundle.loadString('assets/db/content_version.txt')).trim();
    final bundledVersion = int.tryParse(bundledVersionStr) ?? 0;

    var needsUpdate = !targetFile.existsSync();
    if (!needsUpdate) {
      final installedVersion = _readInstalledVersion(targetFile);
      if (installedVersion < bundledVersion) {
        needsUpdate = true;
      }
    }

    if (needsUpdate) {
      await appStorageDir.create(recursive: true);
      final byteData = await assetBundle.load('assets/db/kanji_content.db');
      final bytes = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
      await tempFile.writeAsBytes(bytes, flush: true);
      await tempFile.rename(targetFile.path);
    }

    return openFromFile(targetFile);
  }

  static int _readInstalledVersion(File dbFile) {
    Database? db;
    try {
      db = sqlite3.open(dbFile.path, mode: OpenMode.readOnly);
      final result = db.select("SELECT value FROM meta WHERE key = 'content_version'");
      if (result.isEmpty) return -1;
      return int.tryParse(result.first['value'] as String) ?? -1;
    } catch (_) {
      return -1;
    } finally {
      db?.dispose();
    }
  }

  int get contentVersion {
    final res = _db.select("SELECT value FROM meta WHERE key = 'content_version'");
    if (res.isEmpty) return 0;
    return int.tryParse(res.first['value'] as String) ?? 0;
  }

  int get totalKanjiCount {
    final res = _db.select('SELECT COUNT(*) AS cnt FROM kanji');
    return res.first['cnt'] as int;
  }

  KanjiCharacter? getKanjiByCodepoint(int codepoint) {
    final kRows = _db.select(
      'SELECT * FROM kanji WHERE codepoint = ?',
      [codepoint],
    );
    if (kRows.isEmpty) return null;

    final sRows = _db.select(
      'SELECT * FROM strokes WHERE codepoint = ? ORDER BY stroke_order ASC',
      [codepoint],
    );
    final strokes = sRows.map(KanjiCharacter.strokeFromRow).toList(growable: false);
    return KanjiCharacter.fromRow(kRows.first, strokes);
  }

  /// Returns all kanji ordered by school grade ASC, JLPT level DESC, frequency ASC, codepoint ASC.
  List<KanjiCharacter> getAllKanjiOrdered() {
    final kRows = _db.select('''
      SELECT * FROM kanji
      ORDER BY
        COALESCE(grade, 99) ASC,
        COALESCE(jlpt_level, 0) DESC,
        COALESCE(frequency, 99999) ASC,
        codepoint ASC
    ''');
    return kRows.map((row) {
      final cp = row['codepoint'] as int;
      final sRows = _db.select(
        'SELECT * FROM strokes WHERE codepoint = ? ORDER BY stroke_order ASC',
        [cp],
      );
      final strokes = sRows.map(KanjiCharacter.strokeFromRow).toList(growable: false);
      return KanjiCharacter.fromRow(row, strokes);
    }).toList(growable: false);
  }

  /// Returns ordered codepoints for fast daily queue generation.
  List<int> getOrderedCodepoints() {
    final rows = _db.select('''
      SELECT codepoint FROM kanji
      ORDER BY
        COALESCE(grade, 99) ASC,
        COALESCE(jlpt_level, 0) DESC,
        COALESCE(frequency, 99999) ASC,
        codepoint ASC
    ''');
    return rows.map((r) => r['codepoint'] as int).toList(growable: false);
  }

  /// Generates plausible distractor English meanings for [target], prioritizing same grade / JLPT level.
  List<String> generateMeaningDistractors(KanjiCharacter target, {int count = 3}) {
    final all = getAllKanjiOrdered();
    final targetMeaningsLower = target.meanings.map((m) => m.toLowerCase().trim()).toSet();

    // Prioritize candidates with same grade or JLPT level
    final peers = all
        .where((k) =>
            k.codepoint != target.codepoint &&
            (k.grade == target.grade || k.jlptLevel == target.jlptLevel))
        .toList();

    final pool = peers.length >= count
        ? peers
        : all.where((k) => k.codepoint != target.codepoint).toList();

    final distractors = <String>[];
    for (final candidate in pool) {
      for (final m in candidate.meanings) {
        final clean = m.trim();
        if (clean.isNotEmpty &&
            !targetMeaningsLower.contains(clean.toLowerCase()) &&
            !distractors.contains(clean)) {
          distractors.add(clean);
          break;
        }
      }
      if (distractors.length >= count) break;
    }
    return distractors;
  }

  /// Generates plausible distractor readings (on'yomi or kun'yomi) for [target].
  List<String> generateReadingDistractors(KanjiCharacter target, {int count = 3}) {
    final all = getAllKanjiOrdered();
    final targetReadings =
        {...target.onyomi, ...target.kunyomi}.map((r) => r.trim()).toSet();

    final peers = all
        .where((k) =>
            k.codepoint != target.codepoint &&
            (k.grade == target.grade || k.jlptLevel == target.jlptLevel))
        .toList();

    final pool = peers.length >= count
        ? peers
        : all.where((k) => k.codepoint != target.codepoint).toList();

    final distractors = <String>[];
    for (final candidate in pool) {
      final candidateReadings = [...candidate.onyomi, ...candidate.kunyomi];
      for (final r in candidateReadings) {
        final clean = r.trim();
        if (clean.isNotEmpty &&
            !targetReadings.contains(clean) &&
            !distractors.contains(clean)) {
          distractors.add(clean);
          break;
        }
      }
      if (distractors.length >= count) break;
    }
    return distractors;
  }

  /// Generates plausible distractor Kanji characters for [target].
  List<String> generateKanjiDistractors(KanjiCharacter target, {int count = 3}) {
    final all = getAllKanjiOrdered();
    final pool = all.where((k) => k.codepoint != target.codepoint).toList();

    final distractors = <String>[];
    for (final candidate in pool) {
      if (!distractors.contains(candidate.literal)) {
        distractors.add(candidate.literal);
      }
      if (distractors.length >= count) break;
    }
    return distractors;
  }

  void close() => _db.dispose();
}
