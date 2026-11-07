/// Classification of the audio pronunciation delivery payload.
enum AudioPayloadType {
  /// File stored on the local filesystem (e.g. extracted package file).
  localFile,

  /// Bundled Flutter asset (e.g. 'assets/audio/4e00.mp3').
  asset,

  /// Remote HTTP / HTTPS URL stream or endpoint.
  remoteUrl,

  /// System on-device Text-To-Speech synthesis using [uriOrText] as spoken Japanese text.
  ttsFallback,
}

/// Immutable delivery model for audio pronunciation of a Kanji character or reading.
class AudioPronunciation {
  /// Delivery method of the audio payload.
  final AudioPayloadType type;

  /// Target URI (path, asset key, remote URL) or the spoken text string for TTS.
  final String uriOrText;

  /// Optional MIME type (e.g. 'audio/mpeg', 'audio/ogg', 'audio/wav').
  final String? mimeType;

  /// The pronunciation / reading associated with this audio (e.g. 'いち', 'イチ').
  final String reading;

  const AudioPronunciation({
    required this.type,
    required this.uriOrText,
    this.mimeType,
    required this.reading,
  });

  AudioPronunciation copyWith({
    AudioPayloadType? type,
    String? uriOrText,
    String? mimeType,
    String? reading,
  }) {
    return AudioPronunciation(
      type: type ?? this.type,
      uriOrText: uriOrText ?? this.uriOrText,
      mimeType: mimeType ?? this.mimeType,
      reading: reading ?? this.reading,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioPronunciation &&
          runtimeType == other.runtimeType &&
          type == other.type &&
          uriOrText == other.uriOrText &&
          mimeType == other.mimeType &&
          reading == other.reading;

  @override
  int get hashCode => Object.hash(type, uriOrText, mimeType, reading);

  @override
  String toString() =>
      'AudioPronunciation(type: $type, uriOrText: "$uriOrText", reading: "$reading", mimeType: $mimeType)';
}

/// Abstract provider interface for Kanji audio pronunciation sources.
abstract interface class IKanjiAudioSource {
  /// Unique machine-readable identifier for this audio source (e.g. 'bundled_tts_audio').
  String get sourceId;

  /// Human-readable display name (e.g. 'Default TTS Speech').
  String get displayName;

  /// Semantic version string (e.g. '1.0.0').
  String get version;

  /// Whether this source represents the zero-configuration bundled default.
  bool get isBundledDefault;

  /// Returns audio pronunciation for [codepoint] (and optional specific [reading]), or null if unavailable.
  Future<AudioPronunciation?> getAudio(int codepoint, {String? reading});

  /// Fast check for whether this source contains audio for [codepoint] (and optional [reading]).
  Future<bool> containsAudio(int codepoint, {String? reading});
}
