import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_kanji_practice/src/data/content_db.dart';
import 'package:offline_kanji_practice/src/data/models.dart';
import 'package:offline_kanji_practice/src/data/user_db.dart';
import 'package:offline_kanji_practice/src/domain/exercises/exercise_types.dart';
import 'package:offline_kanji_practice/src/domain/exercises/practice_configuration.dart';
import 'package:offline_kanji_practice/src/providers/app_providers.dart';
import 'package:offline_kanji_practice/src/services/exercise_engine.dart';
import 'package:offline_kanji_practice/src/services/speech_service.dart';
import 'package:offline_kanji_practice/src/ui/screens/home_screen.dart';
import 'package:offline_kanji_practice/src/ui/screens/settings_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Milestone 6: Production Verification (FR-01 to FR-18)', () {
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

    Widget createTestApp({Widget? child}) {
      return ProviderScope(
        overrides: [
          contentDatabaseProvider.overrideWithValue(contentDb),
          userDatabaseProvider.overrideWithValue(userDb),
          speechServiceProvider.overrideWithValue(fakeSpeechService),
        ],
        child: MaterialApp(
          home: child ?? const HomeScreen(),
        ),
      );
    }

    test('FR-01, FR-03, FR-04: Preset Catalog & Activity Partitioning', () {
      final writingPresets = PracticePreset.presetsForActivity(ExerciseActivity.writing);
      final recognitionPresets = PracticePreset.presetsForActivity(ExerciseActivity.recognition);

      expect(writingPresets.length, equals(5));
      expect(recognitionPresets.length, equals(3));

      expect(
        writingPresets.map((p) => p.id).toList(),
        containsAll(['standard', 'beginner', 'challenge', 'audio', 'copy']),
      );
      expect(
        recognitionPresets.map((p) => p.id).toList(),
        containsAll(['rec_meaning', 'rec_reading', 'rec_audio']),
      );
    });

    test('FR-17: Schema v3 Backup & Restore preserves all cards, logs, settings, and metrics', () {
      final now = DateTime.utc(2026, 11, 4, 15, 0);

      // 1. Insert Writing card and Recognition card
      userDb.upsertCard(
        UserCardProgress(
          codepoint: 0x5341,
          mode: 'writing',
          dueDate: now.add(const Duration(days: 3)),
          stability: 4.5,
          difficulty: 3.2,
          elapsedDays: 1,
          scheduledDays: 3,
          reps: 2,
          lapses: 0,
          state: 2,
          lastReview: now,
        ),
      );
      userDb.upsertCard(
        UserCardProgress(
          codepoint: 0x5341,
          mode: 'meaning_rec',
          dueDate: now.add(const Duration(days: 7)),
          stability: 8.0,
          difficulty: 2.1,
          elapsedDays: 3,
          scheduledDays: 7,
          reps: 4,
          lapses: 0,
          state: 2,
          lastReview: now,
        ),
      );

      // 2. Insert writing metrics
      userDb.insertWritingMetric(
        codepoint: 0x5341,
        exerciseType: 'referenceCopy',
        shapeScore: 0.98,
        orderErrors: 0,
        retries: 0,
        durationMs: 3200,
        recordedAt: now,
      );

      // 3. Save custom settings
      userDb.saveSettings(
        const AppSettings(
          audioSpeed: AudioSpeed.slow,
          audioAutoplay: false,
          dailyNewCardsLimit: 15,
        ),
      );

      // 4. Export backup JSON
      final backup = userDb.exportBackupJson();
      expect(backup, contains('"writing_metrics"'));
      expect(backup, contains('"meaning_rec"'));
      expect(backup, contains('"writing"'));

      // 5. Restore into fresh UserDatabase
      final restoredDb = UserDatabase.openInMemory();
      addTearDown(restoredDb.close);
      restoredDb.importBackupJson(backup);

      // Verify all elements restored
      final restoredWriting = restoredDb.getCard(0x5341, mode: 'writing');
      final restoredMeaning = restoredDb.getCard(0x5341, mode: 'meaning_rec');
      final restoredMetrics = restoredDb.getWritingMetrics(0x5341);
      final restoredSettings = restoredDb.loadSettings();

      expect(restoredWriting, isNotNull);
      expect(restoredWriting!.stability, closeTo(4.5, 1e-4));
      expect(restoredMeaning, isNotNull);
      expect(restoredMeaning!.stability, closeTo(8.0, 1e-4));
      expect(restoredMetrics.length, equals(1));
      expect(restoredMetrics.first['shape_score'], closeTo(0.98, 1e-4));
      expect(restoredSettings.audioSpeed, equals(AudioSpeed.slow));
      expect(restoredSettings.audioAutoplay, isFalse);
      expect(restoredSettings.dailyNewCardsLimit, equals(15));
    });

    testWidgets('FR-01: PresetSelectorWidget allows toggling between Writing and Recognition activities', (tester) async {
      await tester.pumpWidget(createTestApp());
      await tester.pumpAndSettle();

      // Initially Writing activity is active
      expect(find.byKey(const Key('preset_chip_standard')), findsOneWidget);
      expect(find.byKey(const Key('preset_chip_beginner')), findsOneWidget);
      expect(find.byKey(const Key('preset_chip_rec_meaning')), findsNothing);

      // Tap 'Recognition' activity segment
      await tester.tap(find.text('Recognition'));
      await tester.pumpAndSettle();

      // Now Recognition chips are shown
      expect(find.byKey(const Key('preset_chip_rec_meaning')), findsOneWidget);
      expect(find.byKey(const Key('preset_chip_rec_reading')), findsOneWidget);
      expect(find.byKey(const Key('preset_chip_rec_audio')), findsOneWidget);
      expect(find.byKey(const Key('preset_chip_standard')), findsNothing);

      // Start button updates to Recognition preset
      expect(find.textContaining('Start Kanji → Meaning'), findsOneWidget);

      // Tap 'Writing' activity segment
      await tester.tap(find.text('Writing'));
      await tester.pumpAndSettle();

      // Returns to writing presets
      expect(find.byKey(const Key('preset_chip_standard')), findsOneWidget);
      expect(find.textContaining('Start Standard Review'), findsOneWidget);
    });

    testWidgets('SettingsScreen allows configuring Audio speed and autoplay (FR-06)', (tester) async {
      await tester.pumpWidget(createTestApp(child: const SettingsScreen()));
      await tester.pumpAndSettle();

      // Scroll to Audio Settings
      await tester.scrollUntilVisible(find.text('Audio Autoplay'), 100);
      expect(find.text('Audio Autoplay'), findsOneWidget);

      // Tap Slow audio speed segment
      await tester.tap(find.text('Slow (0.32x)'));
      await tester.pumpAndSettle();

      // Verify persisted to database
      expect(userDb.loadSettings().audioSpeed, equals(AudioSpeed.slow));

      // Toggle Audio Autoplay off
      await tester.tap(find.text('Audio Autoplay'));
      await tester.pumpAndSettle();

      expect(userDb.loadSettings().audioAutoplay, isFalse);
    });

    test('ExerciseEngine generates full recognition session queue', () {
      final characters = contentDb.getAllKanjiOrdered().take(5).toList();
      const config = PracticeConfiguration(
        exerciseType: ExerciseType.kanjiToMeaning,
        cardLimit: 3,
      );

      final queue = ExerciseEngine.createSessionQueue(
        characters: characters,
        config: config,
        contentDb: contentDb,
      );

      expect(queue.length, equals(3));
      for (final ex in queue) {
        expect(ex.exerciseType, equals(ExerciseType.kanjiToMeaning));
        expect(ex.activity, equals(ExerciseActivity.recognition));
      }
    });
  });
}
