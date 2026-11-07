import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_kanji_practice/src/content/contracts/kanji_audio_source.dart';
import 'package:offline_kanji_practice/src/content/contracts/kanji_metadata_source.dart';
import 'package:offline_kanji_practice/src/content/contracts/kanji_stroke_source.dart';
import 'package:offline_kanji_practice/src/content/registry/content_repository.dart';
import 'package:offline_kanji_practice/src/content/registry/content_source_registry.dart';
import 'package:offline_kanji_practice/src/content/sources/bundled/bundled_metadata_source.dart';
import 'package:offline_kanji_practice/src/content/sources/bundled/bundled_stroke_source.dart';
import 'package:offline_kanji_practice/src/content/sources/bundled/default_tts_audio_source.dart';
import 'package:offline_kanji_practice/src/data/content_db.dart';
import 'package:offline_kanji_practice/src/matching/point2d.dart';
import 'package:offline_kanji_practice/src/matching/stroke_matcher.dart';
import 'package:offline_kanji_practice/src/services/speech_service.dart';

// ============================================================================
// Test Doubles for Adversarial Stress Testing
// ============================================================================

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

/// Highly configurable mock metadata source supporting synchronous and asynchronous
/// faults, simulated delays, and custom entries.
class AdversarialMetadataSource implements IKanjiMetadataSource {
  @override final String sourceId;
  @override final String displayName;
  @override final String version;
  @override final bool isBundledDefault;

  final Map<int, KanjiMetadataEntry> entries;
  Object? throwOnQuery;
  Duration? simulatedDelay;
  bool throwSynchronously;
  dynamic customEntriesProperty;
  bool throwOnDistractors;
  bool throwOnGetAllCodepoints;
  int queryCount = 0;

  AdversarialMetadataSource({
    required this.sourceId,
    this.displayName = 'Adversarial Metadata Source',
    this.version = '1.0.0',
    this.isBundledDefault = false,
    Map<int, KanjiMetadataEntry>? entries,
    this.throwOnQuery,
    this.simulatedDelay,
    this.throwSynchronously = false,
    this.customEntriesProperty,
    this.throwOnDistractors = false,
    this.throwOnGetAllCodepoints = false,
  }) : entries = entries != null ? Map.from(entries) : {};

  dynamic get entriesProp => customEntriesProperty ?? entries;

  @override
  Future<KanjiMetadataEntry?> getMetadata(int codepoint) async {
    queryCount++;
    if (simulatedDelay != null) {
      await Future<void>.delayed(simulatedDelay!);
    }
    if (throwOnQuery != null) {
      throw throwOnQuery!;
    }
    return entries[codepoint];
  }

  KanjiMetadataEntry? getMetadataSync(int codepoint) {
    queryCount++;
    if (throwSynchronously && throwOnQuery != null) {
      throw throwOnQuery!;
    }
    return entries[codepoint];
  }

  @override
  Future<List<int>> getAllCodepoints() async {
    if (throwOnGetAllCodepoints) {
      throw const SocketException('Network timeout while fetching codepoints');
    }
    return entries.keys.toList();
  }

  List<int> getAllCodepointsSync() {
    if (throwSynchronously && throwOnGetAllCodepoints) {
      throw StateError('Sync codepoints retrieval failed');
    }
    return entries.keys.toList();
  }

  @override
  Future<int> getCharacterCount() async => entries.length;

  @override
  Future<List<String>> generateMeaningDistractors(
    KanjiMetadataEntry target, {
    int count = 3,
  }) async {
    if (throwOnDistractors) {
      throw StateError('Distractor generation failure');
    }
    final distractors = <String>[];
    for (final e in entries.values) {
      if (e.codepoint == target.codepoint) continue;
      for (final m in e.meanings) {
        distractors.add(m);
      }
    }
    return distractors.take(count).toList();
  }

  @override
  Future<List<String>> generateReadingDistractors(
    KanjiMetadataEntry target, {
    int count = 3,
  }) async {
    if (throwOnDistractors) {
      throw StateError('Reading distractor generation failure');
    }
    final distractors = <String>[];
    for (final e in entries.values) {
      if (e.codepoint == target.codepoint) continue;
      distractors.addAll(e.onyomi);
      distractors.addAll(e.kunyomi);
    }
    return distractors.take(count).toList();
  }
}

/// Adversarial stroke source with configurable delays and faults.
class AdversarialStrokeSource implements IKanjiStrokeSource {
  @override final String sourceId;
  @override final String displayName;
  @override final String version;
  @override final bool isBundledDefault;

  final Map<int, List<ReferenceStroke>> strokesMap;
  Object? throwOnQuery;
  Duration? simulatedDelay;
  bool throwSynchronously;
  int queryCount = 0;

  AdversarialStrokeSource({
    required this.sourceId,
    this.displayName = 'Adversarial Stroke Source',
    this.version = '1.0.0',
    this.isBundledDefault = false,
    Map<int, List<ReferenceStroke>>? strokesMap,
    this.throwOnQuery,
    this.simulatedDelay,
    this.throwSynchronously = false,
  }) : strokesMap = strokesMap != null ? Map.from(strokesMap) : {};

  @override
  Future<List<ReferenceStroke>?> getStrokes(int codepoint) async {
    queryCount++;
    if (simulatedDelay != null) {
      await Future<void>.delayed(simulatedDelay!);
    }
    if (throwOnQuery != null) {
      throw throwOnQuery!;
    }
    return strokesMap[codepoint];
  }

  List<ReferenceStroke>? getStrokesSync(int codepoint) {
    queryCount++;
    if (throwSynchronously && throwOnQuery != null) {
      throw throwOnQuery!;
    }
    return strokesMap[codepoint];
  }

  @override
  Future<bool> containsStrokes(int codepoint) async {
    if (throwOnQuery != null) {
      throw throwOnQuery!;
    }
    return strokesMap.containsKey(codepoint);
  }
}

/// Adversarial audio source with configurable faults.
class AdversarialAudioSource implements IKanjiAudioSource {
  @override final String sourceId;
  @override final String displayName;
  @override final String version;
  @override final bool isBundledDefault;

  final Map<int, AudioPronunciation> audioMap;
  Object? throwOnQuery;
  Duration? simulatedDelay;
  int queryCount = 0;

  AdversarialAudioSource({
    required this.sourceId,
    this.displayName = 'Adversarial Audio Source',
    this.version = '1.0.0',
    this.isBundledDefault = false,
    Map<int, AudioPronunciation>? audioMap,
    this.throwOnQuery,
    this.simulatedDelay,
  }) : audioMap = audioMap != null ? Map.from(audioMap) : {};

  @override
  Future<AudioPronunciation?> getAudio(int codepoint, {String? reading}) async {
    queryCount++;
    if (simulatedDelay != null) {
      await Future<void>.delayed(simulatedDelay!);
    }
    if (throwOnQuery != null) {
      throw throwOnQuery!;
    }
    return audioMap[codepoint];
  }

  @override
  Future<bool> containsAudio(int codepoint, {String? reading}) async {
    if (throwOnQuery != null) {
      throw throwOnQuery!;
    }
    return audioMap.containsKey(codepoint);
  }
}

// ============================================================================
// Main Stress Test Suite
// ============================================================================

void main() {
  group('Adversarial Stress Suite M2: Registration & Unregistration Churn', () {
    late ContentDatabase bundledDb;
    late BundledMetadataSource bundledMeta;
    late BundledStrokeSource bundledStroke;
    late DefaultTtsAudioSource bundledAudio;
    late ContentSourceRegistry registry;
    late List<String> loggedErrors;

    setUp(() {
      bundledDb = ContentDatabase.openFromFile(File('assets/db/kanji_content.db'));
      bundledMeta = BundledMetadataSource(contentDb: bundledDb);
      bundledStroke = BundledStrokeSource(contentDb: bundledDb);
      bundledAudio = DefaultTtsAudioSource(speechService: FakeSpeechService());

      loggedErrors = [];
      registry = ContentSourceRegistry(
        errorLogger: (msg, {required sourceId, error, stackTrace}) {
          loggedErrors.add('$sourceId: $error');
        },
      );

      registry.registerMetadataSource(bundledMeta);
      registry.registerStrokeSource(bundledStroke);
      registry.registerAudioSource(bundledAudio);
    });

    tearDown(() {
      bundledDb.close();
    });

    test('Rapid mass registration of 150 sources preserves order and bundled anchor at tail', () {
      for (int i = 0; i < 150; i++) {
        registry.registerMetadataSource(
          AdversarialMetadataSource(sourceId: 'meta_$i'),
          priority: i,
        );
        registry.registerStrokeSource(
          AdversarialStrokeSource(sourceId: 'stroke_$i'),
          priority: i,
        );
        registry.registerAudioSource(
          AdversarialAudioSource(sourceId: 'audio_$i'),
          priority: i,
        );
      }

      expect(registry.activeMetadataSources.length, equals(151));
      expect(registry.activeStrokeSources.length, equals(151));
      expect(registry.activeAudioSources.length, equals(151));

      // Highest priority should be meta_149 at head
      expect(registry.activeMetadataSources.first.sourceId, equals('meta_149'));
      expect(registry.activeStrokeSources.first.sourceId, equals('stroke_149'));
      expect(registry.activeAudioSources.first.sourceId, equals('audio_149'));

      // Bundled sources must remain anchored at the very end
      expect(registry.activeMetadataSources.last.sourceId, equals('bundled_metadata'));
      expect(registry.activeStrokeSources.last.sourceId, equals('bundled_strokes'));
      expect(registry.activeAudioSources.last.sourceId, equals('bundled_tts_audio'));
    });

    test('Rapid interleaved registration and unregistration of 100 sources maintains registry integrity', () {
      // Register 100
      for (int i = 0; i < 100; i++) {
        registry.registerMetadataSource(
          AdversarialMetadataSource(sourceId: 'meta_churn_$i'),
          priority: i,
        );
      }
      expect(registry.activeMetadataSources.length, equals(101));

      // Interleave: unregister even, register new batch
      for (int i = 0; i < 100; i += 2) {
        registry.unregisterSource('meta_churn_$i');
      }
      expect(registry.activeMetadataSources.length, equals(51)); // 50 odd + 1 bundled

      // Register 50 new
      for (int i = 200; i < 250; i++) {
        registry.registerMetadataSource(
          AdversarialMetadataSource(sourceId: 'meta_new_$i'),
          priority: i,
        );
      }
      expect(registry.activeMetadataSources.length, equals(101));
      expect(registry.activeMetadataSources.last.isBundledDefault, isTrue);
    });

    test('Priority mutation: re-registering the same sourceId 50 times updates priority without duplicates', () {
      const targetId = 'mutating_source';
      for (int i = 0; i < 50; i++) {
        // Alternating positive and negative priorities
        final priority = (i % 2 == 0) ? i * 10 : -i * 10;
        registry.registerMetadataSource(
          AdversarialMetadataSource(sourceId: targetId),
          priority: priority,
        );

        final matches = registry.activeMetadataSources.where((s) => s.sourceId == targetId).toList();
        expect(matches.length, equals(1), reason: 'Source $targetId must never be duplicated');
      }

      // Final registration with priority 9999
      registry.registerMetadataSource(
        AdversarialMetadataSource(sourceId: targetId),
        priority: 9999,
      );
      expect(registry.activeMetadataSources.first.sourceId, equals(targetId));
    });

    test('Unregistering a non-existent sourceId is a clean no-op', () {
      final initialCount = registry.activeMetadataSources.length;
      expect(() => registry.unregisterSource('completely_unknown_id'), returnsNormally);
      expect(registry.activeMetadataSources.length, equals(initialCount));
    });

    test('clearCustomSources removes all 120 custom sources across all chains, keeping bundled defaults', () {
      for (int i = 0; i < 120; i++) {
        registry.registerMetadataSource(AdversarialMetadataSource(sourceId: 'meta_$i'), priority: i);
        registry.registerStrokeSource(AdversarialStrokeSource(sourceId: 'stroke_$i'), priority: i);
        registry.registerAudioSource(AdversarialAudioSource(sourceId: 'audio_$i'), priority: i);
      }

      expect(registry.activeMetadataSources.length, equals(121));
      expect(registry.activeStrokeSources.length, equals(121));
      expect(registry.activeAudioSources.length, equals(121));

      registry.clearCustomSources();

      expect(registry.activeMetadataSources.length, equals(1));
      expect(registry.activeStrokeSources.length, equals(1));
      expect(registry.activeAudioSources.length, equals(1));

      expect(registry.activeMetadataSources.single.sourceId, equals('bundled_metadata'));
      expect(registry.activeStrokeSources.single.sourceId, equals('bundled_strokes'));
      expect(registry.activeAudioSources.single.sourceId, equals('bundled_tts_audio'));
    });

    test('Concurrent mutation during async queryMetadata execution does not throw ConcurrentModificationError', () async {
      final slowEmptySource = AdversarialMetadataSource(
        sourceId: 'slow_empty_meta',
        simulatedDelay: const Duration(milliseconds: 30),
      );
      final fallbackCustomSource = AdversarialMetadataSource(
        sourceId: 'fallback_custom_meta',
        entries: {
          0x4E00: const KanjiMetadataEntry(
            codepoint: 0x4E00,
            literal: '一',
            strokeCount: 1,
            meanings: ['Concurrent Resilient'],
          ),
        },
      );

      registry.registerMetadataSource(slowEmptySource, priority: 30);
      registry.registerMetadataSource(fallbackCustomSource, priority: 10);

      final futureQuery = registry.queryMetadata(0x4E00);

      await Future<void>.delayed(const Duration(milliseconds: 5));
      registry.registerMetadataSource(
        AdversarialMetadataSource(sourceId: 'interleaved_meta'),
        priority: 25,
      );

      try {
        final result = await futureQuery;
        expect(result, isNotNull);
      } on ConcurrentModificationError {
        fail('ConcurrentModificationError was thrown because _metadataSources was modified during iteration in queryMetadata!');
      }
    });

    test('Concurrent mutation during async queryStrokes execution does not throw ConcurrentModificationError', () async {
      final slowEmptySource = AdversarialStrokeSource(
        sourceId: 'slow_empty_strokes',
        simulatedDelay: const Duration(milliseconds: 30),
      );
      final fallbackCustomSource = AdversarialStrokeSource(
        sourceId: 'fallback_custom_strokes',
        strokesMap: {
          0x4E00: [
            const ReferenceStroke(
              strokeOrder: 1,
              strokeType: 'horizontal',
              svgPath: 'M 10 50 L 90 50',
              arcLength: 80.0,
              sampledPoints: [Point2D(10, 50), Point2D(90, 50)],
            ),
          ],
        },
      );

      registry.registerStrokeSource(slowEmptySource, priority: 30);
      registry.registerStrokeSource(fallbackCustomSource, priority: 10);

      final futureQuery = registry.queryStrokes(0x4E00);

      await Future<void>.delayed(const Duration(milliseconds: 5));
      registry.registerStrokeSource(
        AdversarialStrokeSource(sourceId: 'interleaved_strokes'),
        priority: 25,
      );

      try {
        final result = await futureQuery;
        expect(result, isNotNull);
      } on ConcurrentModificationError {
        fail('ConcurrentModificationError was thrown because _strokeSources was modified during iteration in queryStrokes!');
      }
    });

    test('Concurrent mutation during async queryAudio execution does not throw ConcurrentModificationError', () async {
      final slowEmptySource = AdversarialAudioSource(
        sourceId: 'slow_empty_audio',
        simulatedDelay: const Duration(milliseconds: 30),
      );
      final fallbackCustomSource = AdversarialAudioSource(
        sourceId: 'fallback_custom_audio',
        audioMap: {
          0x4E00: const AudioPronunciation(
            type: AudioPayloadType.asset,
            uriOrText: 'assets/audio/ichi.mp3',
            reading: 'イチ',
          ),
        },
      );

      registry.registerAudioSource(slowEmptySource, priority: 30);
      registry.registerAudioSource(fallbackCustomSource, priority: 10);

      final futureQuery = registry.queryAudio(0x4E00);

      await Future<void>.delayed(const Duration(milliseconds: 5));
      registry.registerAudioSource(
        AdversarialAudioSource(sourceId: 'interleaved_audio'),
        priority: 25,
      );

      try {
        final result = await futureQuery;
        expect(result, isNotNull);
      } on ConcurrentModificationError {
        fail('ConcurrentModificationError was thrown because _audioSources was modified during iteration in queryAudio!');
      }
    });
  });

  group('Adversarial Stress Suite M2: Priority Collisions & Boundary Priorities', () {
    late ContentDatabase bundledDb;
    late BundledMetadataSource bundledMeta;
    late ContentSourceRegistry registry;

    setUp(() {
      bundledDb = ContentDatabase.openFromFile(File('assets/db/kanji_content.db'));
      bundledMeta = BundledMetadataSource(contentDb: bundledDb);
      registry = ContentSourceRegistry();
      registry.registerMetadataSource(bundledMeta);
    });

    tearDown(() {
      bundledDb.close();
    });

    test('Massive priority collision: 80 sources with identical priority resolve in deterministic FIFO order', () async {
      for (int i = 0; i < 80; i++) {
        registry.registerMetadataSource(
          AdversarialMetadataSource(
            sourceId: 'collision_$i',
            entries: {
              0x4E00: KanjiMetadataEntry(
                codepoint: 0x4E00,
                literal: '一',
                strokeCount: 1,
                meanings: ['Collision $i'],
                onyomi: const ['イチ'],
                kunyomi: const ['ひと'],
              ),
            },
          ),
          priority: 42, // All identical priority
        );
      }

      // Check order: collision_0 must be first, collision_79 must be 80th, bundledMeta must be 81st
      final active = registry.activeMetadataSources;
      expect(active.length, equals(81));
      expect(active[0].sourceId, equals('collision_0'));
      expect(active[79].sourceId, equals('collision_79'));
      expect(active[80].sourceId, equals('bundled_metadata'));

      // Querying should resolve to collision_0 because it was registered first
      final meta = await registry.queryMetadata(0x4E00);
      expect(meta?.meanings.first, equals('Collision 0'));
    });

    test('Extreme priority values: 64-bit int max, 64-bit int min, 32-bit max, 32-bit min, 0', () {
      const intMax64 = 9223372036854775807;
      const intMin64 = -9223372036854775808;
      const intMax32 = 2147483647;
      const intMin32 = -2147483648;

      registry.registerMetadataSource(AdversarialMetadataSource(sourceId: 'zero'), priority: 0);
      registry.registerMetadataSource(AdversarialMetadataSource(sourceId: 'min32'), priority: intMin32);
      registry.registerMetadataSource(AdversarialMetadataSource(sourceId: 'max32'), priority: intMax32);
      registry.registerMetadataSource(AdversarialMetadataSource(sourceId: 'min64'), priority: intMin64);
      registry.registerMetadataSource(AdversarialMetadataSource(sourceId: 'max64'), priority: intMax64);

      final order = registry.activeMetadataSources.map((s) => s.sourceId).toList();
      expect(order, equals([
        'max64',
        'max32',
        'zero',
        'min32',
        'min64',
        'bundled_metadata', // Bundled default must STILL be anchored at the very end!
      ]));
    });

    test('Negative priority custom source is still placed BEFORE bundled default', () {
      registry.registerMetadataSource(
        AdversarialMetadataSource(
          sourceId: 'negative_prio',
          entries: {
            0x4E00: const KanjiMetadataEntry(
              codepoint: 0x4E00,
              literal: '一',
              strokeCount: 1,
              meanings: ['Negative Prio Meaning'],
              onyomi: ['イチ'],
              kunyomi: ['ひと'],
            ),
          },
        ),
        priority: -999999,
      );

      final active = registry.activeMetadataSources;
      expect(active.first.sourceId, equals('negative_prio'));
      expect(active.last.sourceId, equals('bundled_metadata'));
    });

    test('Attempt to overwrite bundled source with custom source throws ArgumentError', () {
      expect(
        () => registry.registerMetadataSource(
          AdversarialMetadataSource(
            sourceId: 'bundled_metadata', // Spoofing bundled source ID
            isBundledDefault: false,
          ),
          priority: 100,
        ),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('Cannot overwrite permanent bundled default source'),
        )),
      );

      // Verify original bundled source remains untouched
      expect(registry.activeMetadataSources.single.isBundledDefault, isTrue);
      expect(registry.activeMetadataSources.single, same(bundledMeta));
    });
  });

  group('Adversarial Stress Suite M2: Malicious & Crashing Sources', () {
    late ContentDatabase bundledDb;
    late BundledMetadataSource bundledMeta;
    late BundledStrokeSource bundledStroke;
    late DefaultTtsAudioSource bundledAudio;
    late ContentSourceRegistry registry;
    late ContentRepository repository;
    late List<String> loggedErrors;

    setUp(() {
      bundledDb = ContentDatabase.openFromFile(File('assets/db/kanji_content.db'));
      bundledMeta = BundledMetadataSource(contentDb: bundledDb);
      bundledStroke = BundledStrokeSource(contentDb: bundledDb);
      bundledAudio = DefaultTtsAudioSource(speechService: FakeSpeechService());

      loggedErrors = [];
      registry = ContentSourceRegistry(
        errorLogger: (msg, {required sourceId, error, stackTrace}) {
          loggedErrors.add('$sourceId: $error');
        },
      );

      registry.registerMetadataSource(bundledMeta);
      registry.registerStrokeSource(bundledStroke);
      registry.registerAudioSource(bundledAudio);

      repository = ContentRepository(registry: registry);
    });

    tearDown(() {
      bundledDb.close();
    });

    test('Synchronous StateError thrown by custom metadata source falls back cleanly to bundled default', () async {
      registry.registerMetadataSource(
        AdversarialMetadataSource(
          sourceId: 'sync_crasher',
          throwOnQuery: StateError('Explosive synchronous state failure'),
        ),
        priority: 100,
      );

      // Should not throw, should log the exception, and should return bundled 0x4E00 ('一')
      final kanji = await repository.getKanjiByCodepoint(0x4E00);
      expect(kanji, isNotNull);
      expect(kanji!.literal, equals('一'));
      expect(kanji.meanings, contains('one'));
      expect(loggedErrors.any((e) => e.contains('sync_crasher') && e.contains('Explosive synchronous state failure')), isTrue);
    });

    test('Asynchronous SocketException thrown after delay falls back cleanly to bundled default', () async {
      registry.registerMetadataSource(
        AdversarialMetadataSource(
          sourceId: 'async_socket_crasher',
          simulatedDelay: const Duration(milliseconds: 10),
          throwOnQuery: const SocketException('Simulated remote connection reset'),
        ),
        priority: 100,
      );

      final kanji = await repository.getKanjiByCodepoint(0x4E00);
      expect(kanji, isNotNull);
      expect(kanji!.literal, equals('一'));
      expect(loggedErrors.any((e) => e.contains('async_socket_crasher') && e.contains('Simulated remote connection reset')), isTrue);
    });

    test('Various Dart Errors (RangeError, TypeError, UnimplementedError) are safely contained', () async {
      final errors = <Object>[
        RangeError.value(-1, 'index', 'Index out of bounds'),
        TypeError(),
        UnimplementedError('Feature not ready'),
        const FormatException('Corrupted UTF-8 payload'),
      ];

      for (int i = 0; i < errors.length; i++) {
        final sourceId = 'error_source_$i';
        registry.registerMetadataSource(
          AdversarialMetadataSource(
            sourceId: sourceId,
            throwOnQuery: errors[i],
          ),
          priority: 50 + i,
        );
      }

      final kanji = await repository.getKanjiByCodepoint(0x4E00);
      expect(kanji, isNotNull);
      expect(kanji!.literal, equals('一'));
      expect(loggedErrors.length, equals(errors.length));
    });

    test('Crashing stroke source falls back to bundled strokes without error', () async {
      registry.registerStrokeSource(
        AdversarialStrokeSource(
          sourceId: 'crashing_strokes',
          throwOnQuery: StateError('Vector decompression bombed'),
        ),
        priority: 100,
      );

      // queryStrokes should catch error, log, and return bundled strokes for 0x4E00
      final strokes = await registry.queryStrokes(0x4E00);
      expect(strokes, isNotNull);
      expect(strokes!.length, equals(1)); // '一' has 1 stroke
      expect(loggedErrors.any((e) => e.contains('crashing_strokes')), isTrue);

      // getKanjiByCodepoint should assemble KanjiCharacter with bundled strokes
      final kanji = await repository.getKanjiByCodepoint(0x4E00);
      expect(kanji, isNotNull);
      expect(kanji!.strokes.length, equals(1));
    });

    test('Crashing audio source falls back to TTS audio pronunciation without error', () async {
      registry.registerAudioSource(
        AdversarialAudioSource(
          sourceId: 'crashing_audio',
          throwOnQuery: const SocketException('Audio server 503'),
        ),
        priority: 100,
      );

      final audio = await repository.resolveAudio(0x4E00, reading: 'イチ');
      expect(audio, isNotNull);
      expect(audio.type, equals(AudioPayloadType.ttsFallback));
      expect(audio.reading, equals('イチ'));
      expect(loggedErrors.any((e) => e.contains('crashing_audio')), isTrue);
    });

    test('Crashing distractor generators fall back to subsequent or bundled sources', () async {
      registry.registerMetadataSource(
        AdversarialMetadataSource(
          sourceId: 'distractor_crasher',
          throwOnDistractors: true,
        ),
        priority: 100,
      );

      final target = const KanjiMetadataEntry(
        codepoint: 0x4E00,
        literal: '一',
        strokeCount: 1,
        meanings: ['one'],
        onyomi: ['イチ'],
        kunyomi: ['ひと'],
      );

      final meaningDistractors = await repository.generateMeaningDistractors(target, count: 3);
      expect(meaningDistractors.length, equals(3));
      expect(meaningDistractors, isNot(contains('one')));

      final readingDistractors = await repository.generateReadingDistractors(target, count: 3);
      expect(readingDistractors.length, equals(3));
      expect(readingDistractors, isNot(contains('イチ')));
      expect(readingDistractors, isNot(contains('ひと')));
    });

    test('Crashing getAllCodepoints in custom source does not break getAllKanjiOrdered', () async {
      registry.registerMetadataSource(
        AdversarialMetadataSource(
          sourceId: 'all_codepoints_crasher',
          throwOnGetAllCodepoints: true,
        ),
        priority: 100,
      );

      final ordered = await repository.getAllKanjiOrdered();
      // Should successfully return all bundled kanji
      expect(ordered.length, greaterThan(100));
      expect(ordered.any((k) => k.codepoint == 0x4E00), isTrue);
    });

    test('Source returning stroke with empty points list is safely handled', () async {
      registry.registerStrokeSource(
        AdversarialStrokeSource(
          sourceId: 'empty_stroke_source',
          strokesMap: {
            0x4E00: [], // Empty strokes list
          },
        ),
        priority: 100,
      );

      // Registry skips empty strokes list and falls back to bundled strokes
      final strokes = await registry.queryStrokes(0x4E00);
      expect(strokes, isNotNull);
      expect(strokes!.isNotEmpty, isTrue);
      expect(strokes.length, equals(1));
    });
  });

  group('Adversarial Stress Suite M2: Bundled Default Immutability & Protection', () {
    late ContentDatabase bundledDb;
    late BundledMetadataSource bundledMeta;
    late BundledStrokeSource bundledStroke;
    late DefaultTtsAudioSource bundledAudio;
    late ContentSourceRegistry registry;

    setUp(() {
      bundledDb = ContentDatabase.openFromFile(File('assets/db/kanji_content.db'));
      bundledMeta = BundledMetadataSource(contentDb: bundledDb);
      bundledStroke = BundledStrokeSource(contentDb: bundledDb);
      bundledAudio = DefaultTtsAudioSource(speechService: FakeSpeechService());

      registry = ContentSourceRegistry();
      registry.registerMetadataSource(bundledMeta);
      registry.registerStrokeSource(bundledStroke);
      registry.registerAudioSource(bundledAudio);
    });

    tearDown(() {
      bundledDb.close();
    });

    test('Unregistering bundled metadata source throws UnsupportedError and leaves chain intact', () {
      expect(
        () => registry.unregisterSource('bundled_metadata'),
        throwsUnsupportedError,
      );
      expect(registry.activeMetadataSources.length, equals(1));
      expect(registry.activeMetadataSources.single.sourceId, equals('bundled_metadata'));
    });

    test('Unregistering bundled stroke source throws UnsupportedError and leaves chain intact', () {
      expect(
        () => registry.unregisterSource('bundled_strokes'),
        throwsUnsupportedError,
      );
      expect(registry.activeStrokeSources.length, equals(1));
      expect(registry.activeStrokeSources.single.sourceId, equals('bundled_strokes'));
    });

    test('Unregistering bundled audio source throws UnsupportedError and leaves chain intact', () {
      expect(
        () => registry.unregisterSource('bundled_tts_audio'),
        throwsUnsupportedError,
      );
      expect(registry.activeAudioSources.length, equals(1));
      expect(registry.activeAudioSources.single.sourceId, equals('bundled_tts_audio'));
    });

    test('Repeated malicious attempts to unregister bundled defaults leave registry 100% operational', () async {
      for (int i = 0; i < 20; i++) {
        expect(() => registry.unregisterSource('bundled_metadata'), throwsUnsupportedError);
        expect(() => registry.unregisterSource('bundled_strokes'), throwsUnsupportedError);
        expect(() => registry.unregisterSource('bundled_tts_audio'), throwsUnsupportedError);
      }

      final meta = await registry.queryMetadata(0x4E00);
      expect(meta, isNotNull);
      expect(meta!.literal, equals('一'));

      final strokes = await registry.queryStrokes(0x4E00);
      expect(strokes, isNotNull);

      final audio = await registry.queryAudio(0x4E00, reading: 'イチ');
      expect(audio, isNotNull);
    });
  });

  group('Adversarial Stress Suite M2: ContentRepository Facade & Synchronous Edge Cases', () {
    late ContentDatabase bundledDb;
    late BundledMetadataSource bundledMeta;
    late BundledStrokeSource bundledStroke;
    late DefaultTtsAudioSource bundledAudio;
    late ContentSourceRegistry registry;
    late ContentRepository repository;

    setUp(() {
      bundledDb = ContentDatabase.openFromFile(File('assets/db/kanji_content.db'));
      bundledMeta = BundledMetadataSource(contentDb: bundledDb);
      bundledStroke = BundledStrokeSource(contentDb: bundledDb);
      bundledAudio = DefaultTtsAudioSource(speechService: FakeSpeechService());

      registry = ContentSourceRegistry();
      registry.registerMetadataSource(bundledMeta);
      registry.registerStrokeSource(bundledStroke);
      registry.registerAudioSource(bundledAudio);

      repository = ContentRepository(registry: registry);
    });

    tearDown(() {
      bundledDb.close();
    });

    test('getKanjiByCodepointSync handles custom sources throwing in getMetadataSync', () {
      registry.registerMetadataSource(
        AdversarialMetadataSource(
          sourceId: 'sync_thrower',
          throwSynchronously: true,
          throwOnQuery: StateError('Synchronous failure during queue building'),
        ),
        priority: 100,
      );

      // getKanjiByCodepointSync should not throw and should fall back to bundled content
      final kanji = repository.getKanjiByCodepointSync(0x4E00);
      expect(kanji, isNotNull);
      expect(kanji!.literal, equals('一'));
    });

    test('getKanjiByCodepointSync handles custom source with malformed entries property (not a Map)', () {
      registry.registerMetadataSource(
        AdversarialMetadataSource(
          sourceId: 'bad_entries_source',
          customEntriesProperty: 12345, // int instead of Map
        ),
        priority: 100,
      );

      final kanji = repository.getKanjiByCodepointSync(0x4E00);
      expect(kanji, isNotNull);
      expect(kanji!.literal, equals('一'));
    });

    test('getOrderedCodepointsSync handles custom source throwing in getAllCodepointsSync', () {
      registry.registerMetadataSource(
        AdversarialMetadataSource(
          sourceId: 'sync_codepoints_thrower',
          throwSynchronously: true,
          throwOnGetAllCodepoints: true,
        ),
        priority: 100,
      );

      final codepoints = repository.getOrderedCodepointsSync();
      expect(codepoints.length, greaterThan(100));
      expect(codepoints.contains(0x4E00), isTrue);
    });

    test('Cache clearing allows newly registered higher priority custom source to supersede cached character', () async {
      // First query: populates cache from bundled source
      final first = await repository.getKanjiByCodepoint(0x4E00);
      expect(first!.meanings.first, equals('one'));

      // Register new custom source overriding 0x4E00 with higher priority
      registry.registerMetadataSource(
        AdversarialMetadataSource(
          sourceId: 'high_priority_custom',
          entries: {
            0x4E00: const KanjiMetadataEntry(
              codepoint: 0x4E00,
              literal: '一',
              strokeCount: 1,
              meanings: ['Custom Single'],
              onyomi: ['イチ'],
              kunyomi: ['ひと'],
            ),
          },
        ),
        priority: 999,
      );

      // Cache still has old entry until cleared
      final stale = await repository.getKanjiByCodepoint(0x4E00);
      expect(stale!.meanings.first, equals('one'));

      // Clear cache
      repository.clearCache();

      // Now new source takes effect
      final fresh = await repository.getKanjiByCodepoint(0x4E00);
      expect(fresh!.meanings.first, equals('Custom Single'));
    });

    test('Distractor sanitization rejects whitespace, duplicates, and case-insensitive target matches', () async {
      registry.registerMetadataSource(
        AdversarialMetadataSource(
          sourceId: 'dirty_distractors',
          entries: {
            0x4E01: const KanjiMetadataEntry(
              codepoint: 0x4E01,
              literal: '丁',
              strokeCount: 2,
              meanings: [
                'one', // Exact duplicate of target meaning
                'ONE', // Case variation of target meaning
                '  one  ', // Whitespace padded variation
                '  ', // Whitespace only
                'ward', // Valid distractor
                'ward', // Duplicate of valid distractor
                'district', // Valid distractor
              ],
              onyomi: ['イチ', '  イチ  ', 'チョウ'],
              kunyomi: ['ひと', 'チョウ'],
            ),
          },
        ),
        priority: 50,
      );

      final target = const KanjiMetadataEntry(
        codepoint: 0x4E00,
        literal: '一',
        strokeCount: 1,
        meanings: ['one'],
        onyomi: ['イチ'],
        kunyomi: ['ひと'],
      );

      final meaningDistractors = await repository.generateMeaningDistractors(target, count: 3);
      expect(meaningDistractors, isNot(contains('one')));
      expect(meaningDistractors, isNot(contains('ONE')));
      expect(meaningDistractors, isNot(contains('  one  ')));
      expect(meaningDistractors, isNot(contains('  ')));
      expect(meaningDistractors.toSet().length, equals(meaningDistractors.length), reason: 'Must not contain duplicates');

      final readingDistractors = await repository.generateReadingDistractors(target, count: 3);
      expect(readingDistractors, isNot(contains('イチ')));
      expect(readingDistractors, isNot(contains('ひと')));
      expect(readingDistractors.toSet().length, equals(readingDistractors.length), reason: 'Must not contain duplicates');
    });

    test('Boundary codepoints (<= 0, > 0x10FFFF) yield null or safe TTS fallback without exception', () async {
      const invalidCodepoints = [-1, 0, 0x110000, 2147483647];

      for (final cp in invalidCodepoints) {
        expect(await repository.getKanjiByCodepoint(cp), isNull);
        expect(repository.getKanjiByCodepointSync(cp), isNull);
        expect(await registry.queryStrokes(cp), isNull);
        expect(await registry.containsStrokes(cp), isFalse);

        final audio = await repository.resolveAudio(cp, reading: 'テスト');
        expect(audio.type, equals(AudioPayloadType.ttsFallback));
        expect(audio.reading, equals('テスト'));
      }
    });
  });
}
