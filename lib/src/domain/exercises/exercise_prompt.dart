import '../../content/contracts/kanji_audio_source.dart';

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

/// Validates that [codepoint] is a valid Unicode scalar value.
///
/// Must be positive, <= 0x10FFFF, and outside the surrogate range (0xD800–0xDFFF).
bool isValidUnicodeScalar(int codepoint) {
  return codepoint > 0 &&
      codepoint <= 0x10FFFF &&
      (codepoint < 0xD800 || codepoint > 0xDFFF);
}

/// Sealed base class for all exercise prompts.
sealed class ExercisePrompt {
  final int codepoint;
  final String literal;

  const ExercisePrompt({
    required this.codepoint,
    required this.literal,
  });
}

/// Concrete sealed variant representing a Meaning-based writing prompt.
final class MeaningPrompt extends ExercisePrompt {
  final List<String> meanings;
  final List<String> onyomi;
  final List<String> kunyomi;
  final int strokeCount;

  MeaningPrompt({
    required super.codepoint,
    required super.literal,
    required List<String> meanings,
    required List<String> onyomi,
    required List<String> kunyomi,
    required this.strokeCount,
  })  : meanings = List<String>.unmodifiable(meanings),
        onyomi = List<String>.unmodifiable(onyomi),
        kunyomi = List<String>.unmodifiable(kunyomi) {
    if (!isValidUnicodeScalar(codepoint)) {
      throw ArgumentError.value(
        codepoint,
        'codepoint',
        'Must be a valid Unicode scalar value (1..0x10FFFF, excluding 0xD800..0xDFFF)',
      );
    }
    if (literal.trim().isEmpty) {
      throw ArgumentError.value(literal, 'literal', 'Kanji character literal cannot be empty');
    }
    if (this.meanings.isEmpty) {
      throw ArgumentError.value(meanings, 'meanings', 'At least one meaning must be provided');
    }
    if (this.meanings.any((m) => m.trim().isEmpty)) {
      throw ArgumentError.value(meanings, 'meanings', 'Meanings cannot contain empty strings');
    }
    if (strokeCount <= 0) {
      throw ArgumentError.value(strokeCount, 'strokeCount', 'Stroke count must be positive');
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MeaningPrompt &&
          runtimeType == other.runtimeType &&
          codepoint == other.codepoint &&
          literal == other.literal &&
          _listEquals(meanings, other.meanings) &&
          _listEquals(onyomi, other.onyomi) &&
          _listEquals(kunyomi, other.kunyomi) &&
          strokeCount == other.strokeCount;

  @override
  int get hashCode => Object.hash(
        codepoint,
        literal,
        Object.hashAll(meanings),
        Object.hashAll(onyomi),
        Object.hashAll(kunyomi),
        strokeCount,
      );
}

/// Concrete sealed variant representing an Audio-based writing prompt.
final class AudioPrompt extends ExercisePrompt {
  final String spokenText;
  final List<String> hiddenMeanings;
  final int strokeCount;
  final AudioPronunciation? audioPronunciation;

  AudioPrompt({
    required super.codepoint,
    required super.literal,
    required this.spokenText,
    required List<String> hiddenMeanings,
    required this.strokeCount,
    this.audioPronunciation,
  }) : hiddenMeanings = List<String>.unmodifiable(hiddenMeanings) {
    if (!isValidUnicodeScalar(codepoint)) {
      throw ArgumentError.value(
        codepoint,
        'codepoint',
        'Must be a valid Unicode scalar value (1..0x10FFFF, excluding 0xD800..0xDFFF)',
      );
    }
    if (literal.trim().isEmpty) {
      throw ArgumentError.value(literal, 'literal', 'Kanji character literal cannot be empty');
    }
    if (spokenText.trim().isEmpty) {
      throw ArgumentError.value(spokenText, 'spokenText', 'Spoken text cannot be empty');
    }
    if (strokeCount <= 0) {
      throw ArgumentError.value(strokeCount, 'strokeCount', 'Stroke count must be positive');
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioPrompt &&
          runtimeType == other.runtimeType &&
          codepoint == other.codepoint &&
          literal == other.literal &&
          spokenText == other.spokenText &&
          _listEquals(hiddenMeanings, other.hiddenMeanings) &&
          strokeCount == other.strokeCount &&
          audioPronunciation == other.audioPronunciation;

  @override
  int get hashCode => Object.hash(
        codepoint,
        literal,
        spokenText,
        Object.hashAll(hiddenMeanings),
        strokeCount,
        audioPronunciation,
      );
}

/// Concrete sealed variant representing a Kanji-only prompt (used in Kanji -> Meaning and Kanji -> Reading).
final class KanjiPrompt extends ExercisePrompt {
  final int strokeCount;

  KanjiPrompt({
    required super.codepoint,
    required super.literal,
    required this.strokeCount,
  }) {
    if (!isValidUnicodeScalar(codepoint)) {
      throw ArgumentError.value(
        codepoint,
        'codepoint',
        'Must be a valid Unicode scalar value (1..0x10FFFF, excluding 0xD800..0xDFFF)',
      );
    }
    if (literal.trim().isEmpty) {
      throw ArgumentError.value(literal, 'literal', 'Kanji character literal cannot be empty');
    }
    if (strokeCount <= 0) {
      throw ArgumentError.value(strokeCount, 'strokeCount', 'Stroke count must be positive');
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is KanjiPrompt &&
          runtimeType == other.runtimeType &&
          codepoint == other.codepoint &&
          literal == other.literal &&
          strokeCount == other.strokeCount;

  @override
  int get hashCode => Object.hash(codepoint, literal, strokeCount);
}
