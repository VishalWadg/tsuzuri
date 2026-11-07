import '../../matching/stroke_matcher.dart';

/// Abstract provider interface for Kanji stroke geometry and stroke order vector data.
abstract interface class IKanjiStrokeSource {
  /// Unique machine-readable identifier for this stroke source (e.g. 'bundled_strokes').
  String get sourceId;

  /// Human-readable display name (e.g. 'Bundled KanjiVG Strokes').
  String get displayName;

  /// Semantic version string (e.g. '1.0.0').
  String get version;

  /// Whether this source represents the zero-configuration bundled default.
  bool get isBundledDefault;

  /// Returns the ordered list of reference strokes for [codepoint], or null if not contained.
  Future<List<ReferenceStroke>?> getStrokes(int codepoint);

  /// Fast check for whether this source contains stroke data for [codepoint].
  Future<bool> containsStrokes(int codepoint);
}
