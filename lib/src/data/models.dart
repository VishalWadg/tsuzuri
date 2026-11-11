import 'dart:convert';
import 'dart:typed_data';
import '../matching/point2d.dart';
import '../matching/stroke_matcher.dart';

/// Immutable domain model for a Kanji entry from the read-only Content DB.
class KanjiCharacter {
  final int codepoint;
  final String literal;
  final int strokeCount;
  final int? grade;
  final int? jlptLevel;
  final int? frequency;
  final List<String> onyomi;
  final List<String> kunyomi;
  final List<String> meanings;
  final List<ReferenceStroke> strokes;

  const KanjiCharacter({
    required this.codepoint,
    required this.literal,
    required this.strokeCount,
    this.grade,
    this.jlptLevel,
    this.frequency,
    required this.onyomi,
    required this.kunyomi,
    required this.meanings,
    required this.strokes,
  });

  String get unicodeHex => 'U+${codepoint.toRadixString(16).toUpperCase().padLeft(4, '0')}';

  factory KanjiCharacter.fromRow(
    Map<String, Object?> row,
    List<ReferenceStroke> strokes,
  ) {
    return KanjiCharacter(
      codepoint: row['codepoint'] as int,
      literal: row['literal'] as String,
      strokeCount: row['stroke_count'] as int,
      grade: row['grade'] as int?,
      jlptLevel: row['jlpt_level'] as int?,
      frequency: row['frequency'] as int?,
      onyomi: (jsonDecode(row['onyomi_json'] as String) as List<dynamic>).cast<String>(),
      kunyomi: (jsonDecode(row['kunyomi_json'] as String) as List<dynamic>).cast<String>(),
      meanings: (jsonDecode(row['meanings_json'] as String) as List<dynamic>).cast<String>(),
      strokes: strokes,
    );
  }

  static ReferenceStroke strokeFromRow(Map<String, Object?> row) {
    final blob = row['sampled_points_blob'] as Uint8List;
    return ReferenceStroke(
      strokeOrder: row['stroke_order'] as int,
      strokeType: (row['stroke_type'] as String?) ?? '',
      svgPath: row['svg_path'] as String,
      arcLength: (row['arc_length'] as num).toDouble(),
      sampledPoints: StrokeGeometry.unpackPointsBlob(blob),
    );
  }
}

/// Practice modality key (Fix #9: each `(codepoint, mode)` pair is an isolated FSRS card).
class PracticeMode {
  static const String writing = 'writing';
  static const String reading = 'reading'; // Post-v1
  static const String audio = 'audio'; // Post-v1
}

/// Stored FSRS card state in the writable User DB, keyed by `(codepoint, mode)` (Fix #1, #2, #9).
class UserCardProgress {
  final int codepoint;
  final String mode;
  final DateTime dueDate;
  final double stability;
  final double difficulty;
  final int elapsedDays;
  final int scheduledDays;
  final int reps;
  final int lapses;
  final int state; // 0: new, 1: learning, 2: review, 3: relearning
  final DateTime? lastReview;

  const UserCardProgress({
    required this.codepoint,
    required this.mode,
    required this.dueDate,
    required this.stability,
    required this.difficulty,
    required this.elapsedDays,
    required this.scheduledDays,
    required this.reps,
    required this.lapses,
    required this.state,
    this.lastReview,
  });

  Map<String, Object?> toMap() => {
        'codepoint': codepoint,
        'mode': mode,
        'due_date': dueDate.toUtc().toIso8601String(),
        'stability': stability,
        'difficulty': difficulty,
        'elapsed_days': elapsedDays,
        'scheduled_days': scheduledDays,
        'reps': reps,
        'lapses': lapses,
        'state': state,
        'last_review': lastReview?.toUtc().toIso8601String(),
      };

  factory UserCardProgress.fromMap(Map<String, Object?> map) {
    return UserCardProgress(
      codepoint: map['codepoint'] as int,
      mode: map['mode'] as String,
      dueDate: DateTime.parse(map['due_date'] as String).toUtc(),
      stability: (map['stability'] as num).toDouble(),
      difficulty: (map['difficulty'] as num).toDouble(),
      elapsedDays: map['elapsed_days'] as int,
      scheduledDays: map['scheduled_days'] as int,
      reps: map['reps'] as int,
      lapses: map['lapses'] as int,
      state: map['state'] as int,
      lastReview: map['last_review'] != null
          ? DateTime.parse(map['last_review'] as String).toUtc()
          : null,
    );
  }
}

/// Theme mode setting for the app.
enum AppThemeMode {
  system('System (Phone default)'),
  light('Light'),
  dark('Dark');

  final String label;
  const AppThemeMode(this.label);
}

/// Audio playback speed preset for spoken Japanese prompts.
enum AudioSpeed {
  normal('Normal', 0.5),
  slow('Slow', 0.32);

  final String label;
  final double rate;
  const AudioSpeed(this.label, this.rate);
}

/// User preferences stored in the writable User DB.
class AppSettings {
  final LeniencyPreset leniency;
  final bool hintsEnabled;
  final bool hapticsEnabled;
  final int dailyNewCardsLimit;
  final AppThemeMode themeMode;
  final AudioSpeed audioSpeed;
  final bool audioAutoplay;

  const AppSettings({
    this.leniency = LeniencyPreset.normal,
    this.hintsEnabled = true,
    this.hapticsEnabled = true,
    this.dailyNewCardsLimit = 10,
    this.themeMode = AppThemeMode.system,
    this.audioSpeed = AudioSpeed.normal,
    this.audioAutoplay = true,
  });

  AppSettings copyWith({
    LeniencyPreset? leniency,
    bool? hintsEnabled,
    bool? hapticsEnabled,
    int? dailyNewCardsLimit,
    AppThemeMode? themeMode,
    AudioSpeed? audioSpeed,
    bool? audioAutoplay,
  }) {
    return AppSettings(
      leniency: leniency ?? this.leniency,
      hintsEnabled: hintsEnabled ?? this.hintsEnabled,
      hapticsEnabled: hapticsEnabled ?? this.hapticsEnabled,
      dailyNewCardsLimit: dailyNewCardsLimit ?? this.dailyNewCardsLimit,
      themeMode: themeMode ?? this.themeMode,
      audioSpeed: audioSpeed ?? this.audioSpeed,
      audioAutoplay: audioAutoplay ?? this.audioAutoplay,
    );
  }
}

/// Origin type of an installed custom content source package.
enum SourceOriginType {
  offlineArchive('offline_archive', 'Offline Archive (.zip)'),
  offlineDir('offline_dir', 'Offline Folder'),
  offlineJson('offline_json', 'Offline JSON'),
  onlineUrl('online_url', 'Online URL');

  final String dbKey;
  final String label;
  const SourceOriginType(this.dbKey, this.label);

  static SourceOriginType fromDbKey(String value) {
    return SourceOriginType.values.firstWhere(
      (e) => e.dbKey == value,
      orElse: () => SourceOriginType.offlineArchive,
    );
  }
}

/// Persistent registration record for an installed custom content source in `user_progress.db`.
class InstalledSourceRecord {
  final String sourceId;
  final String name;
  final String version;
  final SourceOriginType originType;
  final String? originUri;
  final String packageDir;
  final List<String> capabilities;
  final int priority;
  final bool enabled;
  final DateTime installedAt;

  const InstalledSourceRecord({
    required this.sourceId,
    required this.name,
    required this.version,
    required this.originType,
    this.originUri,
    required this.packageDir,
    required this.capabilities,
    required this.priority,
    required this.enabled,
    required this.installedAt,
  });

  InstalledSourceRecord copyWith({
    String? sourceId,
    String? name,
    String? version,
    SourceOriginType? originType,
    String? originUri,
    String? packageDir,
    List<String>? capabilities,
    int? priority,
    bool? enabled,
    DateTime? installedAt,
  }) {
    return InstalledSourceRecord(
      sourceId: sourceId ?? this.sourceId,
      name: name ?? this.name,
      version: version ?? this.version,
      originType: originType ?? this.originType,
      originUri: originUri ?? this.originUri,
      packageDir: packageDir ?? this.packageDir,
      capabilities: capabilities ?? this.capabilities,
      priority: priority ?? this.priority,
      enabled: enabled ?? this.enabled,
      installedAt: installedAt ?? this.installedAt,
    );
  }

  Map<String, Object?> toMap() => {
        'source_id': sourceId,
        'name': name,
        'version': version,
        'origin_type': originType.dbKey,
        'origin_uri': originUri,
        'package_dir': packageDir,
        'capabilities_json': jsonEncode(capabilities),
        'priority': priority,
        'enabled': enabled ? 1 : 0,
        'installed_at': installedAt.toUtc().toIso8601String(),
      };

  factory InstalledSourceRecord.fromMap(Map<String, Object?> map) {
    final rawCaps = map['capabilities_json'] as String? ?? '[]';
    final caps = (jsonDecode(rawCaps) as List<dynamic>).map((e) => e.toString()).toList();
    return InstalledSourceRecord(
      sourceId: map['source_id'] as String,
      name: map['name'] as String,
      version: map['version'] as String,
      originType: SourceOriginType.fromDbKey(map['origin_type'] as String? ?? 'offline_archive'),
      originUri: map['origin_uri'] as String?,
      packageDir: map['package_dir'] as String,
      capabilities: List.unmodifiable(caps),
      priority: (map['priority'] as num).toInt(),
      enabled: (map['enabled'] as num).toInt() != 0,
      installedAt: DateTime.parse(map['installed_at'] as String).toUtc(),
    );
  }
}
