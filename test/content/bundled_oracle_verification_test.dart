import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_kanji_practice/src/content/contracts/kanji_audio_source.dart';
import 'package:offline_kanji_practice/src/content/sources/bundled/bundled_metadata_source.dart';
import 'package:offline_kanji_practice/src/content/sources/bundled/bundled_stroke_source.dart';
import 'package:offline_kanji_practice/src/content/sources/bundled/default_tts_audio_source.dart';
import 'package:offline_kanji_practice/src/data/content_db.dart';
import 'package:offline_kanji_practice/src/data/models.dart';
import 'package:offline_kanji_practice/src/services/speech_service.dart';

void main() {
  late ContentDatabase contentDb;
  late BundledMetadataSource bundledMeta;
  late BundledStrokeSource bundledStroke;
  late DefaultTtsAudioSource defaultTts;
  late FakeSpeechService fakeSpeech;

  setUpAll(() {
    final dbFile = File('assets/db/kanji_content.db');
    expect(dbFile.existsSync(), isTrue, reason: 'Bundled database asset must exist');
    contentDb = ContentDatabase.openFromFile(dbFile);
    bundledMeta = BundledMetadataSource(contentDb: contentDb);
    bundledStroke = BundledStrokeSource(contentDb: contentDb);
    fakeSpeech = FakeSpeechService(japaneseAvailable: true);
    defaultTts = DefaultTtsAudioSource(speechService: fakeSpeech, contentDb: contentDb);
  });

  tearDownAll(() {
    contentDb.close();
  });

  group('Milestone M1 Oracle Verification: Aggregate Consistency', () {
    test('bundledMeta.getCharacterCount() matches contentDb.totalKanjiCount exactly', () async {
      final expectedCount = contentDb.totalKanjiCount;
      final actualCount = await bundledMeta.getCharacterCount();
      expect(actualCount, equals(expectedCount));
      expect(actualCount, greaterThan(0));
    });

    test('bundledMeta.getAllCodepoints() matches contentDb.getOrderedCodepoints() exactly in order and elements', () async {
      final expectedCodepoints = contentDb.getOrderedCodepoints();
      final actualCodepoints = await bundledMeta.getAllCodepoints();

      expect(actualCodepoints.length, equals(expectedCodepoints.length));
      expect(actualCodepoints, equals(expectedCodepoints));
    });
  });

  group('Milestone M1 Oracle Verification: Differential Consistency Across Representative Kanji Sample', () {
    test('Differential consistency across ALL codepoints in database', () async {
      final allCodepoints = contentDb.getOrderedCodepoints();
      expect(allCodepoints.isNotEmpty, isTrue);

      for (final cp in allCodepoints) {
        final direct = contentDb.getKanjiByCodepoint(cp);
        expect(direct, isNotNull, reason: 'Codepoint $cp from getOrderedCodepoints() must exist in DB');

        // Verify BundledMetadataSource
        final meta = await bundledMeta.getMetadata(cp);
        expect(meta, isNotNull, reason: 'BundledMetadataSource must return entry for codepoint $cp');
        expect(meta!.codepoint, equals(direct!.codepoint));
        expect(meta.literal, equals(direct.literal));
        expect(meta.strokeCount, equals(direct.strokeCount));
        expect(meta.grade, equals(direct.grade));
        expect(meta.jlptLevel, equals(direct.jlptLevel));
        expect(meta.frequency, equals(direct.frequency));
        expect(meta.onyomi, equals(direct.onyomi));
        expect(meta.kunyomi, equals(direct.kunyomi));
        expect(meta.meanings, equals(direct.meanings));
        expect(meta.radical, isNull);

        // Verify conversion toKanjiCharacter
        final reconstructed = meta.toKanjiCharacter(strokes: direct.strokes);
        expect(reconstructed.codepoint, equals(direct.codepoint));
        expect(reconstructed.literal, equals(direct.literal));
        expect(reconstructed.strokeCount, equals(direct.strokeCount));
        expect(reconstructed.meanings, equals(direct.meanings));
        expect(reconstructed.strokes.length, equals(direct.strokes.length));

        // Verify BundledStrokeSource
        final containsStrokes = await bundledStroke.containsStrokes(cp);
        expect(containsStrokes, equals(direct.strokes.isNotEmpty));

        final strokes = await bundledStroke.getStrokes(cp);
        if (direct.strokes.isEmpty) {
          expect(strokes, isNull);
        } else {
          expect(strokes, isNotNull);
          expect(strokes!.length, equals(direct.strokes.length));

          for (var i = 0; i < strokes.length; i++) {
            final sActual = strokes[i];
            final sExpected = direct.strokes[i];
            expect(sActual.strokeOrder, equals(sExpected.strokeOrder));
            expect(sActual.strokeType, equals(sExpected.strokeType));
            expect(sActual.svgPath, equals(sExpected.svgPath));
            expect(sActual.arcLength, equals(sExpected.arcLength));
            expect(sActual.sampledPoints.length, equals(50));
            expect(sActual.sampledPoints.length, equals(sExpected.sampledPoints.length));

            for (var pIdx = 0; pIdx < sActual.sampledPoints.length; pIdx++) {
              expect(sActual.sampledPoints[pIdx].x, equals(sExpected.sampledPoints[pIdx].x));
              expect(sActual.sampledPoints[pIdx].y, equals(sExpected.sampledPoints[pIdx].y));
            }
          }
        }
      }
    });

    test('Representative sample: Single-stroke kanji (e.g. 一 U+4E00)', () async {
      const oneCp = 0x4E00; // '一'
      final direct = contentDb.getKanjiByCodepoint(oneCp);
      expect(direct, isNotNull);
      expect(direct!.strokeCount, equals(1));
      expect(direct.literal, equals('一'));

      final meta = await bundledMeta.getMetadata(oneCp);
      expect(meta, isNotNull);
      expect(meta!.codepoint, equals(0x4E00));
      expect(meta.literal, equals('一'));
      expect(meta.strokeCount, equals(1));
      expect(meta.grade, equals(1));

      final strokes = await bundledStroke.getStrokes(oneCp);
      expect(strokes, isNotNull);
      expect(strokes!.length, equals(1));
      expect(strokes.first.strokeOrder, equals(0));
      expect(strokes.first.sampledPoints.length, equals(50));
    });

    test('Representative sample: Grade 1 Joyo kanji cohort', () async {
      final allKanji = contentDb.getAllKanjiOrdered();
      final grade1List = allKanji.where((k) => k.grade == 1).toList();
      expect(grade1List.isNotEmpty, isTrue);

      for (final direct in grade1List) {
        final meta = await bundledMeta.getMetadata(direct.codepoint);
        expect(meta, isNotNull);
        expect(meta!.grade, equals(1));
        expect(meta.strokeCount, equals(direct.strokeCount));
        expect(meta.literal, equals(direct.literal));

        final strokes = await bundledStroke.getStrokes(direct.codepoint);
        expect(strokes, isNotNull);
        expect(strokes!.length, equals(direct.strokeCount));
      }
    });

    test('Representative sample: High stroke count kanji cohort', () async {
      final allKanji = contentDb.getAllKanjiOrdered();
      // Sort descending by stroke count
      final sortedByStrokes = List.of(allKanji)..sort((a, b) => b.strokeCount.compareTo(a.strokeCount));
      final maxStrokes = sortedByStrokes.first.strokeCount;
      final highStrokeKanji = sortedByStrokes.take(5).toList();

      for (final direct in highStrokeKanji) {
        final meta = await bundledMeta.getMetadata(direct.codepoint);
        expect(meta, isNotNull);
        expect(meta!.strokeCount, equals(direct.strokeCount));

        final strokes = await bundledStroke.getStrokes(direct.codepoint);
        expect(strokes, isNotNull);
        expect(strokes!.length, equals(direct.strokeCount));
        expect(strokes.length, greaterThanOrEqualTo(maxStrokes <= 4 ? 4 : 5));
      }
    });
  });

  group('Milestone M1 Oracle Verification: Distractor Generation Differential Consistency', () {
    test('generateMeaningDistractors yields identical outputs between bundledMeta and contentDb', () async {
      final allKanji = contentDb.getAllKanjiOrdered();
      // Select representative cohort: first 4, middle 3, last 3
      final sample = <KanjiCharacter>[
        ...allKanji.take(4),
        if (allKanji.length > 8) allKanji[allKanji.length ~/ 2],
        if (allKanji.length > 8) allKanji[(allKanji.length ~/ 2) + 1],
        if (allKanji.length > 8) allKanji[(allKanji.length ~/ 2) + 2],
        ...allKanji.reversed.take(3),
      ];

      for (final direct in sample.take(2)) {
        final meta = (await bundledMeta.getMetadata(direct.codepoint))!;
        
        for (final count in [1, 2, 3, 5]) {
          final dbDistractors = contentDb.generateMeaningDistractors(direct, count: count);
          final metaDistractors = await bundledMeta.generateMeaningDistractors(meta, count: count);
          expect(metaDistractors, equals(dbDistractors),
              reason: 'Distractors for ${direct.literal} count=$count must match direct DB query');
        }

        // Test count <= 0 boundary
        expect(await bundledMeta.generateMeaningDistractors(meta, count: 0), isEmpty);
        expect(await bundledMeta.generateMeaningDistractors(meta, count: -1), isEmpty);
      }
    });

    test('generateReadingDistractors yields identical outputs between bundledMeta and contentDb', () async {
      final allKanji = contentDb.getAllKanjiOrdered();
      final sample = <KanjiCharacter>[
        ...allKanji.take(4),
        if (allKanji.length > 8) allKanji[allKanji.length ~/ 2],
        if (allKanji.length > 8) allKanji[(allKanji.length ~/ 2) + 1],
        if (allKanji.length > 8) allKanji[(allKanji.length ~/ 2) + 2],
        ...allKanji.reversed.take(3),
      ];

      for (final direct in sample.take(2)) {
        final meta = (await bundledMeta.getMetadata(direct.codepoint))!;
        
        for (final count in [1, 2, 3, 5]) {
          final dbDistractors = contentDb.generateReadingDistractors(direct, count: count);
          final metaDistractors = await bundledMeta.generateReadingDistractors(meta, count: count);
          expect(metaDistractors, equals(dbDistractors),
              reason: 'Reading distractors for ${direct.literal} count=$count must match direct DB query');
        }

        // Test count <= 0 boundary
        expect(await bundledMeta.generateReadingDistractors(meta, count: 0), isEmpty);
        expect(await bundledMeta.generateReadingDistractors(meta, count: -1), isEmpty);
      }
    });
  });

  group('Milestone M1 Oracle Verification: DefaultTtsAudioSource Differential Reading Resolution', () {
    test('DefaultTtsAudioSource automatically resolves reading matching ContentDatabase', () async {
      final allCodepoints = contentDb.getOrderedCodepoints();
      for (final cp in allCodepoints) {
        final direct = contentDb.getKanjiByCodepoint(cp)!;
        final expectedReading = direct.onyomi.isNotEmpty
            ? direct.onyomi.first
            : (direct.kunyomi.isNotEmpty ? direct.kunyomi.first : direct.literal);

        final audio = await defaultTts.getAudio(cp);
        expect(audio, isNotNull);
        expect(audio!.type, equals(AudioPayloadType.ttsFallback));
        expect(audio.uriOrText, equals(expectedReading));
        expect(audio.reading, equals(expectedReading));

        final hasAudio = await defaultTts.containsAudio(cp);
        expect(hasAudio, isTrue);
      }
    });
  });

  group('Milestone M1 Oracle Verification: Boundary and Non-Existent Codepoints Consistency', () {
    test('Non-existent or boundary codepoints return null / false identically across adapters', () async {
      final nonExistentCodepoints = [
        0,
        -1,
        -99999,
        0x0041, // ASCII 'A' (not in kanji DB)
        0x1F600, // Emoji (not in kanji DB)
        0xD800, // Surrogate
        0x10FFFF, // Max Unicode
        0x110000, // Out of Unicode range
      ];

      for (final cp in nonExistentCodepoints) {
        final direct = contentDb.getKanjiByCodepoint(cp);
        expect(direct, isNull, reason: 'Codepoint $cp must not exist in bundled DB');

        final meta = await bundledMeta.getMetadata(cp);
        expect(meta, isNull, reason: 'BundledMetadataSource must return null for non-existent $cp');

        final strokes = await bundledStroke.getStrokes(cp);
        expect(strokes, isNull, reason: 'BundledStrokeSource must return null for non-existent $cp');

        final hasStrokes = await bundledStroke.containsStrokes(cp);
        expect(hasStrokes, isFalse, reason: 'BundledStrokeSource containsStrokes must be false for $cp');

        final hasAudioWithoutReading = await defaultTts.containsAudio(cp);
        expect(hasAudioWithoutReading, isFalse,
            reason: 'DefaultTtsAudioSource without reading must return false for missing $cp');

        final audioWithoutReading = await defaultTts.getAudio(cp);
        expect(audioWithoutReading, isNull,
            reason: 'DefaultTtsAudioSource without reading must return null for missing $cp');
      }
    });
  });
}
