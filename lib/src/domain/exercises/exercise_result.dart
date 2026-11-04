import 'exercise_prompt.dart';
import 'exercise_types.dart';

/// Pure outcome data carrier recording the metrics of an exercise attempt.
///
/// DOES NOT own FSRS scheduling, grade derivation, or persistence logic.
class ExerciseResult {
  final String exerciseId;
  final ExerciseType exerciseType;
  final int codepoint;
  final String literal;
  final bool isCompleted;
  final int mistakes;
  final int hintsUsed;
  final Duration elapsed;

  ExerciseResult({
    required this.exerciseId,
    required this.exerciseType,
    required this.codepoint,
    required this.literal,
    required this.isCompleted,
    required this.mistakes,
    required this.hintsUsed,
    required this.elapsed,
  }) {
    if (exerciseId.trim().isEmpty) {
      throw ArgumentError.value(exerciseId, 'exerciseId', 'Exercise id cannot be empty');
    }
    if (!isValidUnicodeScalar(codepoint)) {
      throw ArgumentError.value(codepoint, 'codepoint', 'Invalid Unicode scalar value');
    }
    if (literal.trim().isEmpty) {
      throw ArgumentError.value(literal, 'literal', 'Literal cannot be empty');
    }
    if (mistakes < 0) {
      throw ArgumentError.value(mistakes, 'mistakes', 'Mistakes cannot be negative');
    }
    if (hintsUsed < 0) {
      throw ArgumentError.value(hintsUsed, 'hintsUsed', 'Hints used cannot be negative');
    }
    if (elapsed < Duration.zero) {
      throw ArgumentError.value(elapsed, 'elapsed', 'Elapsed duration cannot be negative');
    }
  }

  /// Computed getter guaranteeing internal state consistency with mistakes and hints.
  bool get isFirstAttemptClean => mistakes == 0 && hintsUsed == 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ExerciseResult &&
          runtimeType == other.runtimeType &&
          exerciseId == other.exerciseId &&
          exerciseType == other.exerciseType &&
          codepoint == other.codepoint &&
          literal == other.literal &&
          isCompleted == other.isCompleted &&
          mistakes == other.mistakes &&
          hintsUsed == other.hintsUsed &&
          elapsed == other.elapsed;

  @override
  int get hashCode => Object.hash(
        exerciseId,
        exerciseType,
        codepoint,
        literal,
        isCompleted,
        mistakes,
        hintsUsed,
        elapsed,
      );
}
