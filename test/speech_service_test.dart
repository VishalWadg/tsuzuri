import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_kanji_practice/src/data/models.dart';
import 'package:offline_kanji_practice/src/data/user_db.dart';
import 'package:offline_kanji_practice/src/providers/app_providers.dart';
import 'package:offline_kanji_practice/src/services/speech_service.dart';

void main() {
  group('Milestone 2: SpeechService & ISpeechService Abstraction', () {
    test('FakeSpeechService tracks invocations, text, and speech rate', () async {
      final fake = FakeSpeechService(japaneseAvailable: true);

      expect(await fake.isJapaneseVoiceAvailable(), isTrue);

      await fake.speakJapanese('十', rate: 0.45);
      expect(fake.speakCount, equals(1));
      expect(fake.lastSpokenText, equals('十'));
      expect(fake.lastSpeechRate, equals(0.45));

      await fake.stop();
      expect(fake.stopCount, equals(1));

      fake.reset();
      expect(fake.speakCount, equals(0));
      expect(fake.stopCount, equals(0));
      expect(fake.lastSpokenText, isNull);
    });

    test('FakeSpeechService reflects unavailable voice', () async {
      final fake = FakeSpeechService(japaneseAvailable: false);
      expect(await fake.isJapaneseVoiceAvailable(), isFalse);
    });

    test('speechServiceProvider can be overridden in ProviderContainer', () async {
      final fake = FakeSpeechService();
      final container = ProviderContainer(
        overrides: [
          speechServiceProvider.overrideWithValue(fake),
        ],
      );

      final service = container.read(speechServiceProvider);
      expect(service, isA<FakeSpeechService>());

      await service.speakJapanese('一', rate: 0.5);
      expect(fake.speakCount, equals(1));
      expect(fake.lastSpokenText, equals('一'));

      container.dispose();
    });
  });

  group('Milestone 2: Audio Settings & Riverpod State', () {
    test('AudioSpeed enum defines correct labels and playback rates', () {
      expect(AudioSpeed.normal.rate, equals(0.5));
      expect(AudioSpeed.slow.rate, equals(0.32));
      expect(AudioSpeed.normal.label, equals('Normal'));
      expect(AudioSpeed.slow.label, equals('Slow'));
    });

    test('AppSettings has expected audio defaults', () {
      const settings = AppSettings();
      expect(settings.audioSpeed, equals(AudioSpeed.normal));
      expect(settings.audioAutoplay, isTrue);
    });

    test('UserDatabase persists and restores audioSpeed and audioAutoplay', () {
      final db = UserDatabase.openInMemory();
      try {
        final initialSettings = db.loadSettings();
        expect(initialSettings.audioSpeed, equals(AudioSpeed.normal));
        expect(initialSettings.audioAutoplay, isTrue);

        final updatedSettings = initialSettings.copyWith(
          audioSpeed: AudioSpeed.slow,
          audioAutoplay: false,
        );
        db.saveSettings(updatedSettings);

        final reloaded = db.loadSettings();
        expect(reloaded.audioSpeed, equals(AudioSpeed.slow));
        expect(reloaded.audioAutoplay, isFalse);
      } finally {
        db.close();
      }
    });

    test('japaneseVoiceAvailableProvider reacts to speechServiceProvider state', () async {
      final fake = FakeSpeechService(japaneseAvailable: true);
      final container = ProviderContainer(
        overrides: [
          speechServiceProvider.overrideWithValue(fake),
        ],
      );

      final isAvailable = await container.read(japaneseVoiceAvailableProvider.future);
      expect(isAvailable, isTrue);

      container.dispose();
    });
  });
}
