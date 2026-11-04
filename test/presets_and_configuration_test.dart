import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_kanji_practice/src/data/content_db.dart';
import 'package:offline_kanji_practice/src/data/models.dart';
import 'package:offline_kanji_practice/src/data/user_db.dart';
import 'package:offline_kanji_practice/src/domain/exercises/exercise_answer_method.dart';
import 'package:offline_kanji_practice/src/domain/exercises/exercise_prompt.dart';
import 'package:offline_kanji_practice/src/domain/exercises/exercise_types.dart';
import 'package:offline_kanji_practice/src/domain/exercises/practice_configuration.dart';
import 'package:offline_kanji_practice/src/matching/stroke_matcher.dart';
import 'package:offline_kanji_practice/src/providers/app_providers.dart';
import 'package:offline_kanji_practice/src/services/exercise_engine.dart';
import 'package:offline_kanji_practice/src/services/speech_service.dart';
import 'package:offline_kanji_practice/src/ui/screens/home_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Milestone 4: PracticeConfiguration & PracticePreset Domain Models', () {
    test('Default PracticeConfiguration has expected baseline parameters', () {
      const config = PracticeConfiguration();
      expect(config.exerciseType, ExerciseType.meaningToKanji);
      expect(config.leniency, LeniencyPreset.normal);
      expect(config.hintsEnabled, isTrue);
      expect(config.hapticsEnabled, isTrue);
      expect(config.audioSpeed, AudioSpeed.normal);
      expect(config.audioAutoplay, isTrue);
      expect(config.cardLimit, 10);
    });

    test('PracticeConfiguration.copyWith preserves unmutated values', () {
      const config = PracticeConfiguration(
        exerciseType: ExerciseType.audioToKanji,
        leniency: LeniencyPreset.strict,
        hintsEnabled: false,
        hapticsEnabled: false,
        audioSpeed: AudioSpeed.slow,
        audioAutoplay: false,
        cardLimit: 25,
      );

      final updated = config.copyWith(
        exerciseType: ExerciseType.guidedStrokeWriting,
        cardLimit: 5,
      );

      expect(updated.exerciseType, ExerciseType.guidedStrokeWriting);
      expect(updated.leniency, LeniencyPreset.strict);
      expect(updated.hintsEnabled, isFalse);
      expect(updated.hapticsEnabled, isFalse);
      expect(updated.audioSpeed, AudioSpeed.slow);
      expect(updated.audioAutoplay, isFalse);
      expect(updated.cardLimit, 5);
    });

    test('PracticeConfiguration equality and hash code', () {
      const config1 = PracticeConfiguration(cardLimit: 12);
      const config2 = PracticeConfiguration(cardLimit: 12);
      const config3 = PracticeConfiguration(cardLimit: 15);

      expect(config1, equals(config2));
      expect(config1.hashCode, equals(config2.hashCode));
      expect(config1, isNot(equals(config3)));
    });

    test('PracticeConfiguration rejects invalid cardLimit <= 0', () {
      expect(
        () => PracticeConfiguration(cardLimit: 0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => PracticeConfiguration(cardLimit: -5),
        throwsA(isA<AssertionError>()),
      );
    });

    test('PracticePreset standardPresets catalog contains 5 built-in presets', () {
      expect(PracticePreset.standardPresets.length, 5);
      final ids = PracticePreset.standardPresets.map((p) => p.id).toSet();
      expect(ids, containsAll(['standard', 'beginner', 'challenge', 'audio', 'copy']));
    });

    test('PracticePreset.getById resolves recognized presets and falls back to standard', () {
      expect(PracticePreset.getById('standard').id, 'standard');
      expect(PracticePreset.getById('beginner').id, 'beginner');
      expect(PracticePreset.getById('challenge').id, 'challenge');
      expect(PracticePreset.getById('audio').id, 'audio');
      expect(PracticePreset.getById('copy').id, 'copy');
      expect(PracticePreset.getById('non_existent').id, 'standard');
    });
  });

  group('Milestone 4: ExerciseEngine Unified Factory & Session Queue', () {
    late ContentDatabase contentDb;
    late KanjiCharacter tenKanji;

    setUp(() {
      contentDb = ContentDatabase.openFromFile(File('assets/db/kanji_content.db'));
      final loadedTen = contentDb.getKanjiByCodepoint(0x5341);
      expect(loadedTen, isNotNull);
      tenKanji = loadedTen!;
    });

    tearDown(() {
      contentDb.close();
    });

    test('createExercise dispatches standard review preset correctly', () {
      final exercise = ExerciseEngine.createExercise(
        kanji: tenKanji,
        config: PracticePreset.standard.configuration,
      );

      expect(exercise.exerciseType, ExerciseType.meaningToKanji);
      expect(exercise.skillType, SkillType.writingRecall);
      expect(exercise.prompt, isA<MeaningPrompt>());
      final method = exercise.answerMethod as HandwritingAnswerMethod;
      expect(method.leniency, LeniencyPreset.normal);
      expect(method.hintsEnabled, isTrue);
      expect(method.showFullReference, isFalse);
      expect(method.guidedMode, isFalse);
    });

    test('createExercise dispatches beginner friendly preset with guided strokes', () {
      final exercise = ExerciseEngine.createExercise(
        kanji: tenKanji,
        config: PracticePreset.beginner.configuration,
      );

      expect(exercise.exerciseType, ExerciseType.guidedStrokeWriting);
      expect(exercise.skillType, SkillType.writingRecall);
      expect(exercise.prompt, isA<MeaningPrompt>());
      final method = exercise.answerMethod as HandwritingAnswerMethod;
      expect(method.leniency, LeniencyPreset.forgiving);
      expect(method.guidedMode, isTrue);
      expect(method.showFullReference, isFalse);
    });

    test('createExercise dispatches mastery challenge preset with strict evaluation and no hints', () {
      final exercise = ExerciseEngine.createExercise(
        kanji: tenKanji,
        config: PracticePreset.challenge.configuration,
      );

      expect(exercise.exerciseType, ExerciseType.meaningToKanji);
      expect(exercise.skillType, SkillType.writingRecall);
      final method = exercise.answerMethod as HandwritingAnswerMethod;
      expect(method.leniency, LeniencyPreset.strict);
      expect(method.hintsEnabled, isFalse);
    });

    test('createExercise dispatches audio immersion preset with AudioPrompt', () {
      final exercise = ExerciseEngine.createExercise(
        kanji: tenKanji,
        config: PracticePreset.audio.configuration,
      );

      expect(exercise.exerciseType, ExerciseType.audioToKanji);
      expect(exercise.skillType, SkillType.writingRecall);
      expect(exercise.prompt, isA<AudioPrompt>());
    });

    test('createExercise dispatches motor tracing preset with showFullReference', () {
      final exercise = ExerciseEngine.createExercise(
        kanji: tenKanji,
        config: PracticePreset.copy.configuration,
      );

      expect(exercise.exerciseType, ExerciseType.referenceCopy);
      expect(exercise.skillType, SkillType.writingDiagnostic);
      final method = exercise.answerMethod as HandwritingAnswerMethod;
      expect(method.leniency, LeniencyPreset.forgiving);
      expect(method.showFullReference, isTrue);
      expect(method.guidedMode, isFalse);
    });

    test('createSessionQueue caps output by cardLimit', () {
      final characters = List.generate(20, (_) => tenKanji);
      const config = PracticeConfiguration(cardLimit: 7);

      final queue = ExerciseEngine.createSessionQueue(
        characters: characters,
        config: config,
      );

      expect(queue.length, 7);
      for (int i = 0; i < queue.length; i++) {
        expect(queue[i].id, 'session_meaningToKanji_21313_$i');
      }
    });

    test('createExercise throws UnsupportedError for unsupported recognition types', () {
      const config = PracticeConfiguration(
        exerciseType: ExerciseType.kanjiToMeaning,
      );

      expect(
        () => ExerciseEngine.createExercise(kanji: tenKanji, config: config),
        throwsUnsupportedError,
      );
    });
  });

  group('Milestone 4: UserDatabase & Riverpod Preset Persistence', () {
    late UserDatabase userDb;

    setUp(() {
      userDb = UserDatabase.openInMemory();
    });

    tearDown(() {
      userDb.close();
    });

    test('loadActivePresetId defaults to standard if unset', () {
      expect(userDb.loadActivePresetId(), 'standard');
    });

    test('saveActivePresetId persists and updates key-value row', () {
      userDb.saveActivePresetId('beginner');
      expect(userDb.loadActivePresetId(), 'beginner');

      userDb.saveActivePresetId('challenge');
      expect(userDb.loadActivePresetId(), 'challenge');
    });

    test('ActivePresetNotifier initializes from database and notifies listeners', () {
      userDb.saveActivePresetId('audio');
      final container = ProviderContainer(
        overrides: [
          userDatabaseProvider.overrideWithValue(userDb),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(activePresetProvider).id, 'audio');
      expect(container.read(activeConfigurationProvider).exerciseType, ExerciseType.audioToKanji);

      container.read(activePresetProvider.notifier).selectPreset(PracticePreset.beginner);

      expect(container.read(activePresetProvider).id, 'beginner');
      expect(container.read(activeConfigurationProvider).exerciseType, ExerciseType.guidedStrokeWriting);
      expect(userDb.loadActivePresetId(), 'beginner');
    });
  });

  group('Milestone 4: PresetSelectorWidget & HomeScreen Integration Suite', () {
    late ContentDatabase contentDb;
    late UserDatabase userDb;
    late FakeSpeechService fakeSpeechService;

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
    });

    tearDown(() {
      userDb.close();
      contentDb.close();
    });

    Widget createTestApp() {
      return ProviderScope(
        overrides: [
          contentDatabaseProvider.overrideWithValue(contentDb),
          userDatabaseProvider.overrideWithValue(userDb),
          speechServiceProvider.overrideWithValue(fakeSpeechService),
        ],
        child: const MaterialApp(
          home: HomeScreen(),
        ),
      );
    }

    testWidgets('PresetSelectorWidget renders all 5 presets with active selection', (tester) async {
      await tester.pumpWidget(createTestApp());
      await tester.pumpAndSettle();

      // Verify that all 5 chips exist
      expect(find.byKey(const Key('preset_chip_standard')), findsOneWidget);
      expect(find.byKey(const Key('preset_chip_beginner')), findsOneWidget);
      expect(find.byKey(const Key('preset_chip_challenge')), findsOneWidget);
      expect(find.byKey(const Key('preset_chip_audio')), findsOneWidget);
      expect(find.byKey(const Key('preset_chip_copy')), findsOneWidget);

      // Verify default active preset is Standard Review
      expect(find.text('Standard Review'), findsOneWidget);
      expect(
        find.textContaining('Balanced spaced-repetition daily writing practice.'),
        findsOneWidget,
      );
      expect(find.textContaining('Start Standard Review'), findsOneWidget);

      // Tap on Beginner Friendly chip
      await tester.ensureVisible(find.byKey(const Key('preset_chip_beginner')));
      await tester.tap(find.byKey(const Key('preset_chip_beginner')));
      await tester.pumpAndSettle();

      // Verify state updated
      expect(
        find.textContaining('Guided stroke-by-stroke assistance for new learners.'),
        findsOneWidget,
      );
      expect(find.textContaining('Start Beginner Friendly'), findsOneWidget);

      // Verify persistence in UserDatabase
      expect(userDb.loadActivePresetId(), 'beginner');

      // Tap on Audio Immersion chip
      await tester.ensureVisible(find.byKey(const Key('preset_chip_audio')));
      await tester.tap(find.byKey(const Key('preset_chip_audio')));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Oral reading prompt testing sound-to-character recall.'),
        findsOneWidget,
      );
      expect(find.textContaining('Start Audio Immersion'), findsOneWidget);
      expect(userDb.loadActivePresetId(), 'audio');
    });
  });
}
