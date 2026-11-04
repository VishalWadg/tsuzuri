import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_kanji_practice/src/data/content_db.dart';
import 'package:offline_kanji_practice/src/data/models.dart';
import 'package:offline_kanji_practice/src/data/user_db.dart';
import 'package:offline_kanji_practice/src/matching/point2d.dart';
import 'package:offline_kanji_practice/src/providers/app_providers.dart';
import 'package:offline_kanji_practice/src/scheduling/fsrs_scheduler.dart';
import 'package:offline_kanji_practice/src/ui/canvas/kanji_canvas.dart';
import 'package:offline_kanji_practice/src/ui/screens/practice_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Milestone 0: Meaning → Write Kanji Baseline Regression Suite', () {
    late ContentDatabase contentDb;
    late UserDatabase userDb;
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

      final loadedTen = contentDb.getKanjiByCodepoint(0x5341); // 十 (ten)
      expect(loadedTen, isNotNull, reason: 'Kanji 十 (0x5341) must exist in content database');
      tenKanji = loadedTen!;

      final loadedOne = contentDb.getKanjiByCodepoint(0x4E00); // 一 (one)
      expect(loadedOne, isNotNull, reason: 'Kanji 一 (0x4E00) must exist in content database');
      oneKanji = loadedOne!;
    });

    tearDown(() {
      userDb.close();
      contentDb.close();
    });

    Widget createTestWidget({required List<PracticeQueueItem> queue}) {
      return ProviderScope(
        overrides: [
          contentDatabaseProvider.overrideWithValue(contentDb),
          userDatabaseProvider.overrideWithValue(userDb),
        ],
        child: MaterialApp(
          home: PracticeScreen(queue: queue),
        ),
      );
    }

    void setMobileViewport(WidgetTester tester) {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    /// Simulates drawing a stroke on the interactive canvas by translating
    /// 109x109 KanjiVG coordinates into real screen pixels on the square canvas [Listener].
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

    testWidgets('1. Verifies Meaning Prompt card elements and initial canvas state', (tester) async {
      setMobileViewport(tester);
      final queueItem = PracticeQueueItem(kanji: tenKanji, existingProgress: null);
      await tester.pumpWidget(createTestWidget(queue: [queueItem]));
      await tester.pumpAndSettle();

      // Meaning prompt
      expect(find.textContaining('ten'), findsOneWidget);
      expect(find.text('Writing Practice (1 / 1)'), findsOneWidget);
      expect(find.text('2 strokes'), findsOneWidget);

      // Readings
      expect(find.textContaining('On\'yomi:'), findsOneWidget);
      expect(find.textContaining('Kun\'yomi:'), findsOneWidget);

      // Action buttons
      expect(find.text('Hint'), findsOneWidget);
      expect(find.text('Undo Stroke'), findsOneWidget);
      expect(find.text('Restart'), findsOneWidget);

      // Canvas exists
      expect(find.byType(KanjiWritingCanvas), findsOneWidget);

      // Initially, Undo Stroke is disabled (cannot undo when stroke count is 0)
      final undoButton = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Undo Stroke'),
      );
      expect(undoButton.onPressed, isNull);
    });

    testWidgets('2. Executes complete Meaning → Write Kanji drawing flow, verifies completion & FSRS persistence', (tester) async {
      setMobileViewport(tester);
      final queueItem = PracticeQueueItem(kanji: tenKanji, existingProgress: null);
      await tester.pumpWidget(createTestWidget(queue: [queueItem]));
      await tester.pumpAndSettle();

      final canvasFinder = find.byType(KanjiWritingCanvas);

      // Stroke 0: Horizontal stroke (left to right)
      await simulateStroke(tester, canvasFinder, tenKanji.strokes[0].sampledPoints);
      expect(find.text('Stroke 1 / 2'), findsOneWidget);

      // Undo button is now enabled
      final undoButton = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Undo Stroke'),
      );
      expect(undoButton.onPressed, isNotNull);

      // Stroke 1: Vertical stroke (top to bottom)
      await simulateStroke(tester, canvasFinder, tenKanji.strokes[1].sampledPoints);

      // Completion card appears
      expect(find.textContaining('Completed「十」— FSRS Grade: Easy'), findsOneWidget);
      expect(find.textContaining('Mistakes: 0 • Hints used: 0'), findsOneWidget);
      expect(find.text('Finish Session'), findsOneWidget);

      // Verify FSRS card persistence in userDb
      final card = userDb.getCard(0x5341, mode: PracticeMode.writing);
      expect(card, isNotNull, reason: 'FSRS card must be created in srs_cards table');
      expect(card!.codepoint, equals(0x5341));
      expect(card.reps, equals(1));
      expect(card.state, equals(2)); // FSRS promotes Easy initial reviews directly to Review state (2)
      expect(card.lastReview, isNotNull);

      // Verify Review Log persistence in userDb
      final cards = userDb.getAllCards(mode: PracticeMode.writing);
      expect(cards.length, equals(1));
    });

    testWidgets('3. Rejects wrong stroke order, displays feedback banner, and adapts FSRS grade', (tester) async {
      setMobileViewport(tester);
      final queueItem = PracticeQueueItem(kanji: tenKanji, existingProgress: null);
      await tester.pumpWidget(createTestWidget(queue: [queueItem]));
      await tester.pumpAndSettle();

      final canvasFinder = find.byType(KanjiWritingCanvas);

      // Attempt to draw vertical stroke (stroke 1) first before horizontal (stroke 0)
      await simulateStroke(tester, canvasFinder, tenKanji.strokes[1].sampledPoints);

      // Feedback banner displays "Wrong stroke order"
      expect(find.text('Wrong stroke order'), findsOneWidget);

      // Stroke count remains 0 (stroke was rejected)
      expect(find.text('Stroke 1 / 2'), findsNothing);

      // Now draw correctly: stroke 0 then stroke 1
      await simulateStroke(tester, canvasFinder, tenKanji.strokes[0].sampledPoints);
      expect(find.text('Stroke 1 / 2'), findsOneWidget);

      await simulateStroke(tester, canvasFinder, tenKanji.strokes[1].sampledPoints);

      // With 1 mistake made, FSRS grade should be "Good" instead of "Easy"
      expect(find.textContaining('Completed「十」— FSRS Grade: Good'), findsOneWidget);
      expect(find.textContaining('Mistakes: 1 • Hints used: 0'), findsOneWidget);

      final card = userDb.getCard(0x5341, mode: PracticeMode.writing);
      expect(card, isNotNull);
      expect(card!.reps, equals(1));
    });

    testWidgets('4. Undo and Restart buttons reset stroke progression as expected', (tester) async {
      setMobileViewport(tester);
      final queueItem = PracticeQueueItem(kanji: tenKanji, existingProgress: null);
      await tester.pumpWidget(createTestWidget(queue: [queueItem]));
      await tester.pumpAndSettle();

      final canvasFinder = find.byType(KanjiWritingCanvas);

      // Draw stroke 0
      await simulateStroke(tester, canvasFinder, tenKanji.strokes[0].sampledPoints);
      expect(find.text('Stroke 1 / 2'), findsOneWidget);

      // Tap Undo Stroke
      await tester.tap(find.widgetWithText(OutlinedButton, 'Undo Stroke'));
      await tester.pumpAndSettle();

      // Undo button is disabled again
      final undoButton = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Undo Stroke'),
      );
      expect(undoButton.onPressed, isNull);

      // Redraw stroke 0
      await simulateStroke(tester, canvasFinder, tenKanji.strokes[0].sampledPoints);
      expect(find.text('Stroke 1 / 2'), findsOneWidget);

      // Tap Restart
      await tester.tap(find.widgetWithText(OutlinedButton, 'Restart'));
      await tester.pumpAndSettle();

      // Canvas reset: stroke count back to 0
      final undoButtonAfterRestart = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Undo Stroke'),
      );
      expect(undoButtonAfterRestart.onPressed, isNull);
    });

    testWidgets('5. Advances through multi-kanji queue to Next Kanji', (tester) async {
      setMobileViewport(tester);
      final queue = [
        PracticeQueueItem(kanji: tenKanji, existingProgress: null),
        PracticeQueueItem(kanji: oneKanji, existingProgress: null),
      ];

      await tester.pumpWidget(createTestWidget(queue: queue));
      await tester.pumpAndSettle();

      final canvasFinder = find.byType(KanjiWritingCanvas);

      // Complete first kanji (十)
      expect(find.text('Writing Practice (1 / 2)'), findsOneWidget);
      await simulateStroke(tester, canvasFinder, tenKanji.strokes[0].sampledPoints);
      await simulateStroke(tester, canvasFinder, tenKanji.strokes[1].sampledPoints);

      // Button says "Next Kanji" (not Finish Session)
      expect(find.text('Next Kanji'), findsOneWidget);

      // Tap Next Kanji
      await tester.tap(find.text('Next Kanji'));
      await tester.pumpAndSettle();

      // Now on second kanji (一)
      expect(find.text('Writing Practice (2 / 2)'), findsOneWidget);
      expect(find.textContaining('one'), findsOneWidget);
      expect(find.text('1 strokes'), findsOneWidget);

      // Complete second kanji
      await simulateStroke(tester, canvasFinder, oneKanji.strokes[0].sampledPoints);
      expect(find.textContaining('Completed「一」— FSRS Grade: Easy'), findsOneWidget);
      expect(find.text('Finish Session'), findsOneWidget);

      // Both cards persisted
      expect(userDb.getCard(0x5341), isNotNull);
      expect(userDb.getCard(0x4E00), isNotNull);
    });
  });
}
