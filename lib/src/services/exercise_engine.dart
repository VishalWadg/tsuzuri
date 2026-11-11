import 'dart:math' as math;
import '../content/contracts/kanji_audio_source.dart';
import '../content/contracts/kanji_metadata_source.dart';
import '../content/registry/content_repository.dart';
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

  static String _canonicalSpokenText(KanjiCharacter kanji) {
    if (kanji.onyomi.isNotEmpty) return kanji.onyomi.first;
    if (kanji.kunyomi.isNotEmpty) return kanji.kunyomi.first;
    return kanji.literal;
  }

  static MultipleChoiceAnswerMethod _buildShuffledMultipleChoice({
    required String correctAnswer,
    required List<String> distractors,
    required String explanation,
    math.Random? random,
  }) {
    final uniqueOptions = <String>[correctAnswer];
    final seen = <String>{correctAnswer};
    for (final d in distractors) {
      final trimmed = d.trim();
      if (trimmed.isNotEmpty && seen.add(trimmed)) {
        uniqueOptions.add(trimmed);
      }
    }
    // Guarantee at least 2 options if a small custom source lacks enough distractors
    if (uniqueOptions.length < 2) {
      uniqueOptions.add(correctAnswer == '—' ? '(other)' : '—');
    }
    uniqueOptions.shuffle(random);
    return MultipleChoiceAnswerMethod(
      options: uniqueOptions,
      correctOptionIndex: uniqueOptions.indexOf(correctAnswer),
      explanation: explanation,
    );
  }

  /// Constructs an [ExerciseDefinition] for Audio → Write Kanji practice.
  static ExerciseDefinition createAudioWritingExercise({
    required KanjiCharacter kanji,
    LeniencyPreset leniency = LeniencyPreset.normal,
    bool hintsEnabled = true,
    bool hapticsEnabled = true,
    AudioPronunciation? audioPronunciation,
    String? id,
  }) {
    final spoken = _canonicalSpokenText(kanji);

    final prompt = AudioPrompt(
      codepoint: kanji.codepoint,
      literal: kanji.literal,
      spokenText: spoken,
      hiddenMeanings: kanji.meanings,
      strokeCount: kanji.strokeCount,
      audioPronunciation: audioPronunciation,
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
    AudioPronunciation? audioPronunciation,
    math.Random? random,
    String? id,
  }) {
    final spoken = _canonicalSpokenText(kanji);

    final prompt = AudioPrompt(
      codepoint: kanji.codepoint,
      literal: kanji.literal,
      spokenText: spoken,
      hiddenMeanings: kanji.meanings,
      strokeCount: kanji.strokeCount,
      audioPronunciation: audioPronunciation,
    );

    final correctAnswer = kanji.meanings.first;
    final distractors = contentDb.generateMeaningDistractors(kanji, count: 3);
    final answerMethod = _buildShuffledMultipleChoice(
      correctAnswer: correctAnswer,
      distractors: distractors,
      explanation: 'Spoken pronunciation "$spoken" belongs to "${kanji.literal}" ($correctAnswer).',
      random: random,
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

  /// Asynchronous repository-aware factory that resolves custom distractors and
  /// custom audio sources across the [ContentRepository] fallback chain.
  static Future<ExerciseDefinition> createExerciseAsync({
    required KanjiCharacter kanji,
    required PracticeConfiguration config,
    ContentRepository? repository,
    ContentDatabase? contentDb,
    math.Random? random,
    String? id,
  }) async {
    final spoken = _canonicalSpokenText(kanji);
    AudioPronunciation? resolvedAudio;
    if (repository != null &&
        (config.exerciseType == ExerciseType.audioToKanji ||
            config.exerciseType == ExerciseType.audioToMeaning)) {
      resolvedAudio = await repository.resolveAudio(kanji.codepoint, reading: spoken);
    }

    if (config.exerciseType.activity == ExerciseActivity.writing) {
      if (config.exerciseType == ExerciseType.audioToKanji) {
        return createAudioWritingExercise(
          kanji: kanji,
          leniency: config.leniency,
          hintsEnabled: config.hintsEnabled,
          hapticsEnabled: config.hapticsEnabled,
          audioPronunciation: resolvedAudio,
          id: id,
        );
      }
      return createExercise(
        kanji: kanji,
        config: config,
        contentDb: contentDb,
        random: random,
        id: id,
      );
    }

    final metaEntry = KanjiMetadataEntry.fromKanjiCharacter(kanji);
    final effectiveDb = contentDb ?? repository?.bundledContentDatabase;

    switch (config.exerciseType) {
      case ExerciseType.kanjiToMeaning:
        final correctAnswer = kanji.meanings.first;
        final distractors = repository != null
            ? await repository.generateMeaningDistractors(metaEntry, count: 3)
            : (effectiveDb != null
                ? effectiveDb.generateMeaningDistractors(kanji, count: 3)
                : throw UnsupportedError('repository or contentDb required'));
        return ExerciseDefinition(
          id: id ?? 'kanji_meaning_${kanji.codepoint}',
          exerciseType: ExerciseType.kanjiToMeaning,
          skillType: SkillType.meaningRecognition,
          character: kanji,
          prompt: KanjiPrompt(
            codepoint: kanji.codepoint,
            literal: kanji.literal,
            strokeCount: kanji.strokeCount,
          ),
          answerMethod: _buildShuffledMultipleChoice(
            correctAnswer: correctAnswer,
            distractors: distractors,
            explanation: 'Primary meaning of "${kanji.literal}" is "$correctAnswer".',
            random: random,
          ),
        );

      case ExerciseType.kanjiToReading:
        final distractors = repository != null
            ? await repository.generateReadingDistractors(metaEntry, count: 3)
            : (effectiveDb != null
                ? effectiveDb.generateReadingDistractors(kanji, count: 3)
                : throw UnsupportedError('repository or contentDb required'));
        return ExerciseDefinition(
          id: id ?? 'kanji_reading_${kanji.codepoint}',
          exerciseType: ExerciseType.kanjiToReading,
          skillType: SkillType.readingRecognition,
          character: kanji,
          prompt: KanjiPrompt(
            codepoint: kanji.codepoint,
            literal: kanji.literal,
            strokeCount: kanji.strokeCount,
          ),
          answerMethod: _buildShuffledMultipleChoice(
            correctAnswer: spoken,
            distractors: distractors,
            explanation: 'Canonical reading for "${kanji.literal}" is "$spoken".',
            random: random,
          ),
        );

      case ExerciseType.meaningToReading:
        final distractors = repository != null
            ? await repository.generateReadingDistractors(metaEntry, count: 3)
            : (effectiveDb != null
                ? effectiveDb.generateReadingDistractors(kanji, count: 3)
                : throw UnsupportedError('repository or contentDb required'));
        return ExerciseDefinition(
          id: id ?? 'meaning_reading_${kanji.codepoint}',
          exerciseType: ExerciseType.meaningToReading,
          skillType: SkillType.readingRecognition,
          character: kanji,
          prompt: MeaningPrompt(
            codepoint: kanji.codepoint,
            literal: kanji.literal,
            meanings: kanji.meanings,
            onyomi: kanji.onyomi,
            kunyomi: kanji.kunyomi,
            strokeCount: kanji.strokeCount,
          ),
          answerMethod: _buildShuffledMultipleChoice(
            correctAnswer: spoken,
            distractors: distractors,
            explanation: 'Reading for "${kanji.literal}" (${kanji.meanings.first}) is "$spoken".',
            random: random,
          ),
        );

      case ExerciseType.audioToMeaning:
        final correctAnswer = kanji.meanings.first;
        final distractors = repository != null
            ? await repository.generateMeaningDistractors(metaEntry, count: 3)
            : (effectiveDb != null
                ? effectiveDb.generateMeaningDistractors(kanji, count: 3)
                : throw UnsupportedError('repository or contentDb required'));
        return ExerciseDefinition(
          id: id ?? 'audio_meaning_${kanji.codepoint}',
          exerciseType: ExerciseType.audioToMeaning,
          skillType: SkillType.meaningRecognition,
          character: kanji,
          prompt: AudioPrompt(
            codepoint: kanji.codepoint,
            literal: kanji.literal,
            spokenText: spoken,
            hiddenMeanings: kanji.meanings,
            strokeCount: kanji.strokeCount,
            audioPronunciation: resolvedAudio,
          ),
          answerMethod: _buildShuffledMultipleChoice(
            correctAnswer: correctAnswer,
            distractors: distractors,
            explanation: 'Spoken pronunciation "$spoken" belongs to "${kanji.literal}" ($correctAnswer).',
            random: random,
          ),
        );

      default:
        return createExercise(
          kanji: kanji,
          config: config,
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
    final eligible = config.exerciseType.activity == ExerciseActivity.writing
        ? characters.where((c) => c.strokes.isNotEmpty)
        : characters;
    final capped = eligible.take(config.cardLimit).toList();
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

  /// Repository-aware async queue builder supporting custom audio, metadata, and distractors.
  static Future<List<ExerciseDefinition>> createSessionQueueAsync({
    required List<KanjiCharacter> characters,
    required PracticeConfiguration config,
    ContentRepository? repository,
    ContentDatabase? contentDb,
    math.Random? random,
  }) async {
    final eligible = config.exerciseType.activity == ExerciseActivity.writing
        ? characters.where((c) => c.strokes.isNotEmpty)
        : characters;
    final capped = eligible.take(config.cardLimit).toList();

    final exercises = <ExerciseDefinition>[];
    for (var index = 0; index < capped.length; index++) {
      final ex = await createExerciseAsync(
        kanji: capped[index],
        config: config,
        repository: repository,
        contentDb: contentDb,
        random: random,
        id: 'session_${config.exerciseType.name}_${capped[index].codepoint}_$index',
      );
      exercises.add(ex);
    }
    return exercises;
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
