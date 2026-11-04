import '../../matching/stroke_matcher.dart';
import 'exercise_types.dart';

bool _listEquals<T>(List<T>? a, List<T>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Sealed base class for exercise answer methods.
sealed class ExerciseAnswerMethod {
  final AnswerType answerType;

  const ExerciseAnswerMethod({required this.answerType});
}

/// Concrete sealed variant configuring canvas-based handwriting input.
///
/// Wraps [referenceStrokes] in [List.unmodifiable]. Elements of type [ReferenceStroke]
/// are verified to have only `final` fields and immutable [Point2D] coordinates.
final class HandwritingAnswerMethod extends ExerciseAnswerMethod {
  final List<ReferenceStroke> referenceStrokes;
  final LeniencyPreset leniency;
  final bool hintsEnabled;
  final bool hapticsEnabled;
  final bool showFullReference;
  final bool guidedMode;

  HandwritingAnswerMethod({
    required List<ReferenceStroke> referenceStrokes,
    this.leniency = LeniencyPreset.normal,
    this.hintsEnabled = true,
    this.hapticsEnabled = true,
    this.showFullReference = false,
    this.guidedMode = false,
  })  : referenceStrokes = List<ReferenceStroke>.unmodifiable(referenceStrokes),
        super(answerType: AnswerType.handwriting) {
    if (this.referenceStrokes.isEmpty) {
      throw ArgumentError.value(
        referenceStrokes,
        'referenceStrokes',
        'Reference strokes cannot be empty for handwriting practice',
      );
    }
  }

  int get totalStrokes => referenceStrokes.length;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HandwritingAnswerMethod &&
          runtimeType == other.runtimeType &&
          leniency == other.leniency &&
          hintsEnabled == other.hintsEnabled &&
          hapticsEnabled == other.hapticsEnabled &&
          showFullReference == other.showFullReference &&
          guidedMode == other.guidedMode &&
          _listEquals(referenceStrokes, other.referenceStrokes);

  @override
  int get hashCode => Object.hash(
        leniency,
        hintsEnabled,
        hapticsEnabled,
        showFullReference,
        guidedMode,
        Object.hashAll(referenceStrokes),
      );
}

/// Concrete sealed variant configuring multiple-choice recognition input.
final class MultipleChoiceAnswerMethod extends ExerciseAnswerMethod {
  final List<String> options;
  final int correctOptionIndex;
  final String? explanation;

  MultipleChoiceAnswerMethod({
    required List<String> options,
    required this.correctOptionIndex,
    this.explanation,
  })  : options = List<String>.unmodifiable(options),
        super(answerType: AnswerType.multipleChoice) {
    if (this.options.length < 2) {
      throw ArgumentError.value(
        options,
        'options',
        'Multiple choice questions must have at least 2 options',
      );
    }
    if (correctOptionIndex < 0 || correctOptionIndex >= this.options.length) {
      throw RangeError.range(
        correctOptionIndex,
        0,
        this.options.length - 1,
        'correctOptionIndex',
      );
    }
  }

  String get correctOption => options[correctOptionIndex];

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MultipleChoiceAnswerMethod &&
          runtimeType == other.runtimeType &&
          correctOptionIndex == other.correctOptionIndex &&
          explanation == other.explanation &&
          _listEquals(options, other.options);

  @override
  int get hashCode => Object.hash(
        correctOptionIndex,
        explanation,
        Object.hashAll(options),
      );
}
