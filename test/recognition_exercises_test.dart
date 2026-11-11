import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_kanji_practice/src/data/content_db.dart';
import 'package:offline_kanji_practice/src/data/models.dart';
import 'package:offline_kanji_practice/src/data/user_db.dart';
import 'package:offline_kanji_practice/src/domain/exercises/exercise_answer_method.dart';
import 'package:offline_kanji_practice/src/domain/exercises/exercise_definition.dart';
import 'package:offline_kanji_practice/src/domain/exercises/exercise_prompt.dart';
import 'package:offline_kanji_practice/src/domain/exercises/exercise_types.dart';
import 'package:offline_kanji_practice/src/providers/app_providers.dart';
import 'package:offline_kanji_practice/src/scheduling/fsrs_scheduler.dart';
import 'package:offline_kanji_practice/src/services/exercise_engine.dart';
import 'package:offline_kanji_practice/src/services/speech_service.dart';
import 'package:offline_kanji_practice/src/ui/screens/practice_screen.dart';
import 'package:offline_kanji_practice/src/ui/widgets/multiple_choice_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Milestone 5: Database Schema v3 & Multi-Skill FSRS Isolation', () {
    late UserDatabase userDb;
    late FsrsSchedulerService scheduler;

    setUp(() {
      userDb = UserDatabase.openInMemory();
      scheduler = FsrsSchedulerService();
    });

    tearDown(() {
      userDb.close();
    });

    test('UserDatabase initializes with currentSchemaVersion == 4 (upgraded from v3) and writing_metrics table', () {
      expect(userDb.schemaVersion, equals(4));
      expect(UserDatabase.currentSchemaVersion, equals(4));

      // Verify writing_metrics can accept records
      userDb.insertWritingMetric(
        codepoint: 0x5341,
        exerciseType: 'referenceCopy',
        shapeScore: 0.94,
        orderErrors: 0,
        retries: 1,
        durationMs: 4500,
        recordedAt: DateTime.now(),
      );

      final metrics = userDb.getWritingMetrics(0x5341);
      expect(metrics.length, equals(1));
      expect(metrics.first['exercise_type'], equals('referenceCopy'));
      expect(metrics.first['shape_score'], closeTo(0.94, 1e-4));
    });

    test('Writing card and Recognition card coexist independently for same Kanji (Multi-Skill Isolation)', () {
      final now = DateTime.utc(2026, 11, 4, 12, 0);

      // Record a Writing practice completion for 十 (0x5341)
      scheduler.recordPracticeCompletion(
        userDb: userDb,
        codepoint: 0x5341,
        mistakes: 0,
        hintsUsed: 0,
        mode: SkillType.writingRecall.v3DbKey, // 'writing'
        now: now,
      );

      // Record a Meaning Recognition completion for 十 (0x5341)
      scheduler.recordPracticeCompletion(
        userDb: userDb,
        codepoint: 0x5341,
        mistakes: 3, // struggled with recognition
        hintsUsed: 0,
        mode: SkillType.meaningRecognition.v3DbKey, // 'meaning_rec'
        now: now,
      );

      // Verify each card is stored independently under its own skill mode
      final loadedWriting = userDb.getCard(0x5341, mode: 'writing');
      final loadedMeaning = userDb.getCard(0x5341, mode: 'meaning_rec');

      expect(loadedWriting, isNotNull);
      expect(loadedMeaning, isNotNull);

      expect(loadedWriting!.mode, equals('writing'));
      expect(loadedMeaning!.mode, equals('meaning_rec'));

      // Writing had 0 mistakes -> higher stability than Meaning with 3 mistakes
      expect(loadedWriting.stability, greaterThan(loadedMeaning.stability));
      expect(loadedWriting.lapses, equals(0));
      expect(loadedMeaning.lapses, equals(1));
    });

    test('SkillType.v3DbKey mapping satisfies Schema v3 requirements', () {
      expect(SkillType.writingRecall.v3DbKey, equals('writing'));
      expect(SkillType.meaningRecognition.v3DbKey, equals('meaning_rec'));
      expect(SkillType.readingRecognition.v3DbKey, equals('reading_rec'));
      expect(SkillType.listeningRecognition.v3DbKey, equals('listening_rec'));
      expect(SkillType.writingDiagnostic.v3DbKey, equals('writing_diag'));
    });
  });

  group('Milestone 5: Recognition Domain Models & Distractor Generation', () {
    late ContentDatabase contentDb;
    late KanjiCharacter tenKanji;

    setUp(() {
      contentDb = ContentDatabase.openFromFile(File('assets/db/kanji_content.db'));
      final loaded = contentDb.getKanjiByCodepoint(0x5341); // 十
      expect(loaded, isNotNull);
      tenKanji = loaded!;
    });

    tearDown(() {
      contentDb.close();
    });

    test('KanjiPrompt constructor and validation', () {
      final prompt = KanjiPrompt(
        codepoint: 0x5341,
        literal: '十',
        strokeCount: 2,
      );

      expect(prompt.codepoint, equals(0x5341));
      expect(prompt.literal, equals('十'));
      expect(prompt.strokeCount, equals(2));

      expect(() => KanjiPrompt(codepoint: -1, literal: '十', strokeCount: 2), throwsArgumentError);
      expect(() => KanjiPrompt(codepoint: 0x5341, literal: '', strokeCount: 2), throwsArgumentError);
      expect(() => KanjiPrompt(codepoint: 0x5341, literal: '十', strokeCount: 0), throwsArgumentError);
    });

    test('MultipleChoiceAnswerMethod constructor and validation', () {
      final method = MultipleChoiceAnswerMethod(
        options: const ['ten', 'one', 'two', 'three'],
        correctOptionIndex: 0,
        explanation: 'Primary meaning is ten',
      );

      expect(method.options.length, equals(4));
      expect(method.correctOption, equals('ten'));
      expect(method.answerType, equals(AnswerType.multipleChoice));

      // Range error for invalid index
      expect(
        () => MultipleChoiceAnswerMethod(options: const ['a', 'b'], correctOptionIndex: 3),
        throwsRangeError,
      );
      // Argument error for < 2 options
      expect(
        () => MultipleChoiceAnswerMethod(options: const ['only'], correctOptionIndex: 0),
        throwsArgumentError,
      );
    });

    test('ContentDatabase.generateMeaningDistractors returns distinct non-overlapping meanings', () {
      final distractors = contentDb.generateMeaningDistractors(tenKanji, count: 3);

      expect(distractors.length, equals(3));
      // Distinct distractors
      expect(distractors.toSet().length, equals(3));
      // Does not contain any meaning of the target
      for (final m in tenKanji.meanings) {
        expect(distractors.contains(m), isFalse);
      }
    });

    test('ContentDatabase.generateReadingDistractors returns distinct non-overlapping readings', () {
      final distractors = contentDb.generateReadingDistractors(tenKanji, count: 3);

      expect(distractors.length, equals(3));
      expect(distractors.toSet().length, equals(3));
      final targetReadings = {...tenKanji.onyomi, ...tenKanji.kunyomi};
      for (final r in targetReadings) {
        expect(distractors.contains(r), isFalse);
      }
    });

    test('ContentDatabase.generateKanjiDistractors returns distinct literals', () {
      final distractors = contentDb.generateKanjiDistractors(tenKanji, count: 3);

      expect(distractors.length, equals(3));
      expect(distractors.toSet().length, equals(3));
      expect(distractors.contains('十'), isFalse);
    });
  });

  group('Milestone 5: ExerciseEngine Recognition Factories', () {
    late ContentDatabase contentDb;
    late KanjiCharacter tenKanji;

    setUp(() {
      contentDb = ContentDatabase.openFromFile(File('assets/db/kanji_content.db'));
      final loaded = contentDb.getKanjiByCodepoint(0x5341);
      expect(loaded, isNotNull);
      tenKanji = loaded!;
    });

    tearDown(() {
      contentDb.close();
    });

    test('createKanjiToMeaningExercise builds valid ExerciseDefinition', () {
      final exercise = ExerciseEngine.createKanjiToMeaningExercise(
        kanji: tenKanji,
        contentDb: contentDb,
      );

      expect(exercise.exerciseType, equals(ExerciseType.kanjiToMeaning));
      expect(exercise.activity, equals(ExerciseActivity.recognition));
      expect(exercise.skillType, equals(SkillType.meaningRecognition));
      expect(exercise.prompt, isA<KanjiPrompt>());
      expect(exercise.answerMethod, isA<MultipleChoiceAnswerMethod>());

      final mc = exercise.answerMethod as MultipleChoiceAnswerMethod;
      expect(mc.options.length, equals(4));
      expect(mc.options[mc.correctOptionIndex], equals(tenKanji.meanings.first));
    });

    test('createKanjiToReadingExercise builds valid ExerciseDefinition', () {
      final exercise = ExerciseEngine.createKanjiToReadingExercise(
        kanji: tenKanji,
        contentDb: contentDb,
      );

      expect(exercise.exerciseType, equals(ExerciseType.kanjiToReading));
      expect(exercise.activity, equals(ExerciseActivity.recognition));
      expect(exercise.skillType, equals(SkillType.readingRecognition));
      expect(exercise.prompt, isA<KanjiPrompt>());
      expect(exercise.answerMethod, isA<MultipleChoiceAnswerMethod>());

      final mc = exercise.answerMethod as MultipleChoiceAnswerMethod;
      expect(mc.options.length, equals(4));
      expect(mc.options[mc.correctOptionIndex], equals(tenKanji.onyomi.first));
    });

    test('createAudioToMeaningExercise builds valid ExerciseDefinition', () {
      final exercise = ExerciseEngine.createAudioToMeaningExercise(
        kanji: tenKanji,
        contentDb: contentDb,
      );

      expect(exercise.exerciseType, equals(ExerciseType.audioToMeaning));
      expect(exercise.activity, equals(ExerciseActivity.recognition));
      expect(exercise.skillType, equals(SkillType.meaningRecognition));
      expect(exercise.prompt, isA<AudioPrompt>());
      expect(exercise.answerMethod, isA<MultipleChoiceAnswerMethod>());

      final mc = exercise.answerMethod as MultipleChoiceAnswerMethod;
      expect(mc.options.length, equals(4));
      expect(mc.options[mc.correctOptionIndex], equals(tenKanji.meanings.first));
    });
  });

  group('Milestone 5: MultipleChoiceCard & PracticeScreen Integration Suite', () {
    late ContentDatabase contentDb;
    late UserDatabase userDb;
    late FakeSpeechService fakeSpeechService;
    late KanjiCharacter tenKanji;

    setUpAll(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('com.tsuzuri.kanji/feedback'),
        (call) async => true,
      );
    });

    setUp(() {
      userDb = UserDatabase.openInMemory();
      contentDb = ContentDatabase.openFromFile(File('assets/db/kanji_content.db'));
      fakeSpeechService = FakeSpeechService();

      final loaded = contentDb.getKanjiByCodepoint(0x5341);
      expect(loaded, isNotNull);
      tenKanji = loaded!;
    });

    tearDown(() {
      userDb.close();
      contentDb.close();
    });

    Widget createTestApp(List<ExerciseDefinition> exercises) {
      return ProviderScope(
        overrides: [
          contentDatabaseProvider.overrideWithValue(contentDb),
          userDatabaseProvider.overrideWithValue(userDb),
          speechServiceProvider.overrideWithValue(fakeSpeechService),
        ],
        child: MaterialApp(
          home: PracticeScreen(exercises: exercises),
        ),
      );
    }

    testWidgets('MultipleChoiceCard renders options and shows visual feedback on tap', (tester) async {
      int? selected;
      bool? correct;

      final answerMethod = MultipleChoiceAnswerMethod(
        options: const ['ten', 'one', 'two', 'three'],
        correctOptionIndex: 0,
        explanation: 'Primary meaning of 十 is ten.',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MultipleChoiceCard(
              answerMethod: answerMethod,
              hasAnswered: false,
              selectedIndex: null,
              onOptionSelected: (idx, isCorr) {
                selected = idx;
                correct = isCorr;
              },
            ),
          ),
        ),
      );

      expect(find.byKey(const Key('option_button_0')), findsOneWidget);
      expect(find.byKey(const Key('option_button_1')), findsOneWidget);
      expect(find.byKey(const Key('option_button_2')), findsOneWidget);
      expect(find.byKey(const Key('option_button_3')), findsOneWidget);

      await tester.tap(find.byKey(const Key('option_button_0')));
      await tester.pump();

      expect(selected, equals(0));
      expect(correct, isTrue);
    });

    testWidgets('PracticeScreen executes complete Kanji -> Meaning recognition flow and persists FSRS card', (tester) async {
      // Deterministic option index: pass fixed random seed
      final exercise = ExerciseEngine.createKanjiToMeaningExercise(
        kanji: tenKanji,
        contentDb: contentDb,
        random: math.Random(42),
      );

      final mc = exercise.answerMethod as MultipleChoiceAnswerMethod;
      final correctIdx = mc.correctOptionIndex;

      await tester.pumpWidget(createTestApp([exercise]));
      await tester.pumpAndSettle();

      // Verify Kanji prompt shows character '十'
      expect(find.text('十'), findsOneWidget);
      expect(find.text('Recognition Practice (1 / 1)'), findsOneWidget);

      // Verify options are rendered
      expect(find.byKey(Key('option_button_$correctIdx')), findsOneWidget);

      // Tap the correct option button
      await tester.tap(find.byKey(Key('option_button_$correctIdx')));
      await tester.pumpAndSettle();

      // Verify explanation banner and completion card appear
      expect(find.textContaining('Completed「十」'), findsOneWidget);
      expect(find.textContaining('FSRS Grade: Easy'), findsOneWidget);
      expect(find.text('Finish Session'), findsOneWidget);

      // Verify FSRS persistence under skill mode 'meaning_rec'
      final card = userDb.getCard(0x5341, mode: 'meaning_rec');
      expect(card, isNotNull);
      expect(card!.mode, equals('meaning_rec'));
      expect(card.reps, equals(1));
      expect(card.lapses, equals(0));

      // Tap Finish Session
      await tester.ensureVisible(find.text('Finish Session'));
      await tester.tap(find.text('Finish Session'));
      await tester.pumpAndSettle();
    });
  });
}
