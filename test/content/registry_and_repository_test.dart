import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_kanji_practice/src/content/contracts/kanji_audio_source.dart';
import 'package:offline_kanji_practice/src/content/contracts/kanji_metadata_source.dart';
import 'package:offline_kanji_practice/src/content/contracts/kanji_stroke_source.dart';
import 'package:offline_kanji_practice/src/content/providers/content_source_providers.dart';
import 'package:offline_kanji_practice/src/content/registry/content_repository.dart';
import 'package:offline_kanji_practice/src/content/registry/content_source_registry.dart';
import 'package:offline_kanji_practice/src/content/sources/bundled/bundled_metadata_source.dart';
import 'package:offline_kanji_practice/src/content/sources/bundled/bundled_stroke_source.dart';
import 'package:offline_kanji_practice/src/content/sources/bundled/default_tts_audio_source.dart';
import 'package:offline_kanji_practice/src/data/content_db.dart';
import 'package:offline_kanji_practice/src/data/models.dart';
import 'package:offline_kanji_practice/src/data/user_db.dart';
import 'package:offline_kanji_practice/src/matching/point2d.dart';
import 'package:offline_kanji_practice/src/matching/stroke_matcher.dart';
import 'package:offline_kanji_practice/src/providers/app_providers.dart';
import 'package:offline_kanji_practice/src/scheduling/fsrs_scheduler.dart';
import 'package:offline_kanji_practice/src/services/speech_service.dart';

// ============================================================================
// Test Helpers & Doubles
// ============================================================================

UserCardProgress copyWithDueDate(UserCardProgress p, DateTime due) {
  return UserCardProgress(
    codepoint: p.codepoint,
    mode: p.mode,
    dueDate: due,
    stability: p.stability,
    difficulty: p.difficulty,
    elapsedDays: p.elapsedDays,
    scheduledDays: p.scheduledDays,
    reps: p.reps,
    lapses: p.lapses,
    state: p.state,
    lastReview: p.lastReview,
  );
}

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

class MockCustomMetadataSource implements IKanjiMetadataSource {
  @override final String sourceId;
  @override final String displayName;
  @override final String version;
  @override final bool isBundledDefault;

  final Map<int, KanjiMetadataEntry> entries;
  bool shouldThrow;
  Object throwError;
  int queryCount = 0;

  MockCustomMetadataSource({
    this.sourceId = 'mock_custom_meta',
    this.displayName = 'Mock Custom Metadata',
    this.version = '1.0.0',
    this.isBundledDefault = false,
    Map<int, KanjiMetadataEntry>? entries,
    this.shouldThrow = false,
    this.throwError = const FormatException('Corrupted metadata payload'),
  }) : entries = entries != null ? Map.from(entries) : {};

  @override
  Future<KanjiMetadataEntry?> getMetadata(int codepoint) async {
    queryCount++;
    if (shouldThrow) throw throwError;
    return entries[codepoint];
  }

  KanjiMetadataEntry? getMetadataSync(int codepoint) {
    queryCount++;
    if (shouldThrow) throw throwError;
    return entries[codepoint];
  }

  @override
  Future<List<int>> getAllCodepoints() async {
    if (shouldThrow) throw throwError;
    return entries.keys.toList();
  }

  List<int> getAllCodepointsSync() {
    if (shouldThrow) throw throwError;
    return entries.keys.toList();
  }

  @override
  Future<int> getCharacterCount() async => entries.length;

  @override
  Future<List<String>> generateMeaningDistractors(
    KanjiMetadataEntry target, {
    int count = 3,
  }) async {
    if (shouldThrow) throw throwError;
    final distractors = <String>[];
    for (final e in entries.values) {
      if (e.codepoint == target.codepoint) continue;
      for (final m in e.meanings) {
        if (!target.meanings.contains(m) && !distractors.contains(m)) {
          distractors.add(m);
        }
      }
    }
    return distractors.take(count).toList();
  }

  @override
  Future<List<String>> generateReadingDistractors(
    KanjiMetadataEntry target, {
    int count = 3,
  }) async {
    if (shouldThrow) throw throwError;
    final targetReadings = {...target.onyomi, ...target.kunyomi};
    final distractors = <String>[];
    for (final e in entries.values) {
      if (e.codepoint == target.codepoint) continue;
      for (final r in [...e.onyomi, ...e.kunyomi]) {
        if (!targetReadings.contains(r) && !distractors.contains(r)) {
          distractors.add(r);
        }
      }
    }
    return distractors.take(count).toList();
  }
}

class MockCustomStrokeSource implements IKanjiStrokeSource {
  @override final String sourceId;
  @override final String displayName;
  @override final String version;
  @override final bool isBundledDefault;

  final Map<int, List<ReferenceStroke>> strokesMap;
  bool shouldThrow;
  Object throwError;
  int queryCount = 0;

  MockCustomStrokeSource({
    this.sourceId = 'mock_custom_strokes',
    this.displayName = 'Mock Custom Strokes',
    this.version = '1.0.0',
    this.isBundledDefault = false,
    Map<int, List<ReferenceStroke>>? strokesMap,
    this.shouldThrow = false,
    this.throwError = const FileSystemException('Corrupted stroke vector file'),
  }) : strokesMap = strokesMap != null ? Map.from(strokesMap) : {};

  @override
  Future<List<ReferenceStroke>?> getStrokes(int codepoint) async {
    queryCount++;
    if (shouldThrow) throw throwError;
    return strokesMap[codepoint];
  }

  List<ReferenceStroke>? getStrokesSync(int codepoint) {
    queryCount++;
    if (shouldThrow) throw throwError;
    return strokesMap[codepoint];
  }

  @override
  Future<bool> containsStrokes(int codepoint) async {
    if (shouldThrow) throw throwError;
    return strokesMap.containsKey(codepoint);
  }
}

class MockCustomAudioSource implements IKanjiAudioSource {
  @override final String sourceId;
  @override final String displayName;
  @override final String version;
  @override final bool isBundledDefault;

  final Map<int, AudioPronunciation> audioMap;
  bool shouldThrow;
  Object throwError;
  int queryCount = 0;

  MockCustomAudioSource({
    this.sourceId = 'mock_custom_audio',
    this.displayName = 'Mock Custom Audio',
    this.version = '1.0.0',
    this.isBundledDefault = false,
    Map<int, AudioPronunciation>? audioMap,
    this.shouldThrow = false,
    this.throwError = const HttpException('Audio stream 404 / 500 error'),
  }) : audioMap = audioMap != null ? Map.from(audioMap) : {};

  @override
  Future<AudioPronunciation?> getAudio(int codepoint, {String? reading}) async {
    queryCount++;
    if (shouldThrow) throw throwError;
    return audioMap[codepoint];
  }

  @override
  Future<bool> containsAudio(int codepoint, {String? reading}) async {
    if (shouldThrow) throw throwError;
    return audioMap.containsKey(codepoint);
  }
}

// ============================================================================
// Main Test Suite
// ============================================================================

void main() {
  late ContentDatabase contentDb;
  late BundledMetadataSource bundledMeta;
  late BundledStrokeSource bundledStroke;
  late DefaultTtsAudioSource bundledAudio;
  late FakeSpeechService speechService;

  setUpAll(() {
    final dbFile = File('assets/db/kanji_content.db');
    expect(dbFile.existsSync(), isTrue, reason: 'Bundled kanji_content.db must exist');
    contentDb = ContentDatabase.openFromFile(dbFile);
    speechService = FakeSpeechService(japaneseAvailable: true);
    bundledMeta = BundledMetadataSource(contentDb: contentDb);
    bundledStroke = BundledStrokeSource(contentDb: contentDb);
    bundledAudio = DefaultTtsAudioSource(speechService: speechService, contentDb: contentDb);
  });

  tearDownAll(() {
    contentDb.close();
  });

  // ==========================================================================
  // Group 1: ContentSourceRegistry Priority & Invariants
  // ==========================================================================
  group('Group 1: ContentSourceRegistry Priority & Invariants', () {
    late ContentSourceRegistry registry;

    setUp(() {
      registry = ContentSourceRegistry();
    });

    test('1.1 Priority Ordering: High priority queried before low priority', () {
      final sourceLow = MockCustomMetadataSource(sourceId: 'meta_low');
      final sourceHigh = MockCustomMetadataSource(sourceId: 'meta_high');
      final sourceMid = MockCustomMetadataSource(sourceId: 'meta_mid');

      registry.registerMetadataSource(sourceLow, priority: 10);
      registry.registerMetadataSource(sourceHigh, priority: 100);
      registry.registerMetadataSource(sourceMid, priority: 50);

      final active = registry.activeMetadataSources;
      expect(active.length, equals(3));
      expect(active[0].sourceId, equals('meta_high'));
      expect(active[1].sourceId, equals('meta_mid'));
      expect(active[2].sourceId, equals('meta_low'));
    });

    test('1.2 FIFO Tie-breaking: Equal priority sources ordered by registration sequence', () {
      final source1 = MockCustomMetadataSource(sourceId: 'meta_first');
      final source2 = MockCustomMetadataSource(sourceId: 'meta_second');
      final source3 = MockCustomMetadataSource(sourceId: 'meta_third');

      registry.registerMetadataSource(source1, priority: 50);
      registry.registerMetadataSource(source2, priority: 50);
      registry.registerMetadataSource(source3, priority: 50);

      final active = registry.activeMetadataSources;
      expect(active.map((s) => s.sourceId).toList(), equals(['meta_first', 'meta_second', 'meta_third']));
    });

    test('1.3 Rule of Default Permanence: Bundled defaults permanently anchored at tail', () {
      registry.registerMetadataSource(bundledMeta, priority: 0);

      // Register custom source with negative priority
      final customNeg = MockCustomMetadataSource(sourceId: 'custom_neg');
      registry.registerMetadataSource(customNeg, priority: -100);

      final active = registry.activeMetadataSources;
      expect(active.length, equals(2));
      expect(active.first.sourceId, equals('custom_neg'));
      expect(active.last.sourceId, equals('bundled_metadata'));
    });

    test('1.4 Rule of Default Permanence: Calling unregisterSource on bundled source throws UnsupportedError', () {
      registry.registerMetadataSource(bundledMeta, priority: 0);

      expect(
        () => registry.unregisterSource('bundled_metadata'),
        throwsA(isA<UnsupportedError>()),
      );
      expect(registry.activeMetadataSources.length, equals(1));
      expect(registry.activeMetadataSources.first.sourceId, equals('bundled_metadata'));
    });

    test('1.5 Protection Against Hijacking: Registering custom source with bundled ID throws ArgumentError', () {
      registry.registerMetadataSource(bundledMeta, priority: 0);

      final hijacker = MockCustomMetadataSource(
        sourceId: 'bundled_metadata',
        isBundledDefault: false,
      );

      expect(
        () => registry.registerMetadataSource(hijacker, priority: 999),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('1.6 Clean Unregistration by sourceId: Removes source across metadata, stroke, and audio chains', () {
      const multiSourceId = 'custom_complete_pkg';
      final metaSource = MockCustomMetadataSource(sourceId: multiSourceId);
      final strokeSource = MockCustomStrokeSource(sourceId: multiSourceId);
      final audioSource = MockCustomAudioSource(sourceId: multiSourceId);

      registry.registerMetadataSource(metaSource, priority: 10);
      registry.registerStrokeSource(strokeSource, priority: 10);
      registry.registerAudioSource(audioSource, priority: 10);

      expect(registry.activeMetadataSources.length, equals(1));
      expect(registry.activeStrokeSources.length, equals(1));
      expect(registry.activeAudioSources.length, equals(1));

      registry.unregisterSource(multiSourceId);

      expect(registry.activeMetadataSources, isEmpty);
      expect(registry.activeStrokeSources, isEmpty);
      expect(registry.activeAudioSources, isEmpty);
    });

    test('1.7 clearCustomSources: Removes all custom sources while retaining bundled defaults', () {
      registry.registerMetadataSource(bundledMeta, priority: 0);
      registry.registerStrokeSource(bundledStroke, priority: 0);
      registry.registerAudioSource(bundledAudio, priority: 0);

      registry.registerMetadataSource(MockCustomMetadataSource(sourceId: 'c_meta'), priority: 10);
      registry.registerStrokeSource(MockCustomStrokeSource(sourceId: 'c_stroke'), priority: 10);
      registry.registerAudioSource(MockCustomAudioSource(sourceId: 'c_audio'), priority: 10);

      expect(registry.activeMetadataSources.length, equals(2));
      expect(registry.activeStrokeSources.length, equals(2));
      expect(registry.activeAudioSources.length, equals(2));

      registry.clearCustomSources();

      expect(registry.activeMetadataSources.length, equals(1));
      expect(registry.activeMetadataSources.first.sourceId, equals('bundled_metadata'));
      expect(registry.activeStrokeSources.length, equals(1));
      expect(registry.activeStrokeSources.first.sourceId, equals('bundled_strokes'));
      expect(registry.activeAudioSources.length, equals(1));
      expect(registry.activeAudioSources.first.sourceId, equals('bundled_tts_audio'));
    });

    test('1.8 Observer Pattern & Versioning: Listener notification, monotonic version counter, and mutation tracking', () {
      var listenerCalls = 0;
      void listener() => listenerCalls++;

      registry.addListener(listener);
      expect(registry.version, equals(0));
      expect(registry.lastMutationWasRemoval, isFalse);

      final customMeta = MockCustomMetadataSource(sourceId: 'observer_test_meta');
      registry.registerMetadataSource(customMeta, priority: 5);
      expect(listenerCalls, equals(1));
      expect(registry.version, equals(1));
      expect(registry.lastMutationWasRemoval, isFalse);

      registry.unregisterSource('observer_test_meta');
      expect(listenerCalls, equals(2));
      expect(registry.version, equals(2));
      expect(registry.lastMutationWasRemoval, isTrue);

      registry.removeListener(listener);
      registry.registerMetadataSource(customMeta, priority: 5);
      expect(listenerCalls, equals(2), reason: 'Detached listener should not be invoked');
      expect(registry.version, equals(3));

      registry.dispose();
    });
  });

  // ==========================================================================
  // Group 2: Multi-Tier & Independent Component Fallback
  // ==========================================================================
  group('Group 2: Multi-Tier & Independent Component Fallback', () {
    late ContentSourceRegistry registry;
    late ContentRepository repository;

    setUp(() {
      registry = ContentSourceRegistry();
      registry.registerMetadataSource(bundledMeta, priority: 0);
      registry.registerStrokeSource(bundledStroke, priority: 0);
      registry.registerAudioSource(bundledAudio, priority: 0);
      repository = ContentRepository(registry: registry);
    });

    test('2.1 Priority Resolution: Custom metadata overrides bundled metadata for shared codepoint', () async {
      // 0x5C71 is '山' (bundled meanings: ['mountain'])
      const customEntry = KanjiMetadataEntry(
        codepoint: 0x5C71,
        literal: '山',
        strokeCount: 3,
        meanings: ['Sacred Mountain', 'Peak of Enlightenment'],
        onyomi: ['サン'],
        kunyomi: ['やま'],
      );
      final customSource = MockCustomMetadataSource(
        sourceId: 'custom_buddhist_dict',
        entries: {0x5C71: customEntry},
      );
      registry.registerMetadataSource(customSource, priority: 100);

      final resolved = await repository.getKanjiByCodepoint(0x5C71);
      expect(resolved, isNotNull);
      expect(resolved!.meanings, equals(['Sacred Mountain', 'Peak of Enlightenment']));
      expect(resolved.strokes.length, equals(3), reason: 'Falls back to bundled strokes for 山');
    });

    test('2.2 Independent Component Fallback: Custom metadata + bundled strokes + custom audio', () async {
      const customEntry = KanjiMetadataEntry(
        codepoint: 0x5C71,
        literal: '山',
        strokeCount: 3,
        meanings: ['Mountain High'],
      );
      final customMeta = MockCustomMetadataSource(
        sourceId: 'custom_mountain_meta',
        entries: {0x5C71: customEntry},
      );
      final customAudio = MockCustomAudioSource(
        sourceId: 'custom_mountain_audio',
        audioMap: {
          0x5C71: const AudioPronunciation(
            type: AudioPayloadType.localFile,
            uriOrText: '/packages/audio/yama_native.mp3',
            reading: 'やま',
          ),
        },
      );

      registry.registerMetadataSource(customMeta, priority: 100);
      registry.registerAudioSource(customAudio, priority: 100);

      // Kanji character combines custom metadata + bundled strokes
      final kanji = await repository.getKanjiByCodepoint(0x5C71);
      expect(kanji, isNotNull);
      expect(kanji!.meanings, equals(['Mountain High']));
      expect(kanji.strokes.length, equals(3));

      // Audio resolves to custom localFile
      final audio = await repository.resolveAudio(0x5C71, reading: 'やま');
      expect(audio.type, equals(AudioPayloadType.localFile));
      expect(audio.uriOrText, equals('/packages/audio/yama_native.mp3'));
      expect(audio.reading, equals('やま'));
    });

    test('2.3 Independent Component Fallback: Bundled metadata + custom strokes + default TTS', () async {
      // 0x65E5 is '日'
      final customStrokeList = <ReferenceStroke>[
        ReferenceStroke(
          strokeOrder: 1,
          strokeType: 'h',
          svgPath: 'M 0 0 L 100 0',
          arcLength: 100.0,
          sampledPoints: List.generate(50, (i) => Point2D(i * 2.0, 0.0)),
        ),
      ];
      final customStrokes = MockCustomStrokeSource(
        sourceId: 'custom_hi_strokes',
        strokesMap: {0x65E5: customStrokeList},
      );
      registry.registerStrokeSource(customStrokes, priority: 100);

      final kanji = await repository.getKanjiByCodepoint(0x65E5);
      expect(kanji, isNotNull);
      expect(kanji!.literal, equals('日'));
      expect(kanji.strokes.length, equals(1));
      expect(kanji.strokes.first.sampledPoints.length, equals(50));

      final audio = await repository.resolveAudio(0x65E5);
      expect(audio.type, equals(AudioPayloadType.ttsFallback));
    });

    test('2.4 Missing Entry Fallback: Partial custom source falls back to bundled for missing kanji', () async {
      final customSource = MockCustomMetadataSource(
        sourceId: 'partial_meta',
        entries: {
          0x4E00: const KanjiMetadataEntry(codepoint: 0x4E00, literal: '一', strokeCount: 1, meanings: ['One']),
          0x4E8C: const KanjiMetadataEntry(codepoint: 0x4E8C, literal: '二', strokeCount: 2, meanings: ['Two']),
        },
      );
      registry.registerMetadataSource(customSource, priority: 100);

      // 0x4E09 is '三' (not in customSource, present in bundled)
      final kanji = await repository.getKanjiByCodepoint(0x4E09);
      expect(kanji, isNotNull);
      expect(kanji!.literal, equals('三'));
      expect(kanji.meanings, contains('three'));
      expect(kanji.strokes.length, equals(3));
    });

    test('2.5 Character Absent from All Sources: Returns null for kanji, returns fallback TTS for audio', () async {
      // 0x9999 is '香' in the bundled database; 0x9FFF is absent from bundled defaults
      const absentCodepoint = 0x9FFF;
      final kanji = await repository.getKanjiByCodepoint(absentCodepoint);
      expect(kanji, isNull);

      final audio = await repository.resolveAudio(absentCodepoint, reading: 'きゅう');
      expect(audio.type, equals(AudioPayloadType.ttsFallback));
      expect(audio.reading, equals('きゅう'));
    });

    test('2.6 Total Character Count & Ordered Codepoints: Merges unique codepoints without duplicates', () async {
      final bundledCount = contentDb.totalKanjiCount;

      // Add a custom source with 1 overlapping kanji (0x4E00) and 2 new kanji (0x9F00, 0x9F01)
      final customMeta = MockCustomMetadataSource(
        sourceId: 'custom_new_kanji',
        entries: {
          0x4E00: const KanjiMetadataEntry(codepoint: 0x4E00, literal: '一', strokeCount: 1, grade: 1),
          0x9F00: const KanjiMetadataEntry(codepoint: 0x9F00, literal: '鼀', strokeCount: 13, grade: 9),
          0x9F01: const KanjiMetadataEntry(codepoint: 0x9F01, literal: '鼁', strokeCount: 14, grade: 9),
        },
      );
      registry.registerMetadataSource(customMeta, priority: 100);

      final totalCount = await repository.getTotalCharacterCount();
      expect(totalCount, equals(bundledCount + 2));

      final orderedCodepoints = await repository.getOrderedCodepoints();
      expect(orderedCodepoints.length, equals(bundledCount + 2));
      expect(orderedCodepoints.toSet().length, equals(orderedCodepoints.length), reason: 'Must be unique');
      expect(orderedCodepoints, contains(0x9F00));
      expect(orderedCodepoints, contains(0x9F01));
    });

    test('2.7 Distractor Supplementation: Sparse custom source supplemented by bundled default', () async {
      // Target is 0x4E00 ('一'). Custom source provides only 1 other character.
      final target = const KanjiMetadataEntry(
        codepoint: 0x4E00,
        literal: '一',
        strokeCount: 1,
        meanings: ['one'],
      );
      final customMeta = MockCustomMetadataSource(
        sourceId: 'sparse_meta',
        entries: {
          0x4E00: target,
          0x4E8C: const KanjiMetadataEntry(codepoint: 0x4E8C, literal: '二', strokeCount: 2, meanings: ['two']),
        },
      );
      registry.registerMetadataSource(customMeta, priority: 100);

      final distractors = await repository.generateMeaningDistractors(target, count: 3);
      expect(distractors.length, equals(3));
      expect(distractors.first, equals('two'), reason: 'Custom distractor chosen first');
      expect(distractors, isNot(contains('one')), reason: 'Must exclude target meaning');
    });
  });

  // ==========================================================================
  // Group 3: Exception Containment & Resilience
  // ==========================================================================
  group('Group 3: Exception Containment & Resilience', () {
    late ContentSourceRegistry registry;
    late ContentRepository repository;
    final loggedErrors = <String>[];

    setUp(() {
      loggedErrors.clear();
      registry = ContentSourceRegistry(
        errorLogger: (message, {required sourceId, error, stackTrace}) {
          loggedErrors.add('$sourceId: $message');
        },
      );
      registry.registerMetadataSource(bundledMeta, priority: 0);
      registry.registerStrokeSource(bundledStroke, priority: 0);
      registry.registerAudioSource(bundledAudio, priority: 0);
      repository = ContentRepository(registry: registry);
    });

    test('3.1 Throwing Metadata Source: Registry catches error, logs, and falls back to bundled default', () async {
      final faultyMeta = MockCustomMetadataSource(
        sourceId: 'faulty_meta',
        shouldThrow: true,
        throwError: const FormatException('Corrupted JSON archive at byte 0x42'),
      );
      registry.registerMetadataSource(faultyMeta, priority: 100);

      final kanji = await repository.getKanjiByCodepoint(0x4E00);
      expect(kanji, isNotNull);
      expect(kanji!.literal, equals('一'));
      expect(loggedErrors.any((e) => e.contains('faulty_meta')), isTrue);
    });

    test('3.2 Throwing Stroke Source: Registry catches error, logs, and falls back to bundled strokes', () async {
      final faultyStrokes = MockCustomStrokeSource(
        sourceId: 'faulty_strokes',
        shouldThrow: true,
        throwError: const FileSystemException('Unreadable SVG stroke directory'),
      );
      registry.registerStrokeSource(faultyStrokes, priority: 100);

      final kanji = await repository.getKanjiByCodepoint(0x4E00);
      expect(kanji, isNotNull);
      expect(kanji!.strokes.length, equals(1));
      expect(loggedErrors.any((e) => e.contains('faulty_strokes')), isTrue);
    });

    test('3.3 Throwing Audio Source: Registry catches error and falls back to TTS', () async {
      final faultyAudio = MockCustomAudioSource(
        sourceId: 'faulty_audio',
        shouldThrow: true,
        throwError: const HttpException('503 Service Unavailable'),
      );
      registry.registerAudioSource(faultyAudio, priority: 100);

      final audio = await repository.resolveAudio(0x4E00);
      expect(audio.type, equals(AudioPayloadType.ttsFallback));
      expect(loggedErrors.any((e) => e.contains('faulty_audio')), isTrue);
    });

    test('3.4 Throwing Distractor Generator: Catches error and falls back to bundled distractors', () async {
      final target = const KanjiMetadataEntry(
        codepoint: 0x4E00,
        literal: '一',
        strokeCount: 1,
        meanings: ['one'],
      );
      final faultyDistractorSource = MockCustomMetadataSource(
        sourceId: 'faulty_distractor_source',
        entries: {0x4E00: target},
        shouldThrow: true,
        throwError: StateError('Distractor vocabulary pool exhausted'),
      );
      registry.registerMetadataSource(faultyDistractorSource, priority: 100);

      final distractors = await repository.generateMeaningDistractors(target, count: 3);
      expect(distractors.length, equals(3));
      expect(distractors, isNot(contains('one')));
      expect(loggedErrors.any((e) => e.contains('faulty_distractor_source')), isTrue);
    });

    test('3.5 Throwing Codepoint Enumeration: Catches error and enumerates bundled codepoints safely', () async {
      final faultyEnumSource = MockCustomMetadataSource(
        sourceId: 'faulty_enum_source',
        shouldThrow: true,
        throwError: const ProcessException('sqlite3', [], 'Database disk image malformed'),
      );
      registry.registerMetadataSource(faultyEnumSource, priority: 100);

      final list = await repository.getAllKanjiOrdered();
      expect(list.isNotEmpty, isTrue);
      expect(list.length, equals(contentDb.totalKanjiCount));
      expect(loggedErrors.any((e) => e.contains('faulty_enum_source')), isTrue);
    });
  });

  // ==========================================================================
  // Group 4: Riverpod Provider Integration & Dependency Cascade
  // ==========================================================================
  group('Group 4: Riverpod Provider Integration & Dependency Cascade', () {
    test('4.1 Default Provider Initialization: Contains 3 bundled default sources', () {
      final container = ProviderContainer(
        overrides: [
          contentDatabaseProvider.overrideWithValue(contentDb),
          speechServiceProvider.overrideWithValue(FakeSpeechService()),
        ],
      );
      addTearDown(container.dispose);

      final registry = container.read(contentSourceRegistryProvider);
      expect(registry.activeMetadataSources.length, equals(1));
      expect(registry.activeMetadataSources.first.isBundledDefault, isTrue);
      expect(registry.activeStrokeSources.length, equals(1));
      expect(registry.activeStrokeSources.first.isBundledDefault, isTrue);
      expect(registry.activeAudioSources.length, equals(1));
      expect(registry.activeAudioSources.first.isBundledDefault, isTrue);
    });

    test('4.2 Repository Facade Exposure: Resolves kanji from bundled database', () async {
      final container = ProviderContainer(
        overrides: [
          contentDatabaseProvider.overrideWithValue(contentDb),
          speechServiceProvider.overrideWithValue(FakeSpeechService()),
        ],
      );
      addTearDown(container.dispose);

      final repository = container.read(contentRepositoryProvider);
      final kanji = await repository.getKanjiByCodepoint(0x4E00);
      expect(kanji, isNotNull);
      expect(kanji!.literal, equals('一'));
    });

    test('4.3 Database Override Propagation: Overriding contentDb updates registry and repository', () async {
      final inMemoryDb = ContentDatabase.openFromFile(File('assets/db/kanji_content.db'));
      addTearDown(inMemoryDb.close);

      final container = ProviderContainer(
        overrides: [
          contentDatabaseProvider.overrideWithValue(inMemoryDb),
          speechServiceProvider.overrideWithValue(FakeSpeechService()),
        ],
      );
      addTearDown(container.dispose);

      final repo = container.read(contentRepositoryProvider);
      expect(repo.bundledContentDatabase, same(inMemoryDb));

      final kanji = await repo.getKanjiByCodepoint(0x65E5);
      expect(kanji, isNotNull);
      expect(kanji!.literal, equals('日'));
    });

    test('4.4 Daily Queue Provider Integration: dailyQueueProvider produces valid queue items', () {
      final userDb = UserDatabase.openInMemory();
      addTearDown(userDb.close);

      final container = ProviderContainer(
        overrides: [
          contentDatabaseProvider.overrideWithValue(contentDb),
          userDatabaseProvider.overrideWithValue(userDb),
          speechServiceProvider.overrideWithValue(FakeSpeechService()),
        ],
      );
      addTearDown(container.dispose);

      final queue = container.read(dailyQueueProvider);
      expect(queue.isNotEmpty, isTrue);
      expect(queue.first.kanji, isNotNull);
      expect(queue.first.isNew, isTrue);
    });

    test('4.5 Dual Queue Providers: dailyQueueAsyncProvider resolves pure async custom source and updates dailyQueueProvider', () async {
      final userDb = UserDatabase.openInMemory();
      addTearDown(userDb.close);

      final container = ProviderContainer(
        overrides: [
          contentDatabaseProvider.overrideWithValue(contentDb),
          userDatabaseProvider.overrideWithValue(userDb),
          speechServiceProvider.overrideWithValue(FakeSpeechService()),
        ],
      );
      addTearDown(container.dispose);

      final registry = container.read(contentSourceRegistryProvider);
      const pureAsyncCp = 0x9FFE;
      final pastDue = DateTime.utc(2026, 10, 1, 10, 0);
      userDb.upsertCard(UserCardProgress(
        codepoint: pureAsyncCp,
        mode: PracticeMode.writing,
        dueDate: pastDue,
        stability: 3.0,
        difficulty: 4.0,
        elapsedDays: 2,
        scheduledDays: 2,
        reps: 2,
        lapses: 0,
        state: 2,
        lastReview: pastDue,
      ));

      final pureAsyncSource = MockCustomMetadataSource(
        sourceId: 'pure_async_pkg',
        entries: {
          pureAsyncCp: const KanjiMetadataEntry(
            codepoint: pureAsyncCp,
            literal: '鿾',
            strokeCount: 16,
            meanings: ['AsyncKanji'],
            grade: 1,
          ),
        },
      );
      registry.registerMetadataSource(pureAsyncSource, priority: 100);

      // Read async queue directly
      final asyncQueue = await container.read(dailyQueueAsyncProvider.future);
      expect(asyncQueue.any((item) => item.kanji.codepoint == pureAsyncCp), isTrue);

      // Once resolved, synchronous provider also yields the item
      final syncQueue = container.read(dailyQueueProvider);
      expect(syncQueue.any((item) => item.kanji.codepoint == pureAsyncCp), isTrue);
    });

    test('4.6 ContentRepository auto-invalidation on unregister clears cached character and detaches on dispose', () {
      final reg = ContentSourceRegistry();
      reg.registerMetadataSource(bundledMeta, priority: 0);
      reg.registerStrokeSource(bundledStroke, priority: 0);

      final repo = ContentRepository(registry: reg);
      const customCp = 0x9FF9;
      reg.registerMetadataSource(
        MockCustomMetadataSource(
          sourceId: 'evict_test_pkg',
          entries: {
            customCp: const KanjiMetadataEntry(
              codepoint: customCp,
              literal: '鿹',
              strokeCount: 12,
              meanings: ['EvictTest'],
            ),
          },
        ),
        priority: 10,
      );

      final kanji = repo.getKanjiByCodepointSync(customCp);
      expect(kanji, isNotNull);
      expect(repo.cachedCharacterCount, greaterThan(0));

      // Unregister should trigger auto-invalidation
      reg.unregisterSource('evict_test_pkg');
      expect(repo.getKanjiByCodepointSync(customCp), isNull);
      expect(repo.cachedCharacterCount, equals(0));

      repo.dispose();
    });
  });

  // ==========================================================================
  // Group 5: FSRS User Progress Compatibility, Source Swap & Queue Skipping
  // ==========================================================================
  group('Group 5: FSRS User Progress Compatibility, Source Swap & Queue Skipping', () {
    late UserDatabase userDb;
    late ContentSourceRegistry registry;
    late ContentRepository repository;
    late FsrsSchedulerService scheduler;

    const customCodepoint = 0x9FFF; // Specialized kanji absent from bundled contentDb
    final customEntry = const KanjiMetadataEntry(
      codepoint: customCodepoint,
      literal: '鿿',
      strokeCount: 15,
      meanings: ['Extremely Rare Custom Kanji'],
    );

    setUp(() {
      userDb = UserDatabase.openInMemory();
      registry = ContentSourceRegistry();
      registry.registerMetadataSource(bundledMeta, priority: 0);
      registry.registerStrokeSource(bundledStroke, priority: 0);
      registry.registerAudioSource(bundledAudio, priority: 0);
      repository = ContentRepository(registry: registry);
      scheduler = FsrsSchedulerService();
    });

    tearDown(() {
      userDb.close();
    });

    test('5.1 Progress Persistence: Card and review log saved for custom codepoint', () {
      final progress = scheduler.recordPracticeCompletion(
        userDb: userDb,
        codepoint: customCodepoint,
        mistakes: 0,
        hintsUsed: 0,
        now: DateTime.utc(2026, 11, 1, 12, 0),
      );

      expect(progress.codepoint, equals(customCodepoint));
      expect(progress.reps, equals(1));
      expect(progress.stability, greaterThan(0.0));

      final cardInDb = userDb.getCard(customCodepoint);
      expect(cardInDb, isNotNull);
      expect(cardInDb!.codepoint, equals(customCodepoint));
      expect(cardInDb.reps, equals(1));

      final backupJson = userDb.exportBackupJson();
      final decoded = jsonDecode(backupJson) as Map<String, dynamic>;
      final logs = (decoded['review_logs'] as List<dynamic>).cast<Map<String, dynamic>>();
      expect(logs.any((l) => l['codepoint'] == customCodepoint), isTrue);
    });

    test('5.2 Universal Invariance: Unregistering source leaves user_progress.db 100% intact', () {
      // 1. Register custom source and practice character
      final customSource = MockCustomMetadataSource(
        sourceId: 'custom_rare_pkg',
        entries: {customCodepoint: customEntry},
      );
      registry.registerMetadataSource(customSource, priority: 100);

      scheduler.recordPracticeCompletion(
        userDb: userDb,
        codepoint: customCodepoint,
        mistakes: 1,
        hintsUsed: 0,
        now: DateTime.utc(2026, 11, 1, 12, 0),
      );

      final cardBefore = userDb.getCard(customCodepoint)!;

      // 2. Unregister source
      registry.unregisterSource('custom_rare_pkg');
      repository.clearCache();

      // 3. Verify card in database is untouched
      final cardAfter = userDb.getCard(customCodepoint)!;
      expect(cardAfter.codepoint, equals(cardBefore.codepoint));
      expect(cardAfter.stability, equals(cardBefore.stability));
      expect(cardAfter.difficulty, equals(cardBefore.difficulty));
      expect(cardAfter.reps, equals(cardBefore.reps));
      expect(cardAfter.dueDate, equals(cardBefore.dueDate));
    });

    test('5.3 Non-Destructive Dangling Card Skipping in buildDailyQueue', () {
      // 1. Practice custom kanji and set its due date to the past
      scheduler.recordPracticeCompletion(
        userDb: userDb,
        codepoint: customCodepoint,
        mistakes: 0,
        hintsUsed: 0,
        now: DateTime.utc(2026, 10, 1, 12, 0),
      );

      // Force due card
      final pastDue = DateTime.utc(2026, 10, 2, 12, 0);
      final existing = userDb.getCard(customCodepoint)!;
      userDb.upsertCard(copyWithDueDate(existing, pastDue));

      // 2. Build daily queue without custom source registered
      final queue = scheduler.buildDailyQueue(
        repository: repository,
        userDb: userDb,
        dailyNewLimit: 5,
        now: DateTime.utc(2026, 11, 1, 12, 0),
      );

      // 3. Verify customCodepoint is safely omitted
      expect(queue.any((q) => q.kanji.codepoint == customCodepoint), isFalse);

      // 4. Verify card still exists in SQLite (NOT deleted!)
      final card = userDb.getCard(customCodepoint);
      expect(card, isNotNull);
      expect(card!.codepoint, equals(customCodepoint));
    });

    test('5.4 Automatic Restoration: Card immediately reappears in queue when source re-registered', () {
      // 1. Card due in past
      final pastDue = DateTime.utc(2026, 10, 2, 12, 0);
      scheduler.recordPracticeCompletion(
        userDb: userDb,
        codepoint: customCodepoint,
        mistakes: 0,
        hintsUsed: 0,
        now: DateTime.utc(2026, 10, 1, 12, 0),
      );
      final card = userDb.getCard(customCodepoint)!;
      userDb.upsertCard(copyWithDueDate(card, pastDue));

      // 2. Re-register custom source
      final customSource = MockCustomMetadataSource(
        sourceId: 'custom_rare_pkg',
        entries: {customCodepoint: customEntry},
      );
      registry.registerMetadataSource(customSource, priority: 100);
      repository.clearCache();

      // 3. Build daily queue
      final queue = scheduler.buildDailyQueue(
        repository: repository,
        userDb: userDb,
        dailyNewLimit: 5,
        now: DateTime.utc(2026, 11, 1, 12, 0),
      );

      // 4. Verify custom codepoint is now present in queue with its existing progress
      final item = queue.firstWhere((q) => q.kanji.codepoint == customCodepoint);
      expect(item, isNotNull);
      expect(item.isNew, isFalse);
      expect(item.existingProgress!.codepoint, equals(customCodepoint));
      expect(item.existingProgress!.reps, equals(1));
    });

    test('5.5 Multi-Source Spaced Repetition Interleaving: Bundled and custom due cards interleave cleanly', () {
      // 0x4E00 is bundled '一', 0x9FFF is custom '鿿'
      final pastDue = DateTime.utc(2026, 10, 1, 12, 0);

      // Practice bundled
      scheduler.recordPracticeCompletion(
        userDb: userDb,
        codepoint: 0x4E00,
        mistakes: 0,
        hintsUsed: 0,
        now: pastDue,
      );
      userDb.upsertCard(copyWithDueDate(userDb.getCard(0x4E00)!, pastDue));

      // Practice custom
      scheduler.recordPracticeCompletion(
        userDb: userDb,
        codepoint: customCodepoint,
        mistakes: 0,
        hintsUsed: 0,
        now: pastDue,
      );
      userDb.upsertCard(copyWithDueDate(userDb.getCard(customCodepoint)!, pastDue));

      // Register custom source
      final customSource = MockCustomMetadataSource(
        sourceId: 'custom_interleave_pkg',
        entries: {customCodepoint: customEntry},
      );
      registry.registerMetadataSource(customSource, priority: 100);
      repository.clearCache();

      final queue = scheduler.buildDailyQueue(
        repository: repository,
        userDb: userDb,
        dailyNewLimit: 2,
        now: DateTime.utc(2026, 11, 1, 12, 0),
      );

      final dueCodepoints = queue.where((q) => !q.isNew).map((q) => q.kanji.codepoint).toList();
      expect(dueCodepoints, contains(0x4E00));
      expect(dueCodepoints, contains(customCodepoint));
    });
  });
}
