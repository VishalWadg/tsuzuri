import 'package:flutter_test/flutter_test.dart';
import 'package:offline_kanji_practice/src/data/models.dart';
import 'package:offline_kanji_practice/src/domain/exercises/exercise_answer_method.dart';
import 'package:offline_kanji_practice/src/domain/exercises/exercise_definition.dart';
import 'package:offline_kanji_practice/src/domain/exercises/exercise_prompt.dart';
import 'package:offline_kanji_practice/src/domain/exercises/exercise_result.dart';
import 'package:offline_kanji_practice/src/domain/exercises/exercise_types.dart';
import 'package:offline_kanji_practice/src/matching/point2d.dart';
import 'package:offline_kanji_practice/src/matching/stroke_matcher.dart';
import 'package:offline_kanji_practice/src/services/exercise_engine.dart';
import 'package:offline_kanji_practice/src/ui/screens/practice_screen.dart';

void main() {
  group('Milestone 1: Domain Enums and Types', () {
    test('SkillType maps writingRecall to SQLite key and rejects unsupported skills', () {
      expect(SkillType.writingRecall.dbKey, equals('writing'));

      expect(() => SkillType.meaningRecognition.dbKey, throwsUnsupportedError);
      expect(() => SkillType.readingRecognition.dbKey, throwsUnsupportedError);
      expect(() => SkillType.listeningRecognition.dbKey, throwsUnsupportedError);
      expect(() => SkillType.writingDiagnostic.dbKey, throwsUnsupportedError);
    });

    test('ExerciseType correctly exposes activity and primarySkill', () {
      expect(ExerciseType.meaningToKanji.activity, equals(ExerciseActivity.writing));
      expect(ExerciseType.meaningToKanji.primarySkill, equals(SkillType.writingRecall));
      expect(ExerciseActivity.writing.displayName, equals('Writing Practice'));
      expect(ExerciseActivity.recognition.displayName, equals('Recognition Practice'));
    });
  });

  group('Milestone 1: MeaningPrompt & Unicode Scalar Validation', () {
    test('Creates valid MeaningPrompt and verifies immutability', () {
      final prompt = MeaningPrompt(
        codepoint: 0x5341, // 十
        literal: '十',
        meanings: const ['ten'],
        onyomi: const ['JUU'],
        kunyomi: const ['to'],
        strokeCount: 2,
      );

      expect(prompt.codepoint, equals(0x5341));
      expect(prompt.literal, equals('十'));
      expect(prompt.meanings, equals(['ten']));
      expect(prompt.strokeCount, equals(2));

      // Collection immutability
      expect(() => prompt.meanings.add('decade'), throwsUnsupportedError);
      expect(() => prompt.onyomi.add('JI'), throwsUnsupportedError);
      expect(() => prompt.kunyomi.add('too'), throwsUnsupportedError);
    });

    test('Validates Unicode scalar range', () {
      expect(isValidUnicodeScalar(0x5341), isTrue);
      expect(isValidUnicodeScalar(0x10FFFF), isTrue); // Max valid
      expect(isValidUnicodeScalar(0), isFalse);
      expect(isValidUnicodeScalar(-1), isFalse);
      expect(isValidUnicodeScalar(0xD800), isFalse); // Surrogate min
      expect(isValidUnicodeScalar(0xDFFF), isFalse); // Surrogate max
      expect(isValidUnicodeScalar(0x110000), isFalse); // Above max
    });

    test('Rejects invalid MeaningPrompt parameters', () {
      // Invalid codepoint (surrogate)
      expect(
        () => MeaningPrompt(
          codepoint: 0xD800,
          literal: 'X',
          meanings: const ['bad'],
          onyomi: const [],
          kunyomi: const [],
          strokeCount: 1,
        ),
        throwsArgumentError,
      );

      // Empty literal
      expect(
        () => MeaningPrompt(
          codepoint: 0x5341,
          literal: '  ',
          meanings: const ['ten'],
          onyomi: const [],
          kunyomi: const [],
          strokeCount: 2,
        ),
        throwsArgumentError,
      );

      // Empty meanings
      expect(
        () => MeaningPrompt(
          codepoint: 0x5341,
          literal: '十',
          meanings: const [],
          onyomi: const [],
          kunyomi: const [],
          strokeCount: 2,
        ),
        throwsArgumentError,
      );

      // Empty meaning string in list
      expect(
        () => MeaningPrompt(
          codepoint: 0x5341,
          literal: '十',
          meanings: const [''],
          onyomi: const [],
          kunyomi: const [],
          strokeCount: 2,
        ),
        throwsArgumentError,
      );

      // Non-positive stroke count
      expect(
        () => MeaningPrompt(
          codepoint: 0x5341,
          literal: '十',
          meanings: const ['ten'],
          onyomi: const [],
          kunyomi: const [],
          strokeCount: 0,
        ),
        throwsArgumentError,
      );
    });

    test('Value equality works for MeaningPrompt', () {
      final p1 = MeaningPrompt(
        codepoint: 0x5341,
        literal: '十',
        meanings: const ['ten'],
        onyomi: const ['JUU'],
        kunyomi: const ['to'],
        strokeCount: 2,
      );
      final p2 = MeaningPrompt(
        codepoint: 0x5341,
        literal: '十',
        meanings: const ['ten'],
        onyomi: const ['JUU'],
        kunyomi: const ['to'],
        strokeCount: 2,
      );

      expect(p1, equals(p2));
      expect(p1.hashCode, equals(p2.hashCode));
    });
  });

  group('Milestone 2: AudioPrompt & Validation', () {
    test('Creates valid AudioPrompt and verifies immutability', () {
      final prompt = AudioPrompt(
        codepoint: 0x5341,
        literal: '十',
        spokenText: 'JUU',
        hiddenMeanings: const ['ten'],
        strokeCount: 2,
      );

      expect(prompt.codepoint, equals(0x5341));
      expect(prompt.literal, equals('十'));
      expect(prompt.spokenText, equals('JUU'));
      expect(prompt.hiddenMeanings, equals(['ten']));
      expect(prompt.strokeCount, equals(2));

      expect(() => prompt.hiddenMeanings.add('decade'), throwsUnsupportedError);
    });

    test('Rejects invalid AudioPrompt arguments', () {
      expect(
        () => AudioPrompt(
          codepoint: 0x5341,
          literal: '十',
          spokenText: '  ',
          hiddenMeanings: const ['ten'],
          strokeCount: 2,
        ),
        throwsArgumentError,
      );

      expect(
        () => AudioPrompt(
          codepoint: 0xD800,
          literal: '十',
          spokenText: 'JUU',
          hiddenMeanings: const ['ten'],
          strokeCount: 2,
        ),
        throwsArgumentError,
      );
    });

    test('Value equality works for AudioPrompt', () {
      final p1 = AudioPrompt(
        codepoint: 0x5341,
        literal: '十',
        spokenText: 'JUU',
        hiddenMeanings: const ['ten'],
        strokeCount: 2,
      );
      final p2 = AudioPrompt(
        codepoint: 0x5341,
        literal: '十',
        spokenText: 'JUU',
        hiddenMeanings: const ['ten'],
        strokeCount: 2,
      );

      expect(p1, equals(p2));
      expect(p1.hashCode, equals(p2.hashCode));
    });
  });

  group('Milestone 1: HandwritingAnswerMethod', () {
    const dummyStroke = ReferenceStroke(
      strokeOrder: 1,
      strokeType: 'h',
      svgPath: 'M0,0 L10,10',
      arcLength: 14.14,
      sampledPoints: [Point2D(0, 0), Point2D(10, 10)],
    );

    test('Creates valid HandwritingAnswerMethod and ensures collection immutability', () {
      final method = HandwritingAnswerMethod(
        referenceStrokes: const [dummyStroke],
        leniency: LeniencyPreset.strict,
        hintsEnabled: true,
        hapticsEnabled: false,
      );

      expect(method.totalStrokes, equals(1));
      expect(method.leniency, equals(LeniencyPreset.strict));
      expect(method.hintsEnabled, isTrue);
      expect(method.hapticsEnabled, isFalse);
      expect(() => method.referenceStrokes.add(dummyStroke), throwsUnsupportedError);
    });

    test('Rejects empty reference strokes list', () {
      expect(
        () => HandwritingAnswerMethod(referenceStrokes: const []),
        throwsArgumentError,
      );
    });
  });

  group('Milestone 1: ExerciseDefinition', () {
    const dummyStroke = ReferenceStroke(
      strokeOrder: 1,
      strokeType: 'h',
      svgPath: 'M0,0 L10,10',
      arcLength: 14.14,
      sampledPoints: [Point2D(0, 0), Point2D(10, 10)],
    );

    const validCharacter = KanjiCharacter(
      codepoint: 0x5341,
      literal: '十',
      strokeCount: 1,
      meanings: ['ten'],
      onyomi: ['JUU'],
      kunyomi: ['to'],
      strokes: [dummyStroke],
    );

    test('Creates valid ExerciseDefinition with strict M1 combination', () {
      final prompt = MeaningPrompt(
        codepoint: 0x5341,
        literal: '十',
        meanings: const ['ten'],
        onyomi: const ['JUU'],
        kunyomi: const ['to'],
        strokeCount: 1,
      );
      final answerMethod = HandwritingAnswerMethod(
        referenceStrokes: const [dummyStroke],
      );

      final def = ExerciseDefinition(
        id: 'test_1',
        exerciseType: ExerciseType.meaningToKanji,
        skillType: SkillType.writingRecall,
        character: validCharacter,
        prompt: prompt,
        answerMethod: answerMethod,
      );

      expect(def.id, equals('test_1'));
      expect(def.activity, equals(ExerciseActivity.writing));
    });

    test('Rejects invalid ExerciseDefinition combinations', () {
      final prompt = MeaningPrompt(
        codepoint: 0x5341,
        literal: '十',
        meanings: const ['ten'],
        onyomi: const ['JUU'],
        kunyomi: const ['to'],
        strokeCount: 1,
      );
      final answerMethod = HandwritingAnswerMethod(
        referenceStrokes: const [dummyStroke],
      );

      // Codepoint mismatch
      const mismatchedChar = KanjiCharacter(
        codepoint: 0x4E00,
        literal: '一',
        strokeCount: 1,
        meanings: ['one'],
        onyomi: ['ICHI'],
        kunyomi: ['hito'],
        strokes: [dummyStroke],
      );

      expect(
        () => ExerciseDefinition(
          id: 'test_mismatch',
          exerciseType: ExerciseType.meaningToKanji,
          skillType: SkillType.writingRecall,
          character: mismatchedChar,
          prompt: prompt,
          answerMethod: answerMethod,
        ),
        throwsArgumentError,
      );

      // Unsupported skill type for M1
      expect(
        () => ExerciseDefinition(
          id: 'test_skill_mismatch',
          exerciseType: ExerciseType.meaningToKanji,
          skillType: SkillType.readingRecognition,
          character: validCharacter,
          prompt: prompt,
          answerMethod: answerMethod,
        ),
        throwsArgumentError,
      );
    });
  });

  group('Milestone 1: ExerciseResult', () {
    test('Computes isFirstAttemptClean correctly and records metrics', () {
      final cleanResult = ExerciseResult(
        exerciseId: 'ex_1',
        exerciseType: ExerciseType.meaningToKanji,
        codepoint: 0x5341,
        literal: '十',
        isCompleted: true,
        mistakes: 0,
        hintsUsed: 0,
        elapsed: const Duration(seconds: 4),
      );

      expect(cleanResult.isFirstAttemptClean, isTrue);

      final dirtyResult = ExerciseResult(
        exerciseId: 'ex_2',
        exerciseType: ExerciseType.meaningToKanji,
        codepoint: 0x5341,
        literal: '十',
        isCompleted: true,
        mistakes: 1,
        hintsUsed: 0,
        elapsed: const Duration(seconds: 5),
      );

      expect(dirtyResult.isFirstAttemptClean, isFalse);

      final hintResult = ExerciseResult(
        exerciseId: 'ex_3',
        exerciseType: ExerciseType.meaningToKanji,
        codepoint: 0x5341,
        literal: '十',
        isCompleted: true,
        mistakes: 0,
        hintsUsed: 1,
        elapsed: const Duration(seconds: 6),
      );

      expect(hintResult.isFirstAttemptClean, isFalse);
    });

    test('Rejects negative values and invalid codepoints', () {
      expect(
        () => ExerciseResult(
          exerciseId: 'ex_neg',
          exerciseType: ExerciseType.meaningToKanji,
          codepoint: 0x5341,
          literal: '十',
          isCompleted: true,
          mistakes: -1,
          hintsUsed: 0,
          elapsed: Duration.zero,
        ),
        throwsArgumentError,
      );

      expect(
        () => ExerciseResult(
          exerciseId: 'ex_surrogate',
          exerciseType: ExerciseType.meaningToKanji,
          codepoint: 0xD800,
          literal: '十',
          isCompleted: true,
          mistakes: 0,
          hintsUsed: 0,
          elapsed: Duration.zero,
        ),
        throwsArgumentError,
      );
    });
  });

  group('Milestone 1: ExerciseEngine Factory', () {
    const dummyStroke = ReferenceStroke(
      strokeOrder: 1,
      strokeType: 'h',
      svgPath: 'M0,0 L10,10',
      arcLength: 14.14,
      sampledPoints: [Point2D(0, 0), Point2D(10, 10)],
    );

    const kanji = KanjiCharacter(
      codepoint: 0x5341,
      literal: '十',
      strokeCount: 1,
      meanings: ['ten'],
      onyomi: ['JUU'],
      kunyomi: ['to'],
      strokes: [dummyStroke],
    );

    test('createMeaningWritingExercise builds full definition with settings', () {
      final def = ExerciseEngine.createMeaningWritingExercise(
        kanji: kanji,
        leniency: LeniencyPreset.strict,
        hintsEnabled: false,
        hapticsEnabled: true,
      );

      expect(def.exerciseType, equals(ExerciseType.meaningToKanji));
      expect(def.skillType, equals(SkillType.writingRecall));
      expect(def.prompt, isA<MeaningPrompt>());
      expect(def.answerMethod, isA<HandwritingAnswerMethod>());

      final hw = def.answerMethod as HandwritingAnswerMethod;
      expect(hw.leniency, equals(LeniencyPreset.strict));
      expect(hw.hintsEnabled, isFalse);
      expect(hw.hapticsEnabled, isTrue);
    });

    test('createAudioWritingExercise builds valid audio definition', () {
      final def = ExerciseEngine.createAudioWritingExercise(
        kanji: kanji,
        leniency: LeniencyPreset.forgiving,
        hintsEnabled: true,
        hapticsEnabled: false,
      );

      expect(def.exerciseType, equals(ExerciseType.audioToKanji));
      expect(def.skillType, equals(SkillType.writingRecall));
      expect(def.prompt, isA<AudioPrompt>());
      final audioPrompt = def.prompt as AudioPrompt;
      expect(audioPrompt.spokenText, equals('JUU'));
      expect(audioPrompt.hiddenMeanings, equals(['ten']));

      final hw = def.answerMethod as HandwritingAnswerMethod;
      expect(hw.leniency, equals(LeniencyPreset.forgiving));
      expect(hw.hintsEnabled, isTrue);
      expect(hw.hapticsEnabled, isFalse);
    });
  });

  group('Milestone 1: PracticeScreen Constructor XOR Validation', () {
    test('Throws AssertionError if neither queue nor exercises is provided', () {
      expect(
        () => PracticeScreen(queue: null, exercises: null),
        throwsAssertionError,
      );
    });

    test('Throws AssertionError if both queue and exercises are provided', () {
      expect(
        () => PracticeScreen(queue: const [], exercises: const []),
        throwsAssertionError,
      );
    });

    test('Succeeds when exactly one parameter is provided', () {
      expect(() => const PracticeScreen(queue: []), returnsNormally);
      expect(() => const PracticeScreen(exercises: []), returnsNormally);
    });
  });
}
