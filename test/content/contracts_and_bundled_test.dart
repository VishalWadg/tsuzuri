import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_kanji_practice/src/content/contracts/kanji_audio_source.dart';
import 'package:offline_kanji_practice/src/content/contracts/kanji_metadata_source.dart';
import 'package:offline_kanji_practice/src/content/contracts/kanji_stroke_source.dart';
import 'package:offline_kanji_practice/src/content/sources/bundled/bundled_metadata_source.dart';
import 'package:offline_kanji_practice/src/content/sources/bundled/bundled_stroke_source.dart';
import 'package:offline_kanji_practice/src/content/sources/bundled/default_tts_audio_source.dart';
import 'package:offline_kanji_practice/src/data/content_db.dart';
import 'package:offline_kanji_practice/src/matching/point2d.dart';
import 'package:offline_kanji_practice/src/matching/stroke_matcher.dart';
import 'package:offline_kanji_practice/src/services/speech_service.dart';

// ============================================================================
// Deterministic Mocks for Isolated Contract Verification
// ============================================================================

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

  MockCustomMetadataSource({
    this.sourceId = 'mock_custom_meta',
    this.displayName = 'Mock Custom Metadata',
    this.version = '2.1.0',
    this.isBundledDefault = false,
    Map<int, KanjiMetadataEntry>? entries,
  }) : entries = entries ?? {};

  @override
  Future<KanjiMetadataEntry?> getMetadata(int codepoint) async => entries[codepoint];

  @override
  Future<List<int>> getAllCodepoints() async => entries.keys.toList();

  @override
  Future<int> getCharacterCount() async => entries.length;

  @override
  Future<List<String>> generateMeaningDistractors(
    KanjiMetadataEntry target, {
    int count = 3,
  }) async {
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

  MockCustomStrokeSource({
    this.sourceId = 'mock_custom_strokes',
    this.displayName = 'Mock Custom Strokes',
    this.version = '0.9.0',
    this.isBundledDefault = false,
    Map<int, List<ReferenceStroke>>? strokeMap,
  }) : strokeMap = strokeMap ?? {};

  @override
  Future<List<ReferenceStroke>?> getStrokes(int codepoint) async => strokeMap[codepoint];

  @override
  Future<bool> containsStrokes(int codepoint) async => strokeMap.containsKey(codepoint);
}

class MockCustomAudioSource implements IKanjiAudioSource {
  @override
  final String sourceId;
  @override
  final String displayName;
  @override
  final String version;
  @override
  final bool isBundledDefault;

  final Map<int, AudioPronunciation> audioEntries;

  MockCustomAudioSource({
    this.sourceId = 'mock_custom_audio',
    this.displayName = 'Mock Custom Audio',
    this.version = '1.0.0',
    this.isBundledDefault = false,
    Map<int, AudioPronunciation>? audioEntries,
  }) : audioEntries = audioEntries ?? {};

  @override
  Future<AudioPronunciation?> getAudio(int codepoint, {String? reading}) async =>
      audioEntries[codepoint];

  @override
  Future<bool> containsAudio(int codepoint, {String? reading}) async =>
      audioEntries.containsKey(codepoint);
}

// ============================================================================
// Test Suite
// ============================================================================

void main() {
  group('Milestone M1: Domain Models & Value Equality', () {
    test('KanjiMetadataEntry format, equality, serialization and conversion', () {
      const entry1 = KanjiMetadataEntry(
        codepoint: 0x4E00,
        literal: '一',
        strokeCount: 1,
        grade: 1,
        jlptLevel: 5,
        frequency: 2,
        onyomi: ['ICHI', 'ITSU'],
        kunyomi: ['hito', 'hitotsu'],
        meanings: ['one'],
        radical: '一',
      );

      const entry2 = KanjiMetadataEntry(
        codepoint: 0x4E00,
        literal: '一',
        strokeCount: 1,
        grade: 1,
        jlptLevel: 5,
        frequency: 2,
        onyomi: ['ICHI', 'ITSU'],
        kunyomi: ['hito', 'hitotsu'],
        meanings: ['one'],
        radical: '一',
      );

      expect(entry1.unicodeHex, equals('U+4E00'));
      expect(entry1, equals(entry2));
      expect(entry1.hashCode, equals(entry2.hashCode));
      expect(entry1.toString(), contains('U+4E00'));

      // Serialization round-trip
      final map = entry1.toMap();
      final fromMap = KanjiMetadataEntry.fromMap(map);
      expect(fromMap, equals(entry1));

      // CopyWith immutability
      final updated = entry1.copyWith(strokeCount: 2);
      expect(updated.strokeCount, equals(2));
      expect(entry1.strokeCount, equals(1));
      expect(updated == entry1, isFalse);

      // Conversion to/from KanjiCharacter
      final character = entry1.toKanjiCharacter();
      expect(character.codepoint, equals(0x4E00));
      expect(character.literal, equals('一'));
      final reconverted = KanjiMetadataEntry.fromKanjiCharacter(character, radical: '一');
      expect(reconverted, equals(entry1));
    });

    test('AudioPronunciation payload types, equality and copyWith', () {
      const audio1 = AudioPronunciation(
        type: AudioPayloadType.asset,
        uriOrText: 'assets/audio/4e00.mp3',
        mimeType: 'audio/mpeg',
        reading: 'イチ',
      );

      const audio2 = AudioPronunciation(
        type: AudioPayloadType.asset,
        uriOrText: 'assets/audio/4e00.mp3',
        mimeType: 'audio/mpeg',
        reading: 'イチ',
      );

      expect(audio1, equals(audio2));
      expect(audio1.hashCode, equals(audio2.hashCode));
      expect(audio1.toString(), contains('AudioPayloadType.asset'));

      final modified = audio1.copyWith(type: AudioPayloadType.localFile);
      expect(modified.type, equals(AudioPayloadType.localFile));
      expect(modified == audio1, isFalse);

      // Test all enum values
      expect(AudioPayloadType.values, contains(AudioPayloadType.localFile));
      expect(AudioPayloadType.values, contains(AudioPayloadType.asset));
      expect(AudioPayloadType.values, contains(AudioPayloadType.remoteUrl));
      expect(AudioPayloadType.values, contains(AudioPayloadType.ttsFallback));
    });
  });

  group('Milestone M1: Metadata Source & Bundled Adapter', () {
    late ContentDatabase contentDb;
    late BundledMetadataSource bundledSource;

    setUp(() {
      contentDb = ContentDatabase.openFromFile(File('assets/db/kanji_content.db'));
      bundledSource = BundledMetadataSource(contentDb: contentDb);
    });

    tearDown(() {
      contentDb.close();
    });

    test('IKanjiMetadataSource contract with MockCustomMetadataSource', () async {
      const customEntry = KanjiMetadataEntry(
        codepoint: 0x9999,
        literal: '𠮷',
        strokeCount: 6,
        meanings: ['fortune', 'luck'],
        onyomi: ['KICHI'],
        kunyomi: ['yoshi'],
      );

      final mockSource = MockCustomMetadataSource(
        entries: {0x9999: customEntry},
      );

      expect(mockSource.sourceId, equals('mock_custom_meta'));
      expect(mockSource.displayName, equals('Mock Custom Metadata'));
      expect(mockSource.version, equals('2.1.0'));
      expect(mockSource.isBundledDefault, isFalse);
      expect(await mockSource.getCharacterCount(), equals(1));
      expect(await mockSource.getAllCodepoints(), equals([0x9999]));

      final fetched = await mockSource.getMetadata(0x9999);
      expect(fetched, isNotNull);
      expect(fetched!.literal, equals('𠮷'));
    });

    test('BundledMetadataSource properties and entry queries', () async {
      expect(bundledSource.isBundledDefault, isTrue);
      expect(bundledSource.sourceId, equals('bundled_metadata'));
      expect(bundledSource.displayName, equals('Bundled Kanji Metadata'));
      expect(bundledSource.version, isNotEmpty);
      expect(bundledSource.contentDb, equals(contentDb));

      final sun = await bundledSource.getMetadata(0x65E5); // 日
      expect(sun, isNotNull);
      expect(sun!.literal, equals('日'));
      expect(sun.strokeCount, equals(4));
      expect(sun.grade, equals(1));
      expect(sun.jlptLevel, equals(4));
      expect(sun.meanings.contains('day'), isTrue);

      final allCps = await bundledSource.getAllCodepoints();
      expect(allCps.length, greaterThanOrEqualTo(20));
      expect(allCps.contains(0x65E5), isTrue);

      final totalCount = await bundledSource.getCharacterCount();
      expect(totalCount, equals(allCps.length));
    });
  });

  group('Milestone M1: Stroke Source & Bundled Adapter', () {
    late ContentDatabase contentDb;
    late BundledStrokeSource bundledSource;

    setUp(() {
      contentDb = ContentDatabase.openFromFile(File('assets/db/kanji_content.db'));
      bundledSource = BundledStrokeSource(contentDb: contentDb);
    });

    tearDown(() {
      contentDb.close();
    });

    test('IKanjiStrokeSource contract with MockCustomStrokeSource', () async {
      final mockStroke = ReferenceStroke(
        strokeOrder: 0,
        strokeType: 'horizontal',
        svgPath: 'M 10 50 L 90 50',
        arcLength: 80.0,
        sampledPoints: List.generate(50, (i) => Point2D(10.0 + i * 1.6, 50.0)),
      );

      final mockSource = MockCustomStrokeSource(
        strokeMap: {
          0x4E00: [mockStroke],
        },
      );

      expect(mockSource.isBundledDefault, isFalse);
      expect(mockSource.sourceId, equals('mock_custom_strokes'));
      expect(mockSource.displayName, equals('Mock Custom Strokes'));
      expect(mockSource.version, equals('0.9.0'));
      expect(await mockSource.containsStrokes(0x4E00), isTrue);
      expect(await mockSource.containsStrokes(0x9999), isFalse);

      final strokes = await mockSource.getStrokes(0x4E00);
      expect(strokes, isNotNull);
      expect(strokes!.length, equals(1));
      expect(strokes.first.strokeOrder, equals(0));
    });

    test('BundledStrokeSource returns pre-sampled KanjiVG strokes', () async {
      expect(bundledSource.isBundledDefault, isTrue);
      expect(bundledSource.sourceId, equals('bundled_strokes'));
      expect(bundledSource.displayName, equals('Bundled KanjiVG Strokes'));
      expect(bundledSource.contentDb, equals(contentDb));

      // Check '一' (0x4E00)
      expect(await bundledSource.containsStrokes(0x4E00), isTrue);
      final oneStrokes = await bundledSource.getStrokes(0x4E00);
      expect(oneStrokes, isNotNull);
      expect(oneStrokes!.length, equals(1));
      expect(oneStrokes.first.strokeOrder, equals(0));
      expect(oneStrokes.first.sampledPoints.length, equals(50));
      expect(oneStrokes.first.arcLength, greaterThan(0));

      // Check '十' (0x5341)
      expect(await bundledSource.containsStrokes(0x5341), isTrue);
      final tenStrokes = await bundledSource.getStrokes(0x5341);
      expect(tenStrokes, isNotNull);
      expect(tenStrokes!.length, equals(2));
    });
  });

  group('Milestone M1: Audio Source & Bundled TTS Adapter', () {
    late FakeSpeechService fakeSpeech;
    late ContentDatabase contentDb;

    setUp(() {
      fakeSpeech = FakeSpeechService(japaneseAvailable: true);
      contentDb = ContentDatabase.openFromFile(File('assets/db/kanji_content.db'));
    });

    tearDown(() {
      contentDb.close();
    });

    test('IKanjiAudioSource contract with MockCustomAudioSource', () async {
      const customAudio = AudioPronunciation(
        type: AudioPayloadType.localFile,
        uriOrText: '/data/audio/custom_4e00.mp3',
        mimeType: 'audio/mpeg',
        reading: 'イチ',
      );

      final mockSource = MockCustomAudioSource(
        audioEntries: {0x4E00: customAudio},
      );

      expect(mockSource.isBundledDefault, isFalse);
      expect(mockSource.sourceId, equals('mock_custom_audio'));
      expect(mockSource.displayName, equals('Mock Custom Audio'));
      expect(mockSource.version, equals('1.0.0'));
      expect(await mockSource.containsAudio(0x4E00), isTrue);
      expect(await mockSource.containsAudio(0x9999), isFalse);

      final res = await mockSource.getAudio(0x4E00);
      expect(res, equals(customAudio));
    });

    test('DefaultTtsAudioSource synthesizes TTS audio payloads', () async {
      final ttsSource = DefaultTtsAudioSource(
        speechService: fakeSpeech,
        contentDb: contentDb,
      );

      expect(ttsSource.isBundledDefault, isTrue);
      expect(ttsSource.sourceId, equals('bundled_tts_audio'));
      expect(ttsSource.displayName, equals('Default TTS Speech'));
      expect(ttsSource.version, equals('1.0.0'));
      expect(ttsSource.speechService, equals(fakeSpeech));
      expect(ttsSource.contentDb, equals(contentDb));
      expect(await ttsSource.containsAudio(0x5341), isTrue);

      // Explicit reading
      final explicitAudio = await ttsSource.getAudio(0x5341, reading: 'じゅう');
      expect(explicitAudio, isNotNull);
      expect(explicitAudio!.type, equals(AudioPayloadType.ttsFallback));
      expect(explicitAudio.uriOrText, equals('じゅう'));
      expect(explicitAudio.reading, equals('じゅう'));

      // Resolved reading from contentDb
      final implicitAudio = await ttsSource.getAudio(0x4E00);
      expect(implicitAudio, isNotNull);
      expect(implicitAudio!.type, equals(AudioPayloadType.ttsFallback));
      expect(implicitAudio.uriOrText.isNotEmpty, isTrue);

      // Reflects unavailable Japanese voice
      fakeSpeech.japaneseAvailable = false;
      expect(await ttsSource.containsAudio(0x4E00), isFalse);
      expect(await ttsSource.containsAudio(0x4E00, reading: 'イチ'), isFalse);
    });

    test('DefaultTtsAudioSource without contentDb falls back to String.fromCharCode', () async {
      final ttsSourceWithoutDb = DefaultTtsAudioSource(
        speechService: fakeSpeech,
      );

      expect(ttsSourceWithoutDb.contentDb, isNull);
      final audio = await ttsSourceWithoutDb.getAudio(0x4E00); // '一'
      expect(audio, isNotNull);
      expect(audio!.type, equals(AudioPayloadType.ttsFallback));
      expect(audio.uriOrText, equals('一'));
      expect(audio.reading, equals('一'));
    });
  });

  group('Milestone M1: Missing Codepoints & Graceful Null Handling', () {
    late ContentDatabase contentDb;
    late BundledMetadataSource metadataSource;
    late BundledStrokeSource strokeSource;
    late DefaultTtsAudioSource audioSource;
    late FakeSpeechService fakeSpeech;

    setUp(() {
      contentDb = ContentDatabase.openFromFile(File('assets/db/kanji_content.db'));
      metadataSource = BundledMetadataSource(contentDb: contentDb);
      strokeSource = BundledStrokeSource(contentDb: contentDb);
      fakeSpeech = FakeSpeechService(japaneseAvailable: true);
      audioSource = DefaultTtsAudioSource(
        speechService: fakeSpeech,
        contentDb: contentDb,
      );
    });

    tearDown(() {
      contentDb.close();
    });

    test('Metadata source gracefully returns null for unmapped and invalid codepoints', () async {
      expect(await metadataSource.getMetadata(0x99999), isNull);
      expect(await metadataSource.getMetadata(-1), isNull);
      expect(await metadataSource.getMetadata(0), isNull);
      expect(await metadataSource.getMetadata(0x999999), isNull);
    });

    test('Stroke source gracefully returns null and false for unmapped and invalid codepoints', () async {
      expect(await strokeSource.getStrokes(0x99999), isNull);
      expect(await strokeSource.containsStrokes(0x99999), isFalse);
      expect(await strokeSource.getStrokes(-1), isNull);
      expect(await strokeSource.containsStrokes(-1), isFalse);
      expect(await strokeSource.getStrokes(0), isNull);
      expect(await strokeSource.containsStrokes(0), isFalse);
      expect(await strokeSource.getStrokes(0x999999), isNull);
      expect(await strokeSource.containsStrokes(0x999999), isFalse);
    });

    test('Audio source gracefully returns null and false without RangeError', () async {
      expect(await audioSource.getAudio(-1), isNull);
      expect(await audioSource.getAudio(0), isNull);
      // Unicode out-of-range codepoint must not throw RangeError via String.fromCharCode
      expect(await audioSource.getAudio(0x999999), isNull);
      expect(await audioSource.containsAudio(-1), isFalse);
      expect(await audioSource.containsAudio(0), isFalse);
      expect(await audioSource.containsAudio(0x999999), isFalse);

      // But if explicit reading is provided for unmapped codepoint, it can speak it
      final customReadingAudio = await audioSource.getAudio(0x999999, reading: 'テスト');
      expect(customReadingAudio, isNotNull);
      expect(customReadingAudio!.uriOrText, equals('テスト'));
      expect(await audioSource.containsAudio(0x999999, reading: 'テスト'), isTrue);

      // Testing without contentDb for out-of-range codepoints
      final audioSourceWithoutDb = DefaultTtsAudioSource(speechService: fakeSpeech);
      expect(await audioSourceWithoutDb.getAudio(-1), isNull);
      expect(await audioSourceWithoutDb.getAudio(0), isNull);
      expect(await audioSourceWithoutDb.getAudio(0x999999), isNull);
      expect(await audioSourceWithoutDb.containsAudio(-1), isFalse);
      expect(await audioSourceWithoutDb.containsAudio(0), isFalse);
      expect(await audioSourceWithoutDb.containsAudio(0x999999), isFalse);
    });
  });

  group('Milestone M1: Distractor Generation Through Metadata Contract', () {
    late ContentDatabase contentDb;
    late BundledMetadataSource metadataSource;
    late KanjiMetadataEntry sunEntry;
    late KanjiMetadataEntry tenEntry;

    setUp(() async {
      contentDb = ContentDatabase.openFromFile(File('assets/db/kanji_content.db'));
      metadataSource = BundledMetadataSource(contentDb: contentDb);
      final loadedSun = await metadataSource.getMetadata(0x65E5); // 日
      final loadedTen = await metadataSource.getMetadata(0x5341); // 十
      expect(loadedSun, isNotNull);
      expect(loadedTen, isNotNull);
      sunEntry = loadedSun!;
      tenEntry = loadedTen!;
    });

    tearDown(() {
      contentDb.close();
    });

    test('generateMeaningDistractors returns distinct, non-overlapping meanings', () async {
      final distractors = await metadataSource.generateMeaningDistractors(sunEntry, count: 3);
      expect(distractors.length, equals(3));
      expect(distractors.toSet().length, equals(3), reason: 'Distractors must be unique');

      final sunMeaningsLower = sunEntry.meanings.map((m) => m.toLowerCase().trim()).toSet();
      for (final d in distractors) {
        expect(sunMeaningsLower.contains(d.toLowerCase()), isFalse,
            reason: 'Distractor "$d" must not overlap with target meanings');
      }

      // Count parameter variations
      final distractors1 = await metadataSource.generateMeaningDistractors(sunEntry, count: 1);
      expect(distractors1.length, equals(1));

      final distractors5 = await metadataSource.generateMeaningDistractors(sunEntry, count: 5);
      expect(distractors5.length, equals(5));

      final distractors0 = await metadataSource.generateMeaningDistractors(sunEntry, count: 0);
      expect(distractors0, isEmpty);

      final distractorsNegative = await metadataSource.generateMeaningDistractors(sunEntry, count: -1);
      expect(distractorsNegative, isEmpty);
    });

    test('generateReadingDistractors returns distinct, non-overlapping readings', () async {
      final distractors = await metadataSource.generateReadingDistractors(tenEntry, count: 3);
      expect(distractors.length, equals(3));
      expect(distractors.toSet().length, equals(3), reason: 'Readings must be unique');

      final targetReadings = {...tenEntry.onyomi, ...tenEntry.kunyomi}.map((r) => r.trim()).toSet();
      for (final d in distractors) {
        expect(targetReadings.contains(d), isFalse,
            reason: 'Distractor reading "$d" must not overlap with target readings');
      }

      final distractors0 = await metadataSource.generateReadingDistractors(tenEntry, count: 0);
      expect(distractors0, isEmpty);

      final distractorsNegative = await metadataSource.generateReadingDistractors(tenEntry, count: -1);
      expect(distractorsNegative, isEmpty);
    });

    test('Distractor generation functions cleanly for synthetic custom targets', () async {
      const synthetic = KanjiMetadataEntry(
        codepoint: 0x9999,
        literal: '𠮷',
        strokeCount: 6,
        meanings: ['custom_unique_meaning'],
        onyomi: ['CUSTOM_ONYOMI'],
        kunyomi: ['custom_kunyomi'],
      );

      final meaningDistractors = await metadataSource.generateMeaningDistractors(synthetic, count: 3);
      expect(meaningDistractors.length, equals(3));
      expect(meaningDistractors.contains('custom_unique_meaning'), isFalse);

      final readingDistractors = await metadataSource.generateReadingDistractors(synthetic, count: 3);
      expect(readingDistractors.length, equals(3));
      expect(readingDistractors.contains('CUSTOM_ONYOMI'), isFalse);
      expect(readingDistractors.contains('custom_kunyomi'), isFalse);
    });
  });
}
