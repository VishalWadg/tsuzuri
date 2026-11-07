import '../../../data/content_db.dart';
import '../../../services/speech_service.dart';
import '../../contracts/kanji_audio_source.dart';

/// Zero-configuration bundled audio adapter providing on-device Japanese TTS fallback.
class DefaultTtsAudioSource implements IKanjiAudioSource {
  static const String defaultSourceId = 'bundled_tts_audio';
  static const String defaultDisplayName = 'Default TTS Speech';

  final ISpeechService _speechService;
  final ContentDatabase? _contentDb;
  final String _sourceId;
  final String _displayName;

  DefaultTtsAudioSource({
    required ISpeechService speechService,
    ContentDatabase? contentDb,
    String sourceId = defaultSourceId,
    String displayName = defaultDisplayName,
  })  : _speechService = speechService,
        _contentDb = contentDb,
        _sourceId = sourceId,
        _displayName = displayName;

  ISpeechService get speechService => _speechService;
  ContentDatabase? get contentDb => _contentDb;

  @override
  String get sourceId => _sourceId;

  @override
  String get displayName => _displayName;

  @override
  String get version => '1.0.0';

  @override
  bool get isBundledDefault => true;

  @override
  Future<AudioPronunciation?> getAudio(int codepoint, {String? reading}) async {
    String textToSpeak = (reading ?? '').trim();

    if (textToSpeak.isEmpty) {
      if (_contentDb != null) {
        if (codepoint <= 0) return null;
        final kanji = _contentDb.getKanjiByCodepoint(codepoint);
        if (kanji == null) return null;
        textToSpeak = kanji.onyomi.isNotEmpty
            ? kanji.onyomi.first
            : (kanji.kunyomi.isNotEmpty ? kanji.kunyomi.first : kanji.literal);
      } else {
        if (codepoint > 0 && codepoint <= 0x10FFFF) {
          textToSpeak = String.fromCharCode(codepoint);
        } else {
          return null;
        }
      }
    }

    if (textToSpeak.isEmpty) return null;

    return AudioPronunciation(
      type: AudioPayloadType.ttsFallback,
      uriOrText: textToSpeak,
      reading: textToSpeak,
    );
  }

  @override
  Future<bool> containsAudio(int codepoint, {String? reading}) async {
    final voiceAvailable = await _speechService.isJapaneseVoiceAvailable();
    if (!voiceAvailable) return false;

    if (reading != null && reading.trim().isNotEmpty) {
      return true;
    }

    if (_contentDb != null) {
      if (codepoint <= 0) return false;
      return _contentDb.getKanjiByCodepoint(codepoint) != null;
    }

    return codepoint > 0 && codepoint <= 0x10FFFF;
  }
}
