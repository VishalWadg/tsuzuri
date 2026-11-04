import 'package:flutter_tts/flutter_tts.dart';

/// Abstract contract for local text-to-speech audio synthesis.
abstract interface class ISpeechService {
  /// Checks whether an on-device Japanese voice (`ja-JP`) is available.
  Future<bool> isJapaneseVoiceAvailable();

  /// Speaks the provided Japanese [text] at the specified speech [rate].
  ///
  /// Normal rate is approximately 0.5 for learners; slower speeds use lower rates.
  Future<void> speakJapanese(String text, {double rate = 0.5});

  /// Immediately stops any ongoing speech output.
  Future<void> stop();
}

/// Production implementation of [ISpeechService] wrapping [FlutterTts].
class SpeechService implements ISpeechService {
  final FlutterTts _tts;
  bool? _isJapaneseAvailable;

  SpeechService({FlutterTts? tts}) : _tts = tts ?? FlutterTts();

  @override
  Future<bool> isJapaneseVoiceAvailable() async {
    if (_isJapaneseAvailable != null) {
      return _isJapaneseAvailable!;
    }
    try {
      final dynamic result = await _tts.isLanguageAvailable('ja-JP');
      _isJapaneseAvailable = (result == true || result == 1 || result == 'true');
    } catch (_) {
      _isJapaneseAvailable = false;
    }
    return _isJapaneseAvailable!;
  }

  @override
  Future<void> speakJapanese(String text, {double rate = 0.5}) async {
    if (text.trim().isEmpty) return;
    try {
      await _tts.setLanguage('ja-JP');
      await _tts.setSpeechRate(rate.clamp(0.1, 1.0));
      await _tts.speak(text);
    } catch (_) {
      // Gracefully catch platform-level audio synthesis errors
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }
}

/// Deterministic, zero-dependency fake for unit and widget tests.
class FakeSpeechService implements ISpeechService {
  bool japaneseAvailable;
  String? lastSpokenText;
  double? lastSpeechRate;
  int speakCount = 0;
  int stopCount = 0;

  FakeSpeechService({this.japaneseAvailable = true});

  @override
  Future<bool> isJapaneseVoiceAvailable() async => japaneseAvailable;

  @override
  Future<void> speakJapanese(String text, {double rate = 0.5}) async {
    speakCount++;
    lastSpokenText = text;
    lastSpeechRate = rate;
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }

  void reset() {
    lastSpokenText = null;
    lastSpeechRate = null;
    speakCount = 0;
    stopCount = 0;
  }
}
