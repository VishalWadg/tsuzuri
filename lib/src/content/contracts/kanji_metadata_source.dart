import '../../data/models.dart';
import '../../matching/stroke_matcher.dart';

/// Helper for pure-Dart list equality without Flutter foundation dependency.
bool _listEquals<T>(List<T>? a, List<T>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Immutable domain model representing Kanji character dictionary metadata.
class KanjiMetadataEntry {
  /// Standard Unicode scalar integer value (e.g. 0x4E00 for '一').
  final int codepoint;

  /// Single-character literal glyph (e.g. '一').
  final String literal;

  /// Official total stroke count.
  final int strokeCount;

  /// Japanese school grade level (1..6 for Kyōiku, 8/9 for Jōyō/Jinmeiyō, null for others).
  final int? grade;

  /// Japanese Language Proficiency Test level (5..1, null if none).
  final int? jlptLevel;

  /// Frequency ranking in standard corpora (e.g. 1..2501+, null if unranked).
  final int? frequency;

  /// On'yomi (Sino-Japanese) readings in Katakana.
  final List<String> onyomi;

  /// Kun'yomi (native Japanese) readings in Hiragana.
  final List<String> kunyomi;

  /// English meanings.
  final List<String> meanings;

  /// Optional Kangxi radical glyph or representation (e.g. '一').
  final String? radical;

  const KanjiMetadataEntry({
    required this.codepoint,
    required this.literal,
    required this.strokeCount,
    this.grade,
    this.jlptLevel,
    this.frequency,
    this.onyomi = const [],
    this.kunyomi = const [],
    this.meanings = const [],
    this.radical,
  });

  /// Standard Unicode hexadecimal representation (e.g. 'U+4E00').
  String get unicodeHex =>
      'U+${codepoint.toRadixString(16).toUpperCase().padLeft(4, '0')}';

  /// Assembles a legacy [KanjiCharacter] instance combining this metadata entry
  /// with an optional or resolved list of [ReferenceStroke] vectors.
  KanjiCharacter toKanjiCharacter({
    List<ReferenceStroke> strokes = const [],
  }) {
    return KanjiCharacter(
      codepoint: codepoint,
      literal: literal,
      strokeCount: strokeCount,
      grade: grade,
      jlptLevel: jlptLevel,
      frequency: frequency,
      onyomi: onyomi,
      kunyomi: kunyomi,
      meanings: meanings,
      strokes: strokes,
    );
  }

  /// Factory creating a [KanjiMetadataEntry] from an existing [KanjiCharacter].
  factory KanjiMetadataEntry.fromKanjiCharacter(
    KanjiCharacter character, {
    String? radical,
  }) {
    return KanjiMetadataEntry(
      codepoint: character.codepoint,
      literal: character.literal,
      strokeCount: character.strokeCount,
      grade: character.grade,
      jlptLevel: character.jlptLevel,
      frequency: character.frequency,
      onyomi: character.onyomi,
      kunyomi: character.kunyomi,
      meanings: character.meanings,
      radical: radical,
    );
  }

  /// Converts this metadata entry to a map suitable for JSON serialization.
  Map<String, Object?> toMap() => {
        'codepoint': codepoint,
        'literal': literal,
        'stroke_count': strokeCount,
        'grade': grade,
        'jlpt_level': jlptLevel,
        'frequency': frequency,
        'onyomi': onyomi,
        'kunyomi': kunyomi,
        'meanings': meanings,
        'radical': radical,
      };

  /// Constructs a [KanjiMetadataEntry] from a dynamic map.
  factory KanjiMetadataEntry.fromMap(Map<String, Object?> map) {
    return KanjiMetadataEntry(
      codepoint: map['codepoint'] as int,
      literal: map['literal'] as String,
      strokeCount: (map['stroke_count'] ?? map['strokeCount']) as int,
      grade: map['grade'] as int?,
      jlptLevel: (map['jlpt_level'] ?? map['jlptLevel']) as int?,
      frequency: map['frequency'] as int?,
      onyomi: ((map['onyomi'] as List<dynamic>?) ?? const []).cast<String>(),
      kunyomi: ((map['kunyomi'] as List<dynamic>?) ?? const []).cast<String>(),
      meanings: ((map['meanings'] as List<dynamic>?) ?? const []).cast<String>(),
      radical: map['radical'] as String?,
    );
  }

  KanjiMetadataEntry copyWith({
    int? codepoint,
    String? literal,
    int? strokeCount,
    int? grade,
    int? jlptLevel,
    int? frequency,
    List<String>? onyomi,
    List<String>? kunyomi,
    List<String>? meanings,
    String? radical,
  }) {
    return KanjiMetadataEntry(
      codepoint: codepoint ?? this.codepoint,
      literal: literal ?? this.literal,
      strokeCount: strokeCount ?? this.strokeCount,
      grade: grade ?? this.grade,
      jlptLevel: jlptLevel ?? this.jlptLevel,
      frequency: frequency ?? this.frequency,
      onyomi: onyomi ?? this.onyomi,
      kunyomi: kunyomi ?? this.kunyomi,
      meanings: meanings ?? this.meanings,
      radical: radical ?? this.radical,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is KanjiMetadataEntry &&
          runtimeType == other.runtimeType &&
          codepoint == other.codepoint &&
          literal == other.literal &&
          strokeCount == other.strokeCount &&
          grade == other.grade &&
          jlptLevel == other.jlptLevel &&
          frequency == other.frequency &&
          _listEquals(onyomi, other.onyomi) &&
          _listEquals(kunyomi, other.kunyomi) &&
          _listEquals(meanings, other.meanings) &&
          radical == other.radical;

  @override
  int get hashCode => Object.hash(
        codepoint,
        literal,
        strokeCount,
        grade,
        jlptLevel,
        frequency,
        Object.hashAll(onyomi),
        Object.hashAll(kunyomi),
        Object.hashAll(meanings),
        radical,
      );

  @override
  String toString() =>
      'KanjiMetadataEntry(codepoint: $unicodeHex, literal: "$literal", strokeCount: $strokeCount)';
}

/// Abstract provider interface for Kanji dictionary and character metadata.
abstract interface class IKanjiMetadataSource {
  /// Unique machine-readable identifier for this metadata source (e.g. 'bundled_metadata').
  String get sourceId;

  /// Human-readable display name (e.g. 'Bundled Kanji Metadata').
  String get displayName;

  /// Semantic version string (e.g. '1.0.0').
  String get version;

  /// Whether this source represents the zero-configuration bundled default.
  bool get isBundledDefault;

  /// Returns the dictionary metadata for [codepoint], or null if not contained.
  Future<KanjiMetadataEntry?> getMetadata(int codepoint);

  /// Returns all available Unicode codepoints provided by this source in presentation order.
  Future<List<int>> getAllCodepoints();

  /// Returns the total count of unique kanji characters provided by this source.
  Future<int> getCharacterCount();

  /// Generates plausible distractor English meanings for [target], prioritizing same grade / JLPT level.
  Future<List<String>> generateMeaningDistractors(
    KanjiMetadataEntry target, {
    int count = 3,
  });

  /// Generates plausible distractor readings (on'yomi / kun'yomi) for [target].
  Future<List<String>> generateReadingDistractors(
    KanjiMetadataEntry target, {
    int count = 3,
  });
}
