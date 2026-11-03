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

/// User preferences stored in the writable User DB.
class AppSettings {
  final LeniencyPreset leniency;
  final bool hintsEnabled;
  final bool hapticsEnabled;
  final int dailyNewCardsLimit;
  final AppThemeMode themeMode;

  const AppSettings({
    this.leniency = LeniencyPreset.normal,
    this.hintsEnabled = true,
    this.hapticsEnabled = true,
    this.dailyNewCardsLimit = 10,
    this.themeMode = AppThemeMode.system,
  });

  AppSettings copyWith({
    LeniencyPreset? leniency,
    bool? hintsEnabled,
    bool? hapticsEnabled,
    int? dailyNewCardsLimit,
    AppThemeMode? themeMode,
  }) {
    return AppSettings(
      leniency: leniency ?? this.leniency,
      hintsEnabled: hintsEnabled ?? this.hintsEnabled,
      hapticsEnabled: hapticsEnabled ?? this.hapticsEnabled,
      dailyNewCardsLimit: dailyNewCardsLimit ?? this.dailyNewCardsLimit,
      themeMode: themeMode ?? this.themeMode,
    );
  }
}
