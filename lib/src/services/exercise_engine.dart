import 'dart:math' as math;
import '../data/content_db.dart';
import '../data/models.dart';
import '../domain/exercises/exercise_answer_method.dart';
import '../domain/exercises/exercise_definition.dart';
import '../domain/exercises/exercise_prompt.dart';
import '../domain/exercises/exercise_types.dart';
import '../domain/exercises/practice_configuration.dart';
import '../matching/stroke_matcher.dart';
import '../scheduling/fsrs_scheduler.dart';

/// Pure-Dart factory responsible solely for constructing [ExerciseDefinition] instances.
///
/// DOES NOT manage session progression, own SQLite persistence, or execute FSRS scheduling.
class ExerciseEngine {
  const ExerciseEngine._();

  /// Constructs an [ExerciseDefinition] for Meaning → Write Kanji practice.
  static ExerciseDefinition createMeaningWritingExercise({
    required KanjiCharacter kanji,
    LeniencyPreset leniency = LeniencyPreset.normal,
    bool hintsEnabled = true,
    bool hapticsEnabled = true,
    String? id,
  }) {
    final prompt = MeaningPrompt(
      codepoint: kanji.codepoint,
      literal: kanji.literal,
      meanings: kanji.meanings,
      onyomi: kanji.onyomi,
      kunyomi: kanji.kunyomi,
      strokeCount: kanji.strokeCount,
    );

    final answerMethod = HandwritingAnswerMethod(
      referenceStrokes: kanji.strokes,
      leniency: leniency,
      hintsEnabled: hintsEnabled,
      hapticsEnabled: hapticsEnabled,
    );

    return ExerciseDefinition(
      id: id ?? 'meaning_write_${kanji.codepoint}',
      exerciseType: ExerciseType.meaningToKanji,
      skillType: SkillType.writingRecall,
      character: kanji,
      prompt: prompt,
      answerMethod: answerMethod,
    );
  }

  /// Constructs an [ExerciseDefinition] for Audio → Write Kanji practice.
  static ExerciseDefinition createAudioWritingExercise({
    required KanjiCharacter kanji,
    LeniencyPreset leniency = LeniencyPreset.normal,
    bool hintsEnabled = true,
    bool hapticsEnabled = true,
    String? id,
  }) {
    final spoken = kanji.onyomi.isNotEmpty
        ? kanji.onyomi.first
        : (kanji.kunyomi.isNotEmpty ? kanji.kunyomi.first : kanji.literal);

    final prompt = AudioPrompt(
      codepoint: kanji.codepoint,
      literal: kanji.literal,
      spokenText: spoken,
      hiddenMeanings: kanji.meanings,
      strokeCount: kanji.strokeCount,
    );

    final answerMethod = HandwritingAnswerMethod(
      referenceStrokes: kanji.strokes,
      leniency: leniency,
      hintsEnabled: hintsEnabled,
      hapticsEnabled: hapticsEnabled,
    );

    return ExerciseDefinition(
      id: id ?? 'audio_write_${kanji.codepoint}',
      exerciseType: ExerciseType.audioToKanji,
      skillType: SkillType.writingRecall,
      character: kanji,
      prompt: prompt,
      answerMethod: answerMethod,
    );
  }

  /// Constructs an [ExerciseDefinition] for Reference Copy Practice.
  static ExerciseDefinition createReferenceCopyExercise({
    required KanjiCharacter kanji,
    LeniencyPreset leniency = LeniencyPreset.normal,
    bool hintsEnabled = true,
    bool hapticsEnabled = true,
    String? id,
  }) {
    final prompt = MeaningPrompt(
      codepoint: kanji.codepoint,
      literal: kanji.literal,
      meanings: kanji.meanings,
      onyomi: kanji.onyomi,
      kunyomi: kanji.kunyomi,
      strokeCount: kanji.strokeCount,
    );

    final answerMethod = HandwritingAnswerMethod(
      referenceStrokes: kanji.strokes,
      leniency: leniency,
      hintsEnabled: hintsEnabled,
      hapticsEnabled: hapticsEnabled,
      showFullReference: true,
      guidedMode: false,
    );

    return ExerciseDefinition(
      id: id ?? 'copy_write_${kanji.codepoint}',
      exerciseType: ExerciseType.referenceCopy,
      skillType: SkillType.writingDiagnostic,
      character: kanji,
      prompt: prompt,
      answerMethod: answerMethod,
    );
  }

  /// Constructs an [ExerciseDefinition] for Guided Stroke-Order Practice.
  static ExerciseDefinition createGuidedWritingExercise({
    required KanjiCharacter kanji,
    LeniencyPreset leniency = LeniencyPreset.normal,
    bool hintsEnabled = true,
    bool hapticsEnabled = true,
    String? id,
  }) {
    final prompt = MeaningPrompt(
      codepoint: kanji.codepoint,
      literal: kanji.literal,
      meanings: kanji.meanings,
      onyomi: kanji.onyomi,
      kunyomi: kanji.kunyomi,
      strokeCount: kanji.strokeCount,
    );

    final answerMethod = HandwritingAnswerMethod(
      referenceStrokes: kanji.strokes,
      leniency: leniency,
      hintsEnabled: hintsEnabled,
      hapticsEnabled: hapticsEnabled,
      showFullReference: false,
      guidedMode: true,
    );

    return ExerciseDefinition(
      id: id ?? 'guided_write_${kanji.codepoint}',
      exerciseType: ExerciseType.guidedStrokeWriting,
      skillType: SkillType.writingRecall,
      character: kanji,
      prompt: prompt,
      answerMethod: answerMethod,
    );
  }

  /// Constructs an [ExerciseDefinition] for Kanji → Meaning recognition.
  static ExerciseDefinition createKanjiToMeaningExercise({
    required KanjiCharacter kanji,
    required ContentDatabase contentDb,
    math.Random? random,
    String? id,
  }) {
    final prompt = KanjiPrompt(
      codepoint: kanji.codepoint,
      literal: kanji.literal,
      strokeCount: kanji.strokeCount,
    );

    final correctAnswer = kanji.meanings.first;
    final distractors = contentDb.generateMeaningDistractors(kanji, count: 3);
    final options = [correctAnswer, ...distractors]..shuffle(random);
    final correctIndex = options.indexOf(correctAnswer);

    final answerMethod = MultipleChoiceAnswerMethod(
      options: options,
      correctOptionIndex: correctIndex,
      explanation: 'Primary meaning of "${kanji.literal}" is "$correctAnswer".',
    );

    return ExerciseDefinition(
      id: id ?? 'kanji_meaning_${kanji.codepoint}',
      exerciseType: ExerciseType.kanjiToMeaning,
      skillType: SkillType.meaningRecognition,
      character: kanji,
      prompt: prompt,
      answerMethod: answerMethod,
    );
  }

  /// Constructs an [ExerciseDefinition] for Kanji → Reading recognition.
  static ExerciseDefinition createKanjiToReadingExercise({
    required KanjiCharacter kanji,
    required ContentDatabase contentDb,
    math.Random? random,
    String? id,
  }) {
    final prompt = KanjiPrompt(
      codepoint: kanji.codepoint,
      literal: kanji.literal,
      strokeCount: kanji.strokeCount,
    );

    final correctAnswer = kanji.onyomi.isNotEmpty
        ? kanji.onyomi.first
        : (kanji.kunyomi.isNotEmpty ? kanji.kunyomi.first : kanji.literal);
    final distractors = contentDb.generateReadingDistractors(kanji, count: 3);
    final options = [correctAnswer, ...distractors]..shuffle(random);
    final correctIndex = options.indexOf(correctAnswer);

    final answerMethod = MultipleChoiceAnswerMethod(
      options: options,
      correctOptionIndex: correctIndex,
      explanation: 'Canonical reading for "${kanji.literal}" is "$correctAnswer".',
    );

    return ExerciseDefinition(
      id: id ?? 'kanji_reading_${kanji.codepoint}',
      exerciseType: ExerciseType.kanjiToReading,
      skillType: SkillType.readingRecognition,
      character: kanji,
      prompt: prompt,
      answerMethod: answerMethod,
    );
  }

  /// Constructs an [ExerciseDefinition] for Meaning → Reading recognition.
  static ExerciseDefinition createMeaningToReadingExercise({
    required KanjiCharacter kanji,
    required ContentDatabase contentDb,
    math.Random? random,
    String? id,
  }) {
    final prompt = MeaningPrompt(
      codepoint: kanji.codepoint,
      literal: kanji.literal,
      meanings: kanji.meanings,
      onyomi: kanji.onyomi,
      kunyomi: kanji.kunyomi,
      strokeCount: kanji.strokeCount,
    );

    final correctAnswer = kanji.onyomi.isNotEmpty
        ? kanji.onyomi.first
        : (kanji.kunyomi.isNotEmpty ? kanji.kunyomi.first : kanji.literal);
    final distractors = contentDb.generateReadingDistractors(kanji, count: 3);
    final options = [correctAnswer, ...distractors]..shuffle(random);
    final correctIndex = options.indexOf(correctAnswer);

    final answerMethod = MultipleChoiceAnswerMethod(
      options: options,
      correctOptionIndex: correctIndex,
      explanation: 'Reading for "${kanji.literal}" (${kanji.meanings.first}) is "$correctAnswer".',
    );

    return ExerciseDefinition(
      id: id ?? 'meaning_reading_${kanji.codepoint}',
      exerciseType: ExerciseType.meaningToReading,
      skillType: SkillType.readingRecognition,
      character: kanji,
      prompt: prompt,
      answerMethod: answerMethod,
    );
  }

  /// Constructs an [ExerciseDefinition] for Audio → Meaning recognition.
  static ExerciseDefinition createAudioToMeaningExercise({
    required KanjiCharacter kanji,
    required ContentDatabase contentDb,
    math.Random? random,
    String? id,
  }) {
    final spoken = kanji.onyomi.isNotEmpty
        ? kanji.onyomi.first
        : (kanji.kunyomi.isNotEmpty ? kanji.kunyomi.first : kanji.literal);

    final prompt = AudioPrompt(
      codepoint: kanji.codepoint,
      literal: kanji.literal,
      spokenText: spoken,
      hiddenMeanings: kanji.meanings,
      strokeCount: kanji.strokeCount,
    );

    final correctAnswer = kanji.meanings.first;
    final distractors = contentDb.generateMeaningDistractors(kanji, count: 3);
    final options = [correctAnswer, ...distractors]..shuffle(random);
    final correctIndex = options.indexOf(correctAnswer);

    final answerMethod = MultipleChoiceAnswerMethod(
      options: options,
      correctOptionIndex: correctIndex,
      explanation: 'Spoken pronunciation "$spoken" belongs to "${kanji.literal}" ($correctAnswer).',
    );

    return ExerciseDefinition(
      id: id ?? 'audio_meaning_${kanji.codepoint}',
      exerciseType: ExerciseType.audioToMeaning,
      skillType: SkillType.meaningRecognition,
      character: kanji,
      prompt: prompt,
      answerMethod: answerMethod,
    );
  }

  /// Unified factory constructing an [ExerciseDefinition] for any supported [ExerciseType]
  /// configured by a [PracticeConfiguration].
  static ExerciseDefinition createExercise({
    required KanjiCharacter kanji,
    required PracticeConfiguration config,
    ContentDatabase? contentDb,
    math.Random? random,
    String? id,
  }) {
    switch (config.exerciseType) {
      case ExerciseType.meaningToKanji:
        return createMeaningWritingExercise(
          kanji: kanji,
          leniency: config.leniency,
          hintsEnabled: config.hintsEnabled,
          hapticsEnabled: config.hapticsEnabled,
          id: id,
        );
      case ExerciseType.audioToKanji:
        return createAudioWritingExercise(
          kanji: kanji,
          leniency: config.leniency,
          hintsEnabled: config.hintsEnabled,
          hapticsEnabled: config.hapticsEnabled,
          id: id,
        );
      case ExerciseType.referenceCopy:
        return createReferenceCopyExercise(
          kanji: kanji,
          leniency: config.leniency,
          hintsEnabled: config.hintsEnabled,
          hapticsEnabled: config.hapticsEnabled,
          id: id,
        );
      case ExerciseType.guidedStrokeWriting:
        return createGuidedWritingExercise(
          kanji: kanji,
          leniency: config.leniency,
          hintsEnabled: config.hintsEnabled,
          hapticsEnabled: config.hapticsEnabled,
          id: id,
        );
      case ExerciseType.kanjiToMeaning:
        if (contentDb == null) {
          throw UnsupportedError('contentDb must be provided for Recognition exercises');
        }
        return createKanjiToMeaningExercise(
          kanji: kanji,
          contentDb: contentDb,
          random: random,
          id: id,
        );
      case ExerciseType.kanjiToReading:
        if (contentDb == null) {
          throw UnsupportedError('contentDb must be provided for Recognition exercises');
        }
        return createKanjiToReadingExercise(
          kanji: kanji,
          contentDb: contentDb,
          random: random,
          id: id,
        );
      case ExerciseType.meaningToReading:
        if (contentDb == null) {
          throw UnsupportedError('contentDb must be provided for Recognition exercises');
        }
        return createMeaningToReadingExercise(
          kanji: kanji,
          contentDb: contentDb,
          random: random,
          id: id,
        );
      case ExerciseType.audioToMeaning:
        if (contentDb == null) {
          throw UnsupportedError('contentDb must be provided for Recognition exercises');
        }
        return createAudioToMeaningExercise(
          kanji: kanji,
          contentDb: contentDb,
          random: random,
          id: id,
        );
    }
  }

  /// Builds a complete practice session queue of [ExerciseDefinition] items from
  /// a list of characters, applying [config.cardLimit] and session parameters.
  static List<ExerciseDefinition> createSessionQueue({
    required List<KanjiCharacter> characters,
    required PracticeConfiguration config,
    ContentDatabase? contentDb,
    math.Random? random,
  }) {
    final capped = characters.take(config.cardLimit).toList();
    return List.generate(
      capped.length,
      (index) => createExercise(
        kanji: capped[index],
        config: config,
        contentDb: contentDb,
        random: random,
        id: 'session_${config.exerciseType.name}_${capped[index].codepoint}_$index',
      ),
    );
  }

  /// Convenience factory constructing an [ExerciseDefinition] from a [PracticeQueueItem] and [AppSettings].
  static ExerciseDefinition fromQueueItem({
    required PracticeQueueItem item,
    required AppSettings settings,
  }) {
    return createMeaningWritingExercise(
      kanji: item.kanji,
      leniency: settings.leniency,
      hintsEnabled: settings.hintsEnabled,
      hapticsEnabled: settings.hapticsEnabled,
    );
  }
}
