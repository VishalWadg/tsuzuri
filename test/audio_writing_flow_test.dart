import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_kanji_practice/src/data/content_db.dart';
import 'package:offline_kanji_practice/src/data/models.dart';
import 'package:offline_kanji_practice/src/data/user_db.dart';
import 'package:offline_kanji_practice/src/domain/exercises/exercise_definition.dart';
import 'package:offline_kanji_practice/src/matching/point2d.dart';
import 'package:offline_kanji_practice/src/providers/app_providers.dart';
import 'package:offline_kanji_practice/src/services/exercise_engine.dart';
import 'package:offline_kanji_practice/src/services/speech_service.dart';
import 'package:offline_kanji_practice/src/ui/canvas/kanji_canvas.dart';
import 'package:offline_kanji_practice/src/ui/screens/practice_screen.dart';
import 'package:offline_kanji_practice/src/ui/widgets/audio_prompt_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Milestone 2: Audio → Write Kanji Integration Suite', () {
    late ContentDatabase contentDb;
    late UserDatabase userDb;
    late FakeSpeechService fakeSpeech;
    late KanjiCharacter tenKanji;
    late KanjiCharacter oneKanji;

    setUpAll(() {
      // Mock native haptic feedback channel to avoid MissingPluginException in headless tests
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('com.tsuzuri.kanji/feedback'),
        (call) async => true,
      );
    });

    setUp(() {
      userDb = UserDatabase.openInMemory();
      contentDb = ContentDatabase.openFromFile(File('assets/db/kanji_content.db'));
      fakeSpeech = FakeSpeechService(japaneseAvailable: true);

      final loadedTen = contentDb.getKanjiByCodepoint(0x5341); // 十 (ten)
      expect(loadedTen, isNotNull);
      tenKanji = loadedTen!;

      final loadedOne = contentDb.getKanjiByCodepoint(0x4E00); // 一 (one)
      expect(loadedOne, isNotNull);
      oneKanji = loadedOne!;
    });

    tearDown(() {
      userDb.close();
      contentDb.close();
    });

    Widget createTestWidget({required List<ExerciseDefinition> exercises}) {
      return ProviderScope(
        overrides: [
          contentDatabaseProvider.overrideWithValue(contentDb),
          userDatabaseProvider.overrideWithValue(userDb),
          speechServiceProvider.overrideWithValue(fakeSpeech),
          japaneseVoiceAvailableProvider.overrideWith((ref) async => true),
        ],
        child: MaterialApp(
          home: PracticeScreen(exercises: exercises),
        ),
      );
    }

    void setMobileViewport(WidgetTester tester) {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    Future<void> simulateStroke(
      WidgetTester tester,
      Finder canvasFinder,
      List<Point2D> kanjiPoints,
    ) async {
      final listenerFinder = find.descendant(
        of: find.descendant(of: canvasFinder, matching: find.byType(AspectRatio)),
        matching: find.byType(Listener),
      );
      expect(listenerFinder, findsOneWidget);

      final canvasBox = tester.renderObject<RenderBox>(listenerFinder);
      final canvasTopLeft = canvasBox.localToGlobal(Offset.zero);
      final canvasSize = canvasBox.size;

      final screenPoints = kanjiPoints.map((p) {
        return canvasTopLeft +
            Offset(
              p.x * (canvasSize.width / 109.0),
              p.y * (canvasSize.height / 109.0),
            );
      }).toList();

      final gesture = await tester.startGesture(screenPoints.first);
      for (var i = 1; i < screenPoints.length; i++) {
        await gesture.moveTo(screenPoints[i]);
      }
      await gesture.up();
      await tester.pumpAndSettle();
    }

    testWidgets('1. Audio → Write Kanji renders audio prompt, autoplays, and handles canvas interaction', (tester) async {
      setMobileViewport(tester);

      final audioExercise = ExerciseEngine.createAudioWritingExercise(
        kanji: tenKanji,
      );

      await tester.pumpWidget(createTestWidget(exercises: [audioExercise]));
      await tester.pumpAndSettle();

      // Audio prompt card exists
      expect(find.byType(AudioPromptCard), findsOneWidget);
      expect(find.text('Listen & Write Kanji'), findsOneWidget);
      expect(find.text('2 strokes'), findsOneWidget);

      // Autoplay fired once
      expect(fakeSpeech.speakCount, equals(1));
      expect(fakeSpeech.lastSpokenText, equals(tenKanji.onyomi.first));

      // Replay button works
      await tester.tap(find.widgetWithText(FilledButton, 'Play Audio'));
      await tester.pumpAndSettle();
      expect(fakeSpeech.speakCount, equals(2));

      // Canvas exists
      expect(find.byType(KanjiWritingCanvas), findsOneWidget);

      // Draw stroke 1 of 十 (horizontal stroke)
      await simulateStroke(
        tester,
        find.byType(KanjiWritingCanvas),
        tenKanji.strokes[0].sampledPoints,
      );

      // Draw stroke 2 of 十 (vertical stroke)
      await simulateStroke(
        tester,
        find.byType(KanjiWritingCanvas),
        tenKanji.strokes[1].sampledPoints,
      );

      // Character completed
      expect(find.textContaining('Completed「十」— FSRS Grade: Easy'), findsOneWidget);
      expect(find.text('Finish Session'), findsOneWidget);

      // FSRS card recorded in User DB under 'writing'
      final card = userDb.getCard(0x5341, mode: 'writing');
      expect(card, isNotNull);
      expect(card!.reps, equals(1));
      expect(card.state, equals(2)); // Promoted to Review state
    });

    testWidgets('2. Mixed practice session transitions from Meaning prompt to Audio prompt', (tester) async {
      setMobileViewport(tester);

      final meaningEx = ExerciseEngine.createMeaningWritingExercise(kanji: oneKanji);
      final audioEx = ExerciseEngine.createAudioWritingExercise(kanji: tenKanji);

      await tester.pumpWidget(createTestWidget(exercises: [meaningEx, audioEx]));
      await tester.pumpAndSettle();

      // First question is Meaning prompt
      expect(find.text('Writing Practice (1 / 2)'), findsOneWidget);
      expect(find.textContaining('one'), findsOneWidget);
      expect(find.byType(AudioPromptCard), findsNothing);

      // Draw stroke for 一
      await simulateStroke(
        tester,
        find.byType(KanjiWritingCanvas),
        oneKanji.strokes[0].sampledPoints,
      );

      // Advance to next exercise
      expect(find.text('Next Kanji'), findsOneWidget);
      await tester.tap(find.text('Next Kanji'));
      await tester.pumpAndSettle();

      // Second question is Audio prompt
      expect(find.text('Writing Practice (2 / 2)'), findsOneWidget);
      expect(find.byType(AudioPromptCard), findsOneWidget);
      expect(find.text('Listen & Write Kanji'), findsOneWidget);
      expect(fakeSpeech.speakCount, equals(1));
      expect(fakeSpeech.lastSpokenText, equals(tenKanji.onyomi.first));
    });
  });
}
