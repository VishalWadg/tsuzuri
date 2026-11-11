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
  static const int currentSchemaVersion = 4;
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

    if (version < 3) {
      // Schema v3 migration: adds writing_metrics table for non-SRS diagnostic telemetry
      _db.execute('''
        CREATE TABLE IF NOT EXISTS writing_metrics (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          codepoint INTEGER NOT NULL,
          exercise_type TEXT NOT NULL,
          shape_score REAL NOT NULL,
          order_errors INTEGER NOT NULL,
          retries INTEGER NOT NULL,
          duration_ms INTEGER NOT NULL,
          recorded_at TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_writing_metrics_codepoint
          ON writing_metrics(codepoint);
      ''');
      _db.execute('PRAGMA user_version = 3;');
    }

    if (version < 4) {
      // Schema v4 migration: adds installed_sources table to persist modular content packs across launches
      _db.execute('''
        CREATE TABLE IF NOT EXISTS installed_sources (
          source_id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          version TEXT NOT NULL,
          origin_type TEXT NOT NULL,
          origin_uri TEXT,
          package_dir TEXT NOT NULL,
          capabilities_json TEXT NOT NULL,
          priority INTEGER NOT NULL,
          enabled INTEGER NOT NULL DEFAULT 1,
          installed_at TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_installed_sources_priority
          ON installed_sources(priority DESC, installed_at ASC);
      ''');
      _db.execute('PRAGMA user_version = 4;');
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

  void insertWritingMetric({
    required int codepoint,
    required String exerciseType,
    required double shapeScore,
    required int orderErrors,
    required int retries,
    required int durationMs,
    required DateTime recordedAt,
  }) {
    _db.execute(
      '''
      INSERT INTO writing_metrics (
        codepoint, exercise_type, shape_score, order_errors, retries, duration_ms, recorded_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        codepoint,
        exerciseType,
        shapeScore,
        orderErrors,
        retries,
        durationMs,
        recordedAt.toUtc().toIso8601String(),
      ],
    );
  }

  List<Map<String, Object?>> getWritingMetrics(int codepoint) {
    return _db.select(
      'SELECT * FROM writing_metrics WHERE codepoint = ? ORDER BY id DESC',
      [codepoint],
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

    final themeModeName = map['theme_mode'] ?? AppThemeMode.system.name;
    final themeMode = AppThemeMode.values.firstWhere(
      (e) => e.name == themeModeName,
      orElse: () => AppThemeMode.system,
    );

    final audioSpeedName = map['audio_speed'] ?? AudioSpeed.normal.name;
    final audioSpeed = AudioSpeed.values.firstWhere(
      (e) => e.name == audioSpeedName,
      orElse: () => AudioSpeed.normal,
    );

    return AppSettings(
      leniency: leniency,
      hintsEnabled: (map['hints_enabled'] ?? 'true') == 'true',
      hapticsEnabled: (map['haptics_enabled'] ?? 'true') == 'true',
      dailyNewCardsLimit: int.tryParse(map['daily_new_limit'] ?? '10') ?? 10,
      themeMode: themeMode,
      audioSpeed: audioSpeed,
      audioAutoplay: (map['audio_autoplay'] ?? 'true') == 'true',
    );
  }

  void saveSettings(AppSettings settings) {
    final entries = {
      'leniency': settings.leniency.name,
      'hints_enabled': settings.hintsEnabled.toString(),
      'haptics_enabled': settings.hapticsEnabled.toString(),
      'daily_new_limit': settings.dailyNewCardsLimit.toString(),
      'theme_mode': settings.themeMode.name,
      'audio_speed': settings.audioSpeed.name,
      'audio_autoplay': settings.audioAutoplay.toString(),
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
  // Active Practice Preset CRUD
  // ---------------------------------------------------------------------------

  String loadActivePresetId() {
    final rows = _db.select("SELECT value FROM user_settings WHERE key = 'active_preset_id'");
    if (rows.isEmpty) return 'standard';
    return rows.first['value'] as String;
  }

  void saveActivePresetId(String presetId) {
    final stmt = _db.prepare('''
      INSERT INTO user_settings (key, value) VALUES (?, ?)
      ON CONFLICT(key) DO UPDATE SET value = excluded.value
    ''');
    try {
      stmt.execute(['active_preset_id', presetId]);
    } finally {
      stmt.dispose();
    }
  }

  // ---------------------------------------------------------------------------
  // Installed Custom Content Sources CRUD (Schema v4)
  // ---------------------------------------------------------------------------

  void upsertInstalledSource(InstalledSourceRecord record) {
    _db.execute(
      '''
      INSERT INTO installed_sources (
        source_id, name, version, origin_type, origin_uri,
        package_dir, capabilities_json, priority, enabled, installed_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(source_id) DO UPDATE SET
        name = excluded.name,
        version = excluded.version,
        origin_type = excluded.origin_type,
        origin_uri = excluded.origin_uri,
        package_dir = excluded.package_dir,
        capabilities_json = excluded.capabilities_json,
        priority = excluded.priority,
        enabled = excluded.enabled,
        installed_at = excluded.installed_at
      ''',
      [
        record.sourceId,
        record.name,
        record.version,
        record.originType.dbKey,
        record.originUri,
        record.packageDir,
        jsonEncode(record.capabilities),
        record.priority,
        record.enabled ? 1 : 0,
        record.installedAt.toUtc().toIso8601String(),
      ],
    );
  }

  List<InstalledSourceRecord> getInstalledSources() {
    final rows = _db.select(
      'SELECT * FROM installed_sources ORDER BY priority DESC, installed_at ASC',
    );
    return rows.map(InstalledSourceRecord.fromMap).toList(growable: false);
  }

  InstalledSourceRecord? getInstalledSource(String sourceId) {
    final rows = _db.select(
      'SELECT * FROM installed_sources WHERE source_id = ?',
      [sourceId],
    );
    if (rows.isEmpty) return null;
    return InstalledSourceRecord.fromMap(rows.first);
  }

  void setInstalledSourceEnabled(String sourceId, bool enabled) {
    _db.execute(
      'UPDATE installed_sources SET enabled = ? WHERE source_id = ?',
      [enabled ? 1 : 0, sourceId],
    );
  }

  void updateInstalledSourcePriorities(Map<String, int> priorityBySourceId) {
    if (priorityBySourceId.isEmpty) return;
    _db.execute('BEGIN TRANSACTION;');
    try {
      final stmt = _db.prepare(
        'UPDATE installed_sources SET priority = ? WHERE source_id = ?',
      );
      try {
        for (final entry in priorityBySourceId.entries) {
          stmt.execute([entry.value, entry.key]);
        }
      } finally {
        stmt.dispose();
      }
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  void deleteInstalledSource(String sourceId) {
    _db.execute(
      'DELETE FROM installed_sources WHERE source_id = ?',
      [sourceId],
    );
  }

  // ---------------------------------------------------------------------------
  // Backup & Restore (Fix #11: survives app reinstall & schema migrations)
  // ---------------------------------------------------------------------------

  String exportBackupJson() {
    final cards = _db.select('SELECT * FROM srs_cards ORDER BY codepoint, mode');
    final logs = _db.select('SELECT * FROM review_logs ORDER BY id ASC');
    final settings = _db.select('SELECT * FROM user_settings ORDER BY key ASC');
    final metrics = _db.select('SELECT * FROM writing_metrics ORDER BY id ASC');
    final sources = _db.select(
      'SELECT * FROM installed_sources ORDER BY priority DESC, installed_at ASC',
    );

    final payload = {
      'schema_version': schemaVersion,
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'srs_cards': cards,
      'review_logs': logs,
      'user_settings': settings,
      'writing_metrics': metrics,
      'installed_sources': sources,
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  void importBackupJson(String jsonString) {
    final decoded = jsonDecode(jsonString) as Map<String, dynamic>;
    final cards = (decoded['srs_cards'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    final logs = (decoded['review_logs'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    final settings = (decoded['user_settings'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    final metrics = (decoded['writing_metrics'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    final hasSources = decoded.containsKey('installed_sources');
    final sources = (decoded['installed_sources'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();

    _db.execute('BEGIN TRANSACTION;');
    try {
      _db.execute('DELETE FROM srs_cards;');
      _db.execute('DELETE FROM review_logs;');
      _db.execute('DELETE FROM user_settings;');
      _db.execute('DELETE FROM writing_metrics;');
      if (hasSources) {
        _db.execute('DELETE FROM installed_sources;');
      }

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
      for (final m in metrics) {
        insertWritingMetric(
          codepoint: m['codepoint'] as int,
          exerciseType: m['exercise_type'] as String,
          shapeScore: (m['shape_score'] as num).toDouble(),
          orderErrors: m['order_errors'] as int,
          retries: m['retries'] as int,
          durationMs: m['duration_ms'] as int,
          recordedAt: DateTime.parse(m['recorded_at'] as String),
        );
      }
      if (hasSources) {
        for (final src in sources) {
          upsertInstalledSource(InstalledSourceRecord.fromMap(src));
        }
      }
      _db.execute('COMMIT;');
    } catch (e) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  void close() => _db.dispose();
}
