import 'package:offline_kanji_practice/src/content/contracts/kanji_audio_source.dart';
import 'package:offline_kanji_practice/src/content/contracts/kanji_metadata_source.dart';
import 'package:offline_kanji_practice/src/content/contracts/kanji_stroke_source.dart';
import 'package:offline_kanji_practice/src/matching/stroke_matcher.dart';
import 'package:offline_kanji_practice/src/services/speech_service.dart';

/// Test double implementing [ISpeechService] for hermetic audio testing.
class FakeSpeechService implements ISpeechService {
  final bool japaneseAvailable;
  String? lastSpokenText;
  int speakCount = 0;

  FakeSpeechService({this.japaneseAvailable = true});

  @override
  Future<bool> isJapaneseVoiceAvailable() async => japaneseAvailable;

  @override
  Future<void> speakJapanese(String text, {double rate = 1.0}) async {
    lastSpokenText = text;
    speakCount++;
  }

  @override
  Future<void> stop() async {}
}

/// In-memory implementation of [IKanjiMetadataSource] for deterministic testing.
class MockCustomMetadataSource implements IKanjiMetadataSource {
  @override
  final String sourceId;
  @override
  final String displayName;
  @override
  final String version;
  @override
  final bool isBundledDefault;

  final Map<int, KanjiMetadataEntry> entries;
  bool shouldThrowOnGet;
  bool shouldThrowOnAll;
  bool shouldThrowOnDistractors;
  Object throwError;
  int queryCount = 0;

  MockCustomMetadataSource({
    this.sourceId = 'mock_custom_meta',
    this.displayName = 'Mock Custom Metadata',
    this.version = '1.0.0',
    this.isBundledDefault = false,
    Map<int, KanjiMetadataEntry>? entries,
    this.shouldThrowOnGet = false,
    this.shouldThrowOnAll = false,
    this.shouldThrowOnDistractors = false,
    this.throwError = const FormatException('Simulated metadata fault'),
  }) : entries = entries != null ? Map.from(entries) : {};

  @override
  Future<KanjiMetadataEntry?> getMetadata(int codepoint) async {
    queryCount++;
    if (shouldThrowOnGet) throw throwError;
    return entries[codepoint];
  }

  KanjiMetadataEntry? getMetadataSync(int codepoint) {
    queryCount++;
    if (shouldThrowOnGet) throw throwError;
    return entries[codepoint];
  }

  @override
  Future<List<int>> getAllCodepoints() async {
    if (shouldThrowOnAll) throw throwError;
    return entries.keys.toList();
  }

  List<int> getAllCodepointsSync() {
    if (shouldThrowOnAll) throw throwError;
    return entries.keys.toList();
  }

  @override
  Future<int> getCharacterCount() async {
    if (shouldThrowOnAll) throw throwError;
    return entries.length;
  }

  @override
  Future<List<String>> generateMeaningDistractors(
    KanjiMetadataEntry target, {
    int count = 3,
  }) async {
    if (shouldThrowOnDistractors) throw throwError;
    if (count <= 0) return const [];
    final distractors = <String>[];
    for (final entry in entries.values) {
      if (entry.codepoint == target.codepoint) continue;
      for (final m in entry.meanings) {
        if (!target.meanings.contains(m) && !distractors.contains(m)) {
          distractors.add(m);
        }
      }
      if (distractors.length >= count) break;
    }
    return distractors.take(count).toList();
  }

  @override
  Future<List<String>> generateReadingDistractors(
    KanjiMetadataEntry target, {
    int count = 3,
  }) async {
    if (shouldThrowOnDistractors) throw throwError;
    if (count <= 0) return const [];
    final targetReadings = {...target.onyomi, ...target.kunyomi};
    final distractors = <String>[];
    for (final entry in entries.values) {
      if (entry.codepoint == target.codepoint) continue;
      for (final r in [...entry.onyomi, ...entry.kunyomi]) {
        if (!targetReadings.contains(r) && !distractors.contains(r)) {
          distractors.add(r);
        }
      }
      if (distractors.length >= count) break;
    }
    return distractors.take(count).toList();
  }
}

/// In-memory implementation of [IKanjiStrokeSource] for deterministic testing.
class MockCustomStrokeSource implements IKanjiStrokeSource {
  @override
  final String sourceId;
  @override
  final String displayName;
  @override
  final String version;
  @override
  final bool isBundledDefault;

  final Map<int, List<ReferenceStroke>> strokeMap;
  bool shouldThrow;
  Object throwError;
  int queryCount = 0;

  MockCustomStrokeSource({
    this.sourceId = 'mock_custom_strokes',
    this.displayName = 'Mock Custom Strokes',
    this.version = '1.0.0',
    this.isBundledDefault = false,
    Map<int, List<ReferenceStroke>>? strokeMap,
    this.shouldThrow = false,
    this.throwError = const FormatException('Simulated stroke query failure'),
  }) : strokeMap = strokeMap != null ? Map.from(strokeMap) : {};

  @override
  Future<List<ReferenceStroke>?> getStrokes(int codepoint) async {
    queryCount++;
    if (shouldThrow) throw throwError;
    return strokeMap[codepoint];
  }

  List<ReferenceStroke>? getStrokesSync(int codepoint) {
    queryCount++;
    if (shouldThrow) throw throwError;
    return strokeMap[codepoint];
  }

  @override
  Future<bool> containsStrokes(int codepoint) async {
    if (shouldThrow) throw throwError;
    final s = strokeMap[codepoint];
    return s != null && s.isNotEmpty;
  }
}

/// In-memory implementation of [IKanjiAudioSource] for deterministic testing.
class MockCustomAudioSource implements IKanjiAudioSource {
  @override
  final String sourceId;
  @override
  final String displayName;
  @override
  final String version;
  @override
  final bool isBundledDefault;

  final Map<int, Map<String, AudioPronunciation>> audioMap;
  bool shouldThrow;
  Object throwError;
  int queryCount = 0;

  MockCustomAudioSource({
    this.sourceId = 'mock_custom_audio',
    this.displayName = 'Mock Custom Audio',
    this.version = '1.0.0',
    this.isBundledDefault = false,
    Map<int, Map<String, AudioPronunciation>>? audioMap,
    this.shouldThrow = false,
    this.throwError = const FormatException('Simulated audio query failure'),
  }) : audioMap = audioMap != null ? Map.from(audioMap) : {};

  @override
  Future<AudioPronunciation?> getAudio(int codepoint, {String? reading}) async {
    queryCount++;
    if (shouldThrow) throw throwError;
    final forCp = audioMap[codepoint];
    if (forCp == null) return null;
    if (reading != null && reading.isNotEmpty) {
      return forCp[reading] ?? forCp[''];
    }
    return forCp.values.firstOrNull;
  }

  @override
  Future<bool> containsAudio(int codepoint, {String? reading}) async {
    if (shouldThrow) throw throwError;
    final forCp = audioMap[codepoint];
    if (forCp == null) return false;
    if (reading != null && reading.isNotEmpty) {
      return forCp.containsKey(reading) || forCp.containsKey('');
    }
    return forCp.isNotEmpty;
  }
}
