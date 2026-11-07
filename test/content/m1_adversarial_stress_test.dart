import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_kanji_practice/src/content/contracts/kanji_audio_source.dart';
import 'package:offline_kanji_practice/src/content/contracts/kanji_metadata_source.dart';
import 'package:offline_kanji_practice/src/content/sources/bundled/bundled_metadata_source.dart';
import 'package:offline_kanji_practice/src/content/sources/bundled/bundled_stroke_source.dart';
import 'package:offline_kanji_practice/src/content/sources/bundled/default_tts_audio_source.dart';
import 'package:offline_kanji_practice/src/data/content_db.dart';
import 'package:offline_kanji_practice/src/services/speech_service.dart';

void main() {
  group('Adversarial M1 Stress Suite: Boundary & Extreme Codepoints', () {
    late ContentDatabase contentDb;
    late BundledMetadataSource metadataSource;
    late BundledStrokeSource strokeSource;
    late DefaultTtsAudioSource audioSourceWithDb;
    late DefaultTtsAudioSource audioSourceWithoutDb;
    late FakeSpeechService speechService;

    setUp(() {
      contentDb = ContentDatabase.openFromFile(File('assets/db/kanji_content.db'));
      metadataSource = BundledMetadataSource(contentDb: contentDb);
      strokeSource = BundledStrokeSource(contentDb: contentDb);
      speechService = FakeSpeechService(japaneseAvailable: true);
      audioSourceWithDb = DefaultTtsAudioSource(
        speechService: speechService,
        contentDb: contentDb,
      );
      audioSourceWithoutDb = DefaultTtsAudioSource(
        speechService: speechService,
      );
    });

    tearDown(() {
      contentDb.close();
    });

    const extremeCodepoints = <int>[
      -2147483648, // Integer 32-bit minimum
      -99999,
      -1,
      0,
      0xD800, // High surrogate boundary
      0xDBFF, // High surrogate upper boundary
      0xDC00, // Low surrogate boundary
      0xDFFF, // Low surrogate upper boundary
      0x10FFFF, // Unicode max boundary
      0x110000, // First beyond-Unicode scalar
      0x7FFFFFFF, // Integer 32-bit max
    ];

    test('BundledMetadataSource never crashes on extreme codepoints', () async {
      for (final cp in extremeCodepoints) {
        final meta = await metadataSource.getMetadata(cp);
        expect(meta, isNull, reason: 'Codepoint $cp should yield null metadata');
      }
    });

    test('BundledStrokeSource gracefully rejects extreme codepoints without throwing', () async {
      for (final cp in extremeCodepoints) {
        final strokes = await strokeSource.getStrokes(cp);
        final contains = await strokeSource.containsStrokes(cp);
        expect(strokes, isNull, reason: 'Codepoint $cp must yield null strokes');
        expect(contains, isFalse, reason: 'Codepoint $cp must yield false containsStrokes');
      }
    });

    test('DefaultTtsAudioSource (with db) gracefully handles extreme codepoints', () async {
      for (final cp in extremeCodepoints) {
        final audio = await audioSourceWithDb.getAudio(cp);
        final contains = await audioSourceWithDb.containsAudio(cp);
        expect(audio, isNull, reason: 'Codepoint $cp without reading should yield null audio');
        expect(contains, isFalse, reason: 'Codepoint $cp without reading should yield false containsAudio');
      }
    });

    test('DefaultTtsAudioSource (without db) strictly guards Unicode scalar range', () async {
      // Negative and zero codepoints must return null / false
      for (final cp in [-2147483648, -99999, -1, 0]) {
        expect(await audioSourceWithoutDb.getAudio(cp), isNull);
        expect(await audioSourceWithoutDb.containsAudio(cp), isFalse);
      }

      // Beyond-Unicode codepoints must return null / false without RangeError
      for (final cp in [0x110000, 0x7FFFFFFF]) {
        expect(await audioSourceWithoutDb.getAudio(cp), isNull);
        expect(await audioSourceWithoutDb.containsAudio(cp), isFalse);
      }

      // Valid boundary 0x10FFFF must produce valid String.fromCharCode without throwing RangeError
      final maxScalarAudio = await audioSourceWithoutDb.getAudio(0x10FFFF);
      expect(maxScalarAudio, isNotNull);
      expect(maxScalarAudio!.type, equals(AudioPayloadType.ttsFallback));
      expect(await audioSourceWithoutDb.containsAudio(0x10FFFF), isTrue);

      // Surrogate codepoints in UTF-16
      final surrogateAudio = await audioSourceWithoutDb.getAudio(0xD800);
      expect(surrogateAudio, isNotNull);
      expect(surrogateAudio!.type, equals(AudioPayloadType.ttsFallback));
    });
  });

  group('Adversarial M1 Stress Suite: Distractor Generator Stress & Exhaustion', () {
    late ContentDatabase contentDb;
    late BundledMetadataSource metadataSource;
    late KanjiMetadataEntry sunEntry;

    setUp(() async {
      contentDb = ContentDatabase.openFromFile(File('assets/db/kanji_content.db'));
      metadataSource = BundledMetadataSource(contentDb: contentDb);
      final meta = await metadataSource.getMetadata(0x65E5); // '日'
      expect(meta, isNotNull);
      sunEntry = meta!;
    });

    tearDown(() {
      contentDb.close();
    });

    test('Distractor count edge cases (count = 0, negative, 1, 1000)', () async {
      for (final c in [0, -1, -50, -99999]) {
        final meanings = await metadataSource.generateMeaningDistractors(sunEntry, count: c);
        final readings = await metadataSource.generateReadingDistractors(sunEntry, count: c);
        expect(meanings, isEmpty, reason: 'Count $c should produce empty meaning list');
        expect(readings, isEmpty, reason: 'Count $c should produce empty reading list');
      }

      // Massive count (1000) requests 1000 distractors
      final count1000Meanings = await metadataSource.generateMeaningDistractors(sunEntry, count: 1000);
      expect(count1000Meanings.length, equals(1000));
      expect(count1000Meanings.toSet().length, equals(1000),
          reason: 'All returned distractors must be mutually distinct');

      // Beyond-database count (50000) exhausts all available distinct meanings
      final exhaustedMeanings = await metadataSource.generateMeaningDistractors(sunEntry, count: 50000);
      expect(exhaustedMeanings.isNotEmpty, isTrue);
      expect(exhaustedMeanings.length, lessThan(50000));
      expect(exhaustedMeanings.toSet().length, equals(exhaustedMeanings.length),
          reason: 'Exhausted distractor list must contain only unique meanings');

      final count1000Readings = await metadataSource.generateReadingDistractors(sunEntry, count: 1000);
      expect(count1000Readings.length, equals(1000));
      expect(count1000Readings.toSet().length, equals(1000),
          reason: 'All returned reading distractors must be mutually distinct');
    });

    test('Distractor generator against synthetic entry with empty / null fields', () async {
      const bareSynthetic = KanjiMetadataEntry(
        codepoint: 0x99999,
        literal: '?',
        strokeCount: 0,
        grade: null,
        jlptLevel: null,
        frequency: null,
        onyomi: [],
        kunyomi: [],
        meanings: [],
        radical: null,
      );

      final meanings = await metadataSource.generateMeaningDistractors(bareSynthetic, count: 5);
      expect(meanings.length, equals(5));

      final readings = await metadataSource.generateReadingDistractors(bareSynthetic, count: 5);
      expect(readings.length, equals(5));
    });

    test('Distractor generator against synthetic entry sharing all meanings with pool', () async {
      // Target contains common meanings: should filter them all out cleanly
      final allDbMeanings = <String>[];
      final allCps = await metadataSource.getAllCodepoints();
      for (final cp in allCps.take(5)) {
        final entry = await metadataSource.getMetadata(cp);
        if (entry != null) {
          allDbMeanings.addAll(entry.meanings);
        }
      }

      final collisionTarget = KanjiMetadataEntry(
        codepoint: 0x99998,
        literal: 'X',
        strokeCount: 1,
        meanings: allDbMeanings,
      );

      final distractors = await metadataSource.generateMeaningDistractors(collisionTarget, count: 3);
      expect(distractors.length, equals(3));
      for (final d in distractors) {
        expect(allDbMeanings.map((m) => m.toLowerCase()).contains(d.toLowerCase()), isFalse);
      }
    });
  });

  group('Adversarial M1 Stress Suite: Audio Source Edge Cases', () {
    late ContentDatabase contentDb;
    late FakeSpeechService speechService;
    late DefaultTtsAudioSource audioSource;

    setUp(() {
      contentDb = ContentDatabase.openFromFile(File('assets/db/kanji_content.db'));
      speechService = FakeSpeechService(japaneseAvailable: true);
      audioSource = DefaultTtsAudioSource(
        speechService: speechService,
        contentDb: contentDb,
      );
    });

    tearDown(() {
      contentDb.close();
    });

    test('Whitespace-only and empty readings', () async {
      // Whitespace reading on valid codepoint falls back to database reading
      final audioWs = await audioSource.getAudio(0x4E00, reading: '   \t  \n  ');
      expect(audioWs, isNotNull);
      expect(audioWs!.uriOrText.trim().isNotEmpty, isTrue);
      expect(audioWs.uriOrText, isNot(contains('\t')));

      // Whitespace reading on non-existent codepoint falls back to null
      final audioWsInvalid = await audioSource.getAudio(-999, reading: '   ');
      expect(audioWsInvalid, isNull);

      // Empty reading on non-existent codepoint
      final audioEmptyInvalid = await audioSource.getAudio(-999, reading: '');
      expect(audioEmptyInvalid, isNull);
    });

    test('Voice availability toggling does not corrupt internal state', () async {
      expect(await audioSource.containsAudio(0x4E00), isTrue);

      // Toggle voice offline
      speechService.japaneseAvailable = false;
      expect(await audioSource.containsAudio(0x4E00), isFalse);
      expect(await audioSource.containsAudio(0x4E00, reading: 'イチ'), isFalse);

      // getAudio still delivers AudioPronunciation with ttsFallback payload
      final audio = await audioSource.getAudio(0x4E00);
      expect(audio, isNotNull);
      expect(audio!.type, equals(AudioPayloadType.ttsFallback));

      // Toggle voice back online
      speechService.japaneseAvailable = true;
      expect(await audioSource.containsAudio(0x4E00), isTrue);
    });

    test('Explicit custom reading overrides database readings completely', () async {
      final audio = await audioSource.getAudio(0x4E00, reading: '  カスタムよみ  ');
      expect(audio, isNotNull);
      expect(audio!.reading, equals('カスタムよみ'));
      expect(audio.uriOrText, equals('カスタムよみ'));
    });
  });

  group('Adversarial M1 Stress Suite: Domain Model Resilience & Equality', () {
    test('KanjiMetadataEntry pure-Dart list equality with nulls and duplicates', () {
      const e1 = KanjiMetadataEntry(
        codepoint: 0x4E00,
        literal: '一',
        strokeCount: 1,
        onyomi: ['A', 'B'],
        kunyomi: ['c'],
        meanings: ['one'],
      );

      const e2 = KanjiMetadataEntry(
        codepoint: 0x4E00,
        literal: '一',
        strokeCount: 1,
        onyomi: ['A', 'B'],
        kunyomi: ['c'],
        meanings: ['one'],
      );

      const eDifferentOrder = KanjiMetadataEntry(
        codepoint: 0x4E00,
        literal: '一',
        strokeCount: 1,
        onyomi: ['B', 'A'], // Different order
        kunyomi: ['c'],
        meanings: ['one'],
      );

      expect(e1 == e2, isTrue);
      expect(e1 == eDifferentOrder, isFalse);
      expect(e1.hashCode == e2.hashCode, isTrue);
      expect(e1.hashCode == eDifferentOrder.hashCode, isFalse);
    });

    test('KanjiMetadataEntry.fromMap resilience to varied schema keys', () {
      final mapWithCamelCase = <String, Object?>{
        'codepoint': 0x4E00,
        'literal': '一',
        'strokeCount': 1,
        'jlptLevel': 5,
        'grade': 1,
        'onyomi': <dynamic>['ICHI'],
        'kunyomi': <dynamic>['hito'],
        'meanings': <dynamic>['one'],
      };

      final fromCamel = KanjiMetadataEntry.fromMap(mapWithCamelCase);
      expect(fromCamel.strokeCount, equals(1));
      expect(fromCamel.jlptLevel, equals(5));
      expect(fromCamel.radical, isNull);

      final mapWithSnakeCase = <String, Object?>{
        'codepoint': 0x4E00,
        'literal': '一',
        'stroke_count': 1,
        'jlpt_level': 5,
        'grade': 1,
        'onyomi': <dynamic>['ICHI'],
        'kunyomi': <dynamic>['hito'],
        'meanings': <dynamic>['one'],
      };

      final fromSnake = KanjiMetadataEntry.fromMap(mapWithSnakeCase);
      expect(fromSnake, equals(fromCamel));
    });

    test('KanjiMetadataEntry unicodeHex on zero, small, and high codepoints', () {
      const eZero = KanjiMetadataEntry(codepoint: 0, literal: '', strokeCount: 0);
      expect(eZero.unicodeHex, equals('U+0000'));

      const eAscii = KanjiMetadataEntry(codepoint: 65, literal: 'A', strokeCount: 1);
      expect(eAscii.unicodeHex, equals('U+0041'));

      const eSurrogate = KanjiMetadataEntry(codepoint: 0xD800, literal: '', strokeCount: 0);
      expect(eSurrogate.unicodeHex, equals('U+D800'));

      const eMax = KanjiMetadataEntry(codepoint: 0x10FFFF, literal: '', strokeCount: 0);
      expect(eMax.unicodeHex, equals('U+10FFFF'));
    });
  });

  group('Adversarial M1 Stress Suite: Concurrency & Reentrancy', () {
    late ContentDatabase contentDb;
    late BundledMetadataSource metadataSource;
    late BundledStrokeSource strokeSource;

    setUp(() {
      contentDb = ContentDatabase.openFromFile(File('assets/db/kanji_content.db'));
      metadataSource = BundledMetadataSource(contentDb: contentDb);
      strokeSource = BundledStrokeSource(contentDb: contentDb);
    });

    tearDown(() {
      contentDb.close();
    });

    test('500 concurrent interleaved reads execute without database locks or corruption', () async {
      final futures = <Future<void>>[];

      for (var i = 0; i < 500; i++) {
        final codepoint = (i % 2 == 0) ? 0x4E00 : 0x5341;
        futures.add(() async {
          final meta = await metadataSource.getMetadata(codepoint);
          expect(meta, isNotNull);
          final strokes = await strokeSource.getStrokes(codepoint);
          expect(strokes, isNotNull);
          expect(strokes!.isNotEmpty, isTrue);
          final contains = await strokeSource.containsStrokes(codepoint);
          expect(contains, isTrue);
        }());
      }

      await Future.wait(futures);
    });

    test('10 concurrent distractor generation calls execute stably', () async {
      final sun = await metadataSource.getMetadata(0x65E5);
      expect(sun, isNotNull);

      final futures = List.generate(10, (i) async {
        final count = (i % 5) + 1;
        final meaningDistractors = await metadataSource.generateMeaningDistractors(sun!, count: count);
        expect(meaningDistractors.length, equals(count));

        final readingDistractors = await metadataSource.generateReadingDistractors(sun, count: count);
        expect(readingDistractors.length, equals(count));
      });

      await Future.wait(futures);
    });
  });
}
