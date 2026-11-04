import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_kanji_practice/src/data/models.dart';
import 'package:offline_kanji_practice/src/data/user_db.dart';
import 'package:offline_kanji_practice/src/domain/exercises/exercise_prompt.dart';
import 'package:offline_kanji_practice/src/providers/app_providers.dart';
import 'package:offline_kanji_practice/src/services/speech_service.dart';
import 'package:offline_kanji_practice/src/ui/widgets/audio_prompt_card.dart';

void main() {
  group('Milestone 2: AudioPromptCard Widget & Autoplay Guard', () {
    late FakeSpeechService fakeSpeech;
    late UserDatabase userDb;

    final testPrompt = AudioPrompt(
      codepoint: 0x5341, // 十
      literal: '十',
      spokenText: 'JUU',
      hiddenMeanings: const ['ten', 'tenth'],
      strokeCount: 2,
    );

    setUp(() {
      fakeSpeech = FakeSpeechService(japaneseAvailable: true);
      userDb = UserDatabase.openInMemory();
    });

    tearDown(() {
      userDb.close();
    });

    Widget createTestWidget({
      required AudioPrompt prompt,
      required String exerciseId,
      bool overrideVoiceAvailable = true,
    }) {
      fakeSpeech.japaneseAvailable = overrideVoiceAvailable;

      return ProviderScope(
        overrides: [
          userDatabaseProvider.overrideWithValue(userDb),
          speechServiceProvider.overrideWithValue(fakeSpeech),
          japaneseVoiceAvailableProvider.overrideWith(
            (ref) async => overrideVoiceAvailable,
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: AudioPromptCard(
              prompt: prompt,
              exerciseId: exerciseId,
            ),
          ),
        ),
      );
    }

    testWidgets('Autoplays on first presentation and ignores subsequent rebuilds', (tester) async {
      await tester.pumpWidget(
        createTestWidget(prompt: testPrompt, exerciseId: 'audio_ex_1'),
      );
      await tester.pumpAndSettle();

      // Autoplay triggered exactly once
      expect(fakeSpeech.speakCount, equals(1));
      expect(fakeSpeech.lastSpokenText, equals('JUU'));

      // Rebuilding the widget must NOT re-trigger autoplay
      await tester.pumpWidget(
        createTestWidget(prompt: testPrompt, exerciseId: 'audio_ex_1'),
      );
      await tester.pumpAndSettle();

      expect(fakeSpeech.speakCount, equals(1), reason: 'Rebuild must not trigger duplicate audio');
    });

    testWidgets('Replay button triggers speech repeatedly without limit', (tester) async {
      await tester.pumpWidget(
        createTestWidget(prompt: testPrompt, exerciseId: 'audio_ex_replay'),
      );
      await tester.pumpAndSettle();

      final playButton = find.widgetWithText(FilledButton, 'Play Audio');
      expect(playButton, findsOneWidget);

      final initialCount = fakeSpeech.speakCount; // 1 from autoplay

      // Tap replay 3 times
      await tester.tap(playButton);
      await tester.pumpAndSettle();
      await tester.tap(playButton);
      await tester.pumpAndSettle();
      await tester.tap(playButton);
      await tester.pumpAndSettle();

      expect(fakeSpeech.speakCount, equals(initialCount + 3));
    });

    testWidgets('Speed toggle button cycles between Normal and Slow rate', (tester) async {
      await tester.pumpWidget(
        createTestWidget(prompt: testPrompt, exerciseId: 'audio_ex_speed'),
      );
      await tester.pumpAndSettle();

      expect(find.widgetWithText(OutlinedButton, 'Normal'), findsOneWidget);

      // Tap speed toggle to switch to Slow
      await tester.tap(find.widgetWithText(OutlinedButton, 'Normal'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(OutlinedButton, 'Slow'), findsOneWidget);
      expect(fakeSpeech.lastSpeechRate, equals(AudioSpeed.slow.rate));

      // Tap again to switch back to Normal
      await tester.tap(find.widgetWithText(OutlinedButton, 'Slow'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(OutlinedButton, 'Normal'), findsOneWidget);
      expect(fakeSpeech.lastSpeechRate, equals(AudioSpeed.normal.rate));
    });

    testWidgets('Toggles hidden meaning hint visibility', (tester) async {
      await tester.pumpWidget(
        createTestWidget(prompt: testPrompt, exerciseId: 'audio_ex_hint'),
      );
      await tester.pumpAndSettle();

      // Initially hidden
      expect(find.textContaining('Meaning: ten, tenth'), findsNothing);

      // Tap show hint
      await tester.tap(find.text('Show Meaning Hint'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Meaning: ten, tenth'), findsOneWidget);
      expect(find.text('Hide Meaning'), findsOneWidget);

      // Tap hide
      await tester.tap(find.text('Hide Meaning'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Meaning: ten, tenth'), findsNothing);
    });

    testWidgets('Displays warning banner when Japanese voice is unavailable', (tester) async {
      await tester.pumpWidget(
        createTestWidget(
          prompt: testPrompt,
          exerciseId: 'audio_ex_no_voice',
          overrideVoiceAvailable: false,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Japanese TTS voice not found'), findsOneWidget);
    });
  });
}
