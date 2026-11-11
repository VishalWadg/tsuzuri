import 'dart:io';
import 'package:audioplayers/audioplayers.dart' as ap;
import '../content/contracts/kanji_audio_source.dart';

/// Contract for playing custom recorded/remote Japanese audio assets cleanly,
/// returning `true` if media playback started or `false` if TTS fallback is needed.
abstract interface class IAudioPlaybackService {
  Future<bool> playPronunciation(
    AudioPronunciation audio, {
    double playbackRate = 1.0,
  });

  Future<void> stop();

  void dispose();
}

/// Production audio file/URL player wrapping `package:audioplayers`.
/// Lazily constructs [ap.AudioPlayer] so tests that never play media avoid platform channels.
class AudioplayersPlaybackService implements IAudioPlaybackService {
  ap.AudioPlayer? _player;

  ap.AudioPlayer _ensurePlayer() => _player ??= ap.AudioPlayer();

  @override
  Future<bool> playPronunciation(
    AudioPronunciation audio, {
    double playbackRate = 1.0,
  }) async {
    if (audio.type == AudioPayloadType.ttsFallback || audio.uriOrText.trim().isEmpty) {
      return false;
    }

    try {
      final ap.Source source;
      switch (audio.type) {
        case AudioPayloadType.localFile:
          final file = File(audio.uriOrText);
          if (!await file.exists()) return false;
          source = ap.DeviceFileSource(audio.uriOrText, mimeType: audio.mimeType);
        case AudioPayloadType.remoteUrl:
          source = ap.UrlSource(audio.uriOrText, mimeType: audio.mimeType);
        case AudioPayloadType.asset:
          source = ap.AssetSource(audio.uriOrText, mimeType: audio.mimeType);
        case AudioPayloadType.ttsFallback:
          return false;
      }

      final player = _ensurePlayer();
      await player.stop();
      await player.setPlaybackRate(playbackRate.clamp(0.5, 2.0));
      await player.play(source);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _player?.stop();
    } catch (_) {}
  }

  @override
  void dispose() {
    try {
      _player?.dispose();
    } catch (_) {}
    _player = null;
  }
}

/// Deterministic test double tracking custom audio file/URL playback without native channels.
class FakeAudioPlaybackService implements IAudioPlaybackService {
  bool shouldSucceed;
  AudioPronunciation? lastPlayedAudio;
  double? lastPlaybackRate;
  int playCount = 0;
  int stopCount = 0;

  FakeAudioPlaybackService({this.shouldSucceed = true});

  @override
  Future<bool> playPronunciation(
    AudioPronunciation audio, {
    double playbackRate = 1.0,
  }) async {
    playCount++;
    lastPlayedAudio = audio;
    lastPlaybackRate = playbackRate;
    return shouldSucceed && audio.type != AudioPayloadType.ttsFallback;
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }

  @override
  void dispose() {}
}
