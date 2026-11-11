import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_kanji_practice/src/content/contracts/kanji_audio_source.dart';
import 'package:offline_kanji_practice/src/content/providers/content_source_providers.dart';
import 'package:offline_kanji_practice/src/data/content_db.dart';
import 'package:offline_kanji_practice/src/data/user_db.dart';
import 'package:offline_kanji_practice/src/domain/exercises/exercise_prompt.dart';
import 'package:offline_kanji_practice/src/providers/app_providers.dart';
import 'package:offline_kanji_practice/src/services/audio_playback_service.dart';
import 'package:offline_kanji_practice/src/services/speech_service.dart';
import 'package:offline_kanji_practice/src/ui/screens/content_sources_screen.dart';
import 'package:offline_kanji_practice/src/ui/screens/home_screen.dart';
import 'package:offline_kanji_practice/src/ui/screens/settings_screen.dart';
import 'package:offline_kanji_practice/src/ui/widgets/audio_prompt_card.dart';

import 'fixtures/mock_content_http_server.dart';
import 'fixtures/test_package_builder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  group('UI Exposure & End-to-End Modular Content Sources Integration', () {
    late ContentDatabase contentDb;
    late UserDatabase userDb;
    late Directory tempAppDir;
    late FakeSpeechService fakeSpeech;
    late FakeAudioPlaybackService fakeAudioPlayer;
    late MockContentHttpServer mockHttpServer;

    setUpAll(() {
      HttpOverrides.global = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('com.tsuzuri.kanji/feedback'),
        (call) async => true,
      );
    });

    setUp(() async {
      tempAppDir = Directory.systemTemp.createTempSync('tsuzuri_ui_sources_test_');
      contentDb = ContentDatabase.openFromFile(File('assets/db/kanji_content.db'));
      userDb = await UserDatabase.openFromDirectory(tempAppDir);
      fakeSpeech = FakeSpeechService(japaneseAvailable: true);
      fakeAudioPlayer = FakeAudioPlaybackService(shouldSucceed: true);
      mockHttpServer = MockContentHttpServer();
      await mockHttpServer.start();
    });

    tearDown(() async {
      await mockHttpServer.stop();
      userDb.close();
      contentDb.close();
      try {
        if (await tempAppDir.exists()) {
          await tempAppDir.delete(recursive: true);
        }
      } catch (_) {}
    });

    Widget createApp({Widget? home}) {
      return ProviderScope(
        overrides: [
          contentDatabaseProvider.overrideWithValue(contentDb),
          userDatabaseProvider.overrideWithValue(userDb),
          appDocumentsDirectoryProvider.overrideWithValue(tempAppDir),
          speechServiceProvider.overrideWithValue(fakeSpeech),
          audioPlaybackServiceProvider.overrideWithValue(fakeAudioPlayer),
        ],
        child: MaterialApp(
          home: home ?? const HomeScreen(),
        ),
      );
    }

    Future<void> pumpUntilAsyncDone(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      for (var i = 0; i < 200; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump(const Duration(milliseconds: 20));
        if (find.byType(CircularProgressIndicator).evaluate().isEmpty && i >= 2) {
          break;
        }
      }
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pumpAndSettle();
    }

    testWidgets('SettingsScreen opens ContentSourcesScreen with Bundled Defaults anchored', (tester) async {
      await tester.pumpWidget(createApp(home: const SettingsScreen()));
      await tester.pumpAndSettle();

      final sourcesTile = find.byKey(const Key('settings_content_sources_tile'));
      expect(sourcesTile, findsOneWidget);
      expect(find.textContaining('Using bundled defaults'), findsOneWidget);

      await tester.tap(sourcesTile);
      await tester.pumpAndSettle();

      expect(find.byType(ContentSourcesScreen), findsOneWidget);
      expect(find.byKey(const Key('bundled_defaults_card')), findsOneWidget);
      expect(find.byKey(const Key('import_offline_package_btn')), findsOneWidget);
      expect(find.byKey(const Key('connect_online_source_btn')), findsOneWidget);
    });

    testWidgets('Connecting remote HTTP source via UI updates HomeScreen Kanji Deck and toggles/deletes cleanly', (tester) async {
      const customCodepoint = 0x9B1D; // 鬝 (verified outside bundled Joyo DB)
      final zipBytes = ZipEncoder().encode(
        TestPackageBuilder.buildValidPackageArchive(
          id: 'dragon_pack',
          name: 'Dragon Expansion Pack',
          version: '1.1.0',
          includeMetadata: true,
          includeStrokes: true,
          includeAudio: true,
          sampleCodepoint: customCodepoint,
          sampleLiteral: '鬝',
          meanings: const ['dragon_custom'],
          onyomi: const ['リュウ'],
          kunyomi: const ['たつ'],
        ),
      )!;

      mockHttpServer.serveManifest('/dragon/manifest.json', {
        'id': 'dragon_pack',
        'name': 'Dragon Expansion Pack',
        'version': '1.1.0',
        'capabilities': ['metadata', 'strokes', 'audio'],
        'metadataPath': 'metadata.json',
        'strokesPath': 'strokes.json',
        'audioPath': 'audio',
        'archiveUrl': '/dragon/dragon.zip',
      });
      mockHttpServer.serveBytes('/dragon/dragon.zip', zipBytes);

      await tester.pumpWidget(createApp(home: const HomeScreen()));
      await tester.pumpAndSettle();

      // Open ContentSourcesScreen from HomeScreen Sources shortcut
      final sourcesBtn = find.byKey(const Key('home_manage_sources_btn'));
      await tester.ensureVisible(sourcesBtn);
      await tester.tap(sourcesBtn);
      await tester.pumpAndSettle();

      expect(find.byType(ContentSourcesScreen), findsOneWidget);

      // Connect Online Source via dialog
      await tester.tap(find.byKey(const Key('connect_online_source_btn')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('online_url_textfield')),
        '${mockHttpServer.baseUrl}/dragon/manifest.json',
      );
      await tester.tap(find.byKey(const Key('connect_url_submit_btn')));
      await pumpUntilAsyncDone(tester);

      // Verify custom pack appears with version and capability chips
      expect(find.byKey(const Key('source_card_dragon_pack')), findsOneWidget);
      expect(find.textContaining('Dragon Expansion Pack (v1.1.0)'), findsOneWidget);

      // Navigate back to HomeScreen and verify custom Kanji '鬝' appears in the deck
      await tester.pageBack();
      await pumpUntilAsyncDone(tester);

      expect(find.text('Sources (1)'), findsOneWidget);
      final homeVerticalScroll = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.text('鬝'),
        250,
        scrollable: homeVerticalScroll,
        maxScrolls: 200,
      );
      expect(find.text('鬝'), findsOneWidget);
      expect(find.text('dragon_custom'), findsOneWidget);

      // Return to ContentSourcesScreen to disable and remove the source
      await tester.scrollUntilVisible(
        sourcesBtn,
        -250,
        scrollable: homeVerticalScroll,
        maxScrolls: 200,
      );
      await tester.tap(sourcesBtn);
      await tester.pumpAndSettle();

      // Disable toggle
      await tester.tap(find.byKey(const Key('source_toggle_dragon_pack')));
      await pumpUntilAsyncDone(tester);
      expect(userDb.getInstalledSource('dragon_pack')?.enabled, isFalse);

      // Delete source with FSRS-preservation confirmation dialog
      await tester.tap(find.byKey(const Key('source_delete_dragon_pack')));
      await tester.pumpAndSettle();
      expect(find.textContaining('FSRS spaced-repetition progress'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await pumpUntilAsyncDone(tester);

      expect(find.byKey(const Key('source_card_dragon_pack')), findsNothing);
      expect(userDb.getInstalledSources(), isEmpty);
    });

    testWidgets('Failed remote fetch displays diagnostic Package Rejected dialog without crashing', (tester) async {
      await tester.pumpWidget(createApp(home: const ContentSourcesScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('connect_online_source_btn')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('online_url_textfield')),
        '${mockHttpServer.baseUrl}/nonexistent/manifest.json',
      );
      await tester.tap(find.byKey(const Key('connect_url_submit_btn')));
      await pumpUntilAsyncDone(tester);

      expect(find.textContaining('Package Rejected (networkError)'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
      expect(userDb.getInstalledSources(), isEmpty);
    });

    testWidgets('AudioPromptCard plays custom localFile audio, suppresses TTS warning, and falls back to TTS on error', (tester) async {
      final promptWithCustomAudio = AudioPrompt(
        codepoint: 0x5341,
        literal: '十',
        spokenText: 'ジュウ',
        hiddenMeanings: const ['ten'],
        strokeCount: 2,
        audioPronunciation: const AudioPronunciation(
          type: AudioPayloadType.localFile,
          uriOrText: '/tmp/custom_juu.mp3',
          mimeType: 'audio/mpeg',
          reading: 'ジュウ',
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            userDatabaseProvider.overrideWithValue(userDb),
            speechServiceProvider.overrideWithValue(fakeSpeech),
            audioPlaybackServiceProvider.overrideWithValue(fakeAudioPlayer),
            japaneseVoiceAvailableProvider.overrideWith((ref) async => false),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: AudioPromptCard(
                prompt: promptWithCustomAudio,
                exerciseId: 'custom_audio_test_1',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Custom audio played cleanly via audio playback service, NOT TTS; warning suppressed
      expect(fakeAudioPlayer.playCount, equals(1));
      expect(fakeAudioPlayer.lastPlayedAudio!.uriOrText, equals('/tmp/custom_juu.mp3'));
      expect(fakeSpeech.speakCount, equals(0));
      expect(find.text('Custom Offline Audio Pack'), findsOneWidget);
      expect(find.textContaining('Japanese TTS voice not found'), findsNothing);

      // Simulate media playback failure -> falls back seamlessly to TTS
      fakeAudioPlayer.shouldSucceed = false;
      await tester.tap(find.widgetWithText(FilledButton, 'Play Audio'));
      await tester.pumpAndSettle();

      expect(fakeSpeech.speakCount, equals(1));
      expect(fakeSpeech.lastSpokenText, equals('ジュウ'));
    });
  });
}
