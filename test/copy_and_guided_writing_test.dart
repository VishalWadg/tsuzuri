import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_kanji_practice/src/data/content_db.dart';
import 'package:offline_kanji_practice/src/data/models.dart';
import 'package:offline_kanji_practice/src/data/user_db.dart';
import 'package:offline_kanji_practice/src/domain/exercises/exercise_answer_method.dart';
import 'package:offline_kanji_practice/src/domain/exercises/exercise_definition.dart';
import 'package:offline_kanji_practice/src/domain/exercises/exercise_types.dart';
import 'package:offline_kanji_practice/src/matching/point2d.dart';
import 'package:offline_kanji_practice/src/providers/app_providers.dart';
import 'package:offline_kanji_practice/src/services/exercise_engine.dart';
import 'package:offline_kanji_practice/src/ui/canvas/kanji_canvas.dart';
import 'package:offline_kanji_practice/src/ui/screens/practice_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Milestone 3: Advanced Writing Variations (Copy & Guided Practice)', () {
    late ContentDatabase contentDb;
    late UserDatabase userDb;
    late KanjiCharacter tenKanji;

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
      expect(loadedTen, isNotNull);
      tenKanji = loadedTen!;
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

    test('1. ExerciseEngine builds valid Reference Copy definition with diagnostic skill', () {
      final copyEx = ExerciseEngine.createReferenceCopyExercise(kanji: tenKanji);

      expect(copyEx.exerciseType, equals(ExerciseType.referenceCopy));
      expect(copyEx.skillType, equals(SkillType.writingDiagnostic));
      expect(copyEx.answerMethod, isA<HandwritingAnswerMethod>());

      final hw = copyEx.answerMethod as HandwritingAnswerMethod;
      expect(hw.showFullReference, isTrue);
      expect(hw.guidedMode, isFalse);
    });

    test('2. ExerciseEngine builds valid Guided Writing definition with guided mode', () {
      final guidedEx = ExerciseEngine.createGuidedWritingExercise(kanji: tenKanji);

      expect(guidedEx.exerciseType, equals(ExerciseType.guidedStrokeWriting));
      expect(guidedEx.skillType, equals(SkillType.writingRecall));
      expect(guidedEx.answerMethod, isA<HandwritingAnswerMethod>());

      final hw = guidedEx.answerMethod as HandwritingAnswerMethod;
      expect(hw.showFullReference, isFalse);
      expect(hw.guidedMode, isTrue);
    });

    testWidgets('3. Reference Copy Practice completes and protects FSRS free-recall cards', (tester) async {
      setMobileViewport(tester);

      final copyEx = ExerciseEngine.createReferenceCopyExercise(kanji: tenKanji);
      await tester.pumpWidget(createTestWidget(exercises: [copyEx]));
      await tester.pumpAndSettle();

      final canvas = tester.widget<KanjiWritingCanvas>(find.byType(KanjiWritingCanvas));
      expect(canvas.showFullReference, isTrue);
      expect(canvas.guidedMode, isFalse);

      // Draw stroke 1 and 2
      await simulateStroke(tester, find.byType(KanjiWritingCanvas), tenKanji.strokes[0].sampledPoints);
      await simulateStroke(tester, find.byType(KanjiWritingCanvas), tenKanji.strokes[1].sampledPoints);

      expect(find.textContaining('Completed「十」'), findsOneWidget);

      // Verify that free-recall FSRS card interval was NOT created/advanced
      final card = userDb.getCard(0x5341);
      expect(card, isNull, reason: 'Assisted copy practice must not create or inflate a free-recall SRS card');
    });

    testWidgets('4. Guided Writing Practice completes and protects FSRS free-recall cards', (tester) async {
      setMobileViewport(tester);

      final guidedEx = ExerciseEngine.createGuidedWritingExercise(kanji: tenKanji);
      await tester.pumpWidget(createTestWidget(exercises: [guidedEx]));
      await tester.pumpAndSettle();

      final canvas = tester.widget<KanjiWritingCanvas>(find.byType(KanjiWritingCanvas));
      expect(canvas.showFullReference, isFalse);
      expect(canvas.guidedMode, isTrue);

      // Draw stroke 1 and 2
      await simulateStroke(tester, find.byType(KanjiWritingCanvas), tenKanji.strokes[0].sampledPoints);
      await simulateStroke(tester, find.byType(KanjiWritingCanvas), tenKanji.strokes[1].sampledPoints);

      expect(find.textContaining('Completed「十」'), findsOneWidget);

      // Verify that free-recall FSRS card was NOT created/advanced
      final card = userDb.getCard(0x5341);
      expect(card, isNull, reason: 'Assisted guided practice must not create or inflate a free-recall SRS card');
    });
  });
}
