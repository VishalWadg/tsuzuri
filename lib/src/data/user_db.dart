import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import '../matching/stroke_matcher.dart';
import 'models.dart';

/// Writable User Progress Database (Fix #1, #2, #9, #11).
///
/// Key design rules from the Approach Plan:
/// - Completely separate SQLite file (`user_progress.db`) from `kanji_content.db`.
/// - Keyed by `(codepoint, mode)` where `codepoint` is the Unicode scalar value.
/// - Includes schema versioning (`currentSchemaVersion = 2`) with tested migrations.
/// - Supports full JSON snapshot and raw SQLite file backup & restore.
class UserDatabase {
  static const int currentSchemaVersion = 2;
  final Database _db;
  final String? filePath;

  UserDatabase._(this._db, {this.filePath});

  static UserDatabase openInMemory() {
    final db = sqlite3.openInMemory();
    final instance = UserDatabase._(db);
    instance._migrate();
    return instance;
  }

  static Future<UserDatabase> openFromDirectory(Directory appDocDir) async {
    await appDocDir.create(recursive: true);
    final path = p.join(appDocDir.path, 'user_progress.db');
    final db = sqlite3.open(path);
    final instance = UserDatabase._(db, filePath: path);
    instance._migrate();
    return instance;
  }

  int get schemaVersion {
    final row = _db.select('PRAGMA user_version;').first;
    return row.values.first as int;
  }

  void _migrate() {
    final version = schemaVersion;
    if (version < 1) {
      _db.execute('''
        CREATE TABLE IF NOT EXISTS srs_cards (
          codepoint INTEGER NOT NULL,
          mode TEXT NOT NULL,
          due_date TEXT NOT NULL,
          stability REAL NOT NULL,
          difficulty REAL NOT NULL,
          elapsed_days INTEGER NOT NULL,
          scheduled_days INTEGER NOT NULL,
          reps INTEGER NOT NULL,
          lapses INTEGER NOT NULL,
          state INTEGER NOT NULL,
          last_review TEXT,
          PRIMARY KEY (codepoint, mode)
        );

        CREATE INDEX IF NOT EXISTS idx_srs_cards_mode_due
          ON srs_cards(mode, due_date);

        CREATE TABLE IF NOT EXISTS user_settings (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
      ''');
      _db.execute('PRAGMA user_version = 1;');
    }

    if (version < 2) {
      // Schema v2 migration: adds review_logs table to track practice history & accuracy
      _db.execute('''
        CREATE TABLE IF NOT EXISTS review_logs (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          codepoint INTEGER NOT NULL,
          mode TEXT NOT NULL,
          rating INTEGER NOT NULL,
          mistakes INTEGER NOT NULL,
          hints_used INTEGER NOT NULL,
          reviewed_at TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_review_logs_codepoint
          ON review_logs(codepoint, mode);
      ''');
      _db.execute('PRAGMA user_version = 2;');
    }
  }

  // ---------------------------------------------------------------------------
  // Card Progress CRUD (keyed by Unicode codepoint + mode)
  // ---------------------------------------------------------------------------

  UserCardProgress? getCard(int codepoint, {String mode = PracticeMode.writing}) {
    final rows = _db.select(
      'SELECT * FROM srs_cards WHERE codepoint = ? AND mode = ?',
      [codepoint, mode],
    );
    if (rows.isEmpty) return null;
    return UserCardProgress.fromMap(rows.first);
  }

  List<UserCardProgress> getAllCards({String mode = PracticeMode.writing}) {
    final rows = _db.select(
      'SELECT * FROM srs_cards WHERE mode = ? ORDER BY due_date ASC',
      [mode],
    );
    return rows.map(UserCardProgress.fromMap).toList(growable: false);
  }

  List<UserCardProgress> getDueCards({
    required DateTime now,
    String mode = PracticeMode.writing,
  }) {
    final nowIso = now.toUtc().toIso8601String();
    final rows = _db.select(
      'SELECT * FROM srs_cards WHERE mode = ? AND due_date <= ? ORDER BY due_date ASC',
      [mode, nowIso],
    );
    return rows.map(UserCardProgress.fromMap).toList(growable: false);
  }

  Set<int> getStudiedCodepoints({String mode = PracticeMode.writing}) {
    final rows = _db.select(
      'SELECT codepoint FROM srs_cards WHERE mode = ?',
      [mode],
    );
    return rows.map((r) => r['codepoint'] as int).toSet();
  }

  int getNewCardsIntroducedOnDate({
    required DateTime date,
    String mode = PracticeMode.writing,
  }) {
    final dayPrefix = date.toUtc().toIso8601String().substring(0, 10);
    final rows = _db.select(
      '''
      SELECT COUNT(DISTINCT codepoint) AS cnt
      FROM review_logs
      WHERE mode = ? AND reviewed_at LIKE ?
      ''',
      [mode, '$dayPrefix%'],
    );
    return (rows.first['cnt'] as int?) ?? 0;
  }

  void upsertCard(UserCardProgress card) {
    _db.execute(
      '''
      INSERT INTO srs_cards (
        codepoint, mode, due_date, stability, difficulty,
        elapsed_days, scheduled_days, reps, lapses, state, last_review
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(codepoint, mode) DO UPDATE SET
        due_date = excluded.due_date,
        stability = excluded.stability,
        difficulty = excluded.difficulty,
        elapsed_days = excluded.elapsed_days,
        scheduled_days = excluded.scheduled_days,
        reps = excluded.reps,
        lapses = excluded.lapses,
        state = excluded.state,
        last_review = excluded.last_review
      ''',
      [
        card.codepoint,
        card.mode,
        card.dueDate.toUtc().toIso8601String(),
        card.stability,
        card.difficulty,
        card.elapsedDays,
        card.scheduledDays,
        card.reps,
        card.lapses,
        card.state,
        card.lastReview?.toUtc().toIso8601String(),
      ],
    );
  }

  void insertReviewLog({
    required int codepoint,
    required String mode,
    required int rating,
    required int mistakes,
    required int hintsUsed,
    required DateTime reviewedAt,
  }) {
    _db.execute(
      '''
      INSERT INTO review_logs (codepoint, mode, rating, mistakes, hints_used, reviewed_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ''',
      [
        codepoint,
        mode,
        rating,
        mistakes,
        hintsUsed,
        reviewedAt.toUtc().toIso8601String(),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // User Settings CRUD
  // ---------------------------------------------------------------------------

  AppSettings loadSettings() {
    final rows = _db.select('SELECT key, value FROM user_settings');
    final map = <String, String>{
      for (final r in rows) r['key'] as String: r['value'] as String,
    };

    final leniencyName = map['leniency'] ?? LeniencyPreset.normal.name;
    final leniency = LeniencyPreset.values.firstWhere(
      (e) => e.name == leniencyName,
      orElse: () => LeniencyPreset.normal,
    );

    return AppSettings(
      leniency: leniency,
      hintsEnabled: (map['hints_enabled'] ?? 'true') == 'true',
      hapticsEnabled: (map['haptics_enabled'] ?? 'true') == 'true',
      dailyNewCardsLimit: int.tryParse(map['daily_new_limit'] ?? '10') ?? 10,
    );
  }

  void saveSettings(AppSettings settings) {
    final entries = {
      'leniency': settings.leniency.name,
      'hints_enabled': settings.hintsEnabled.toString(),
      'haptics_enabled': settings.hapticsEnabled.toString(),
      'daily_new_limit': settings.dailyNewCardsLimit.toString(),
    };
    final stmt = _db.prepare('''
      INSERT INTO user_settings (key, value) VALUES (?, ?)
      ON CONFLICT(key) DO UPDATE SET value = excluded.value
    ''');
    try {
      for (final entry in entries.entries) {
        stmt.execute([entry.key, entry.value]);
      }
    } finally {
      stmt.dispose();
    }
  }

  // ---------------------------------------------------------------------------
  // Backup & Restore (Fix #11: survives app reinstall & schema migrations)
  // ---------------------------------------------------------------------------

  String exportBackupJson() {
    final cards = _db.select('SELECT * FROM srs_cards ORDER BY codepoint, mode');
    final logs = _db.select('SELECT * FROM review_logs ORDER BY id ASC');
    final settings = _db.select('SELECT * FROM user_settings ORDER BY key ASC');

    final payload = {
      'schema_version': schemaVersion,
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'srs_cards': cards,
      'review_logs': logs,
      'user_settings': settings,
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  void importBackupJson(String jsonString) {
    final decoded = jsonDecode(jsonString) as Map<String, dynamic>;
    final cards = (decoded['srs_cards'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    final logs = (decoded['review_logs'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    final settings = (decoded['user_settings'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();

    _db.execute('BEGIN TRANSACTION;');
    try {
      _db.execute('DELETE FROM srs_cards;');
      _db.execute('DELETE FROM review_logs;');
      _db.execute('DELETE FROM user_settings;');

      for (final c in cards) {
        upsertCard(UserCardProgress.fromMap(c));
      }
      for (final l in logs) {
        insertReviewLog(
          codepoint: l['codepoint'] as int,
          mode: l['mode'] as String,
          rating: l['rating'] as int,
          mistakes: l['mistakes'] as int,
          hintsUsed: l['hints_used'] as int,
          reviewedAt: DateTime.parse(l['reviewed_at'] as String),
        );
      }
      for (final s in settings) {
        _db.execute(
          'INSERT INTO user_settings (key, value) VALUES (?, ?)',
          [s['key'] as String, s['value'] as String],
        );
      }
      _db.execute('COMMIT;');
    } catch (e) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  void close() => _db.dispose();
}
