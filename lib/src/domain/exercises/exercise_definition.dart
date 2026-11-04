import '../../data/models.dart';
import 'exercise_answer_method.dart';
import 'exercise_prompt.dart';
import 'exercise_types.dart';

/// Immutable definition of an exercise ready for presentation and evaluation.
///
/// In Milestone 1, explicitly validates that the single supported combination is used:
/// meaningToKanji + writingRecall + MeaningPrompt + HandwritingAnswerMethod.
class ExerciseDefinition {
  final String id;
  final ExerciseType exerciseType;
  final SkillType skillType;
  final KanjiCharacter character;
  final ExercisePrompt prompt;
  final ExerciseAnswerMethod answerMethod;

  ExerciseDefinition({
    required this.id,
    required this.exerciseType,
    required this.skillType,
    required this.character,
    required this.prompt,
    required this.answerMethod,
  }) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'Exercise id cannot be empty');
    }
    if (!isValidUnicodeScalar(character.codepoint)) {
      throw ArgumentError.value(
        character.codepoint,
        'character.codepoint',
        'Invalid Unicode scalar value',
      );
    }
    if (character.codepoint != prompt.codepoint) {
      throw ArgumentError(
        'Character codepoint (${character.codepoint}) must match prompt codepoint (${prompt.codepoint})',
      );
    }
    if (character.literal != prompt.literal) {
      throw ArgumentError(
        'Character literal (${character.literal}) must match prompt literal (${prompt.literal})',
      );
    }

    // Supported writing combinations (M1: Meaning, M2: Audio, M3: Copy & Guided)
    final isValidMeaningWriting = exerciseType == ExerciseType.meaningToKanji &&
        activity == ExerciseActivity.writing &&
        skillType == SkillType.writingRecall &&
        prompt is MeaningPrompt &&
        answerMethod is HandwritingAnswerMethod;

    final isValidAudioWriting = exerciseType == ExerciseType.audioToKanji &&
        activity == ExerciseActivity.writing &&
        skillType == SkillType.writingRecall &&
        prompt is AudioPrompt &&
        answerMethod is HandwritingAnswerMethod;

    final method = answerMethod;
    final isValidCopyWriting = exerciseType == ExerciseType.referenceCopy &&
        activity == ExerciseActivity.writing &&
        skillType == SkillType.writingDiagnostic &&
        prompt is MeaningPrompt &&
        method is HandwritingAnswerMethod &&
        method.showFullReference;

    final isValidGuidedWriting = exerciseType == ExerciseType.guidedStrokeWriting &&
        activity == ExerciseActivity.writing &&
        skillType == SkillType.writingRecall &&
        prompt is MeaningPrompt &&
        method is HandwritingAnswerMethod &&
        method.guidedMode;

    // Supported recognition combinations (M5: Recognition)
    final isValidKanjiToMeaning = exerciseType == ExerciseType.kanjiToMeaning &&
        activity == ExerciseActivity.recognition &&
        skillType == SkillType.meaningRecognition &&
        prompt is KanjiPrompt &&
        answerMethod is MultipleChoiceAnswerMethod;

    final isValidKanjiToReading = exerciseType == ExerciseType.kanjiToReading &&
        activity == ExerciseActivity.recognition &&
        skillType == SkillType.readingRecognition &&
        prompt is KanjiPrompt &&
        answerMethod is MultipleChoiceAnswerMethod;

    final isValidMeaningToReading = exerciseType == ExerciseType.meaningToReading &&
        activity == ExerciseActivity.recognition &&
        skillType == SkillType.readingRecognition &&
        prompt is MeaningPrompt &&
        answerMethod is MultipleChoiceAnswerMethod;

    final isValidAudioToMeaning = exerciseType == ExerciseType.audioToMeaning &&
        activity == ExerciseActivity.recognition &&
        skillType == SkillType.meaningRecognition &&
        prompt is AudioPrompt &&
        answerMethod is MultipleChoiceAnswerMethod;

    if (!isValidMeaningWriting &&
        !isValidAudioWriting &&
        !isValidCopyWriting &&
        !isValidGuidedWriting &&
        !isValidKanjiToMeaning &&
        !isValidKanjiToReading &&
        !isValidMeaningToReading &&
        !isValidAudioToMeaning) {
      throw ArgumentError(
        'Unsupported exercise combination: $exerciseType with prompt ${prompt.runtimeType} '
        'and skill $skillType',
      );
    }
  }

  ExerciseActivity get activity => exerciseType.activity;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ExerciseDefinition &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          exerciseType == other.exerciseType &&
          skillType == other.skillType &&
          character.codepoint == other.character.codepoint;

  @override
  int get hashCode => Object.hash(id, exerciseType, skillType, character.codepoint);
}
