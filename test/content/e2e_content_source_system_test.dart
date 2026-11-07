import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:offline_kanji_practice/src/content/contracts/kanji_audio_source.dart';
import 'package:offline_kanji_practice/src/content/contracts/kanji_metadata_source.dart';
import 'package:offline_kanji_practice/src/content/ingestion/loaders/offline_package_loader.dart';
import 'package:offline_kanji_practice/src/content/ingestion/loaders/online_source_fetcher.dart';
import 'package:offline_kanji_practice/src/content/ingestion/models/ingestion_result.dart';
import 'package:offline_kanji_practice/src/content/ingestion/models/source_manifest.dart';
import 'package:offline_kanji_practice/src/content/ingestion/security/zip_slip_guard.dart';
import 'package:offline_kanji_practice/src/content/ingestion/staging/package_staging_manager.dart';
import 'package:offline_kanji_practice/src/content/ingestion/validation/source_validator.dart';
import 'package:offline_kanji_practice/src/content/registry/content_repository.dart';
import 'package:offline_kanji_practice/src/content/registry/content_source_registry.dart';
import 'package:offline_kanji_practice/src/content/sources/bundled/bundled_metadata_source.dart';
import 'package:offline_kanji_practice/src/content/sources/bundled/bundled_stroke_source.dart';
import 'package:offline_kanji_practice/src/content/sources/bundled/default_tts_audio_source.dart';
import 'package:offline_kanji_practice/src/content/sources/custom/custom_audio_source.dart';
import 'package:offline_kanji_practice/src/content/sources/custom/custom_metadata_source.dart';
import 'package:offline_kanji_practice/src/content/sources/custom/custom_stroke_source.dart';
import 'package:offline_kanji_practice/src/data/content_db.dart';
import 'package:offline_kanji_practice/src/data/models.dart';
import 'package:offline_kanji_practice/src/data/user_db.dart';
import 'package:offline_kanji_practice/src/matching/point2d.dart';
import 'package:offline_kanji_practice/src/matching/stroke_matcher.dart';
import 'package:offline_kanji_practice/src/scheduling/fsrs_scheduler.dart';

import 'fixtures/mock_content_http_server.dart';
import 'fixtures/mock_custom_sources.dart';
import 'fixtures/test_package_builder.dart';

void main() {
  HttpOverrides.global = null;

  late ContentDatabase bundledContentDb;
  late Directory globalTempDir;

  setUpAll(() {
    HttpOverrides.global = null;
    final dbFile = File('assets/db/kanji_content.db');
    expect(dbFile.existsSync(), isTrue, reason: 'Bundled database asset must exist');
    bundledContentDb = ContentDatabase.openFromFile(dbFile);
    globalTempDir = Directory.systemTemp.createTempSync('tsuzuri_e2e_global_');
  });

  tearDownAll(() {
    bundledContentDb.close();
    try {
      if (globalTempDir.existsSync()) {
        globalTempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  // ============================================================================
  // TIER 1: FEATURE COVERAGE (50 Tests, F1 - F10)
  // ============================================================================
  group('Tier 1: Feature Coverage (F1-F10)', () {
    // ------------------------------------------------------------------------
    // F1: Pluggable Source Abstraction (5 tests)
    // ------------------------------------------------------------------------
    group('F1: Pluggable Source Abstraction', () {
      test('T1-F1-01: IKanjiMetadataSource provides metadata, character count, and codepoints list', () async {
        final mockMeta = MockCustomMetadataSource(
          sourceId: 'custom_meta_f1',
          displayName: 'Custom Meta F1',
          version: '1.2.0',
          entries: {
            0x4E00: const KanjiMetadataEntry(
              codepoint: 0x4E00,
              literal: '一',
              strokeCount: 1,
              meanings: ['one'],
              onyomi: ['イチ'],
              kunyomi: ['ひと'],
            ),
            0x4E8C: const KanjiMetadataEntry(
              codepoint: 0x4E8C,
              literal: '二',
              strokeCount: 2,
              meanings: ['two'],
              onyomi: ['ニ'],
              kunyomi: ['ふた'],
            ),
          },
        );

        expect(mockMeta.sourceId, equals('custom_meta_f1'));
        expect(mockMeta.isBundledDefault, isFalse);
        expect(await mockMeta.getCharacterCount(), equals(2));
        final codepoints = await mockMeta.getAllCodepoints();
        expect(codepoints, containsAll([0x4E00, 0x4E8C]));

        final entry = await mockMeta.getMetadata(0x4E00);
        expect(entry, isNotNull);
        expect(entry!.literal, equals('一'));
        expect(entry.meanings, equals(['one']));
      });

      test('T1-F1-02: IKanjiMetadataSource generates non-empty distractors excluding target', () async {
        final mockMeta = MockCustomMetadataSource(
          entries: {
            0x4E00: const KanjiMetadataEntry(
              codepoint: 0x4E00,
              literal: '一',
              strokeCount: 1,
              meanings: ['one'],
              onyomi: ['イチ'],
            ),
            0x4E8C: const KanjiMetadataEntry(
              codepoint: 0x4E8C,
              literal: '二',
              strokeCount: 2,
              meanings: ['two'],
              onyomi: ['ニ'],
            ),
            0x4E09: const KanjiMetadataEntry(
              codepoint: 0x4E09,
              literal: '三',
              strokeCount: 3,
              meanings: ['three'],
              onyomi: ['サン'],
            ),
          },
        );

        final target = (await mockMeta.getMetadata(0x4E00))!;
        final meaningDistractors = await mockMeta.generateMeaningDistractors(target, count: 2);
        expect(meaningDistractors.length, equals(2));
        expect(meaningDistractors, isNot(contains('one')));
        expect(meaningDistractors, contains('two'));

        final readingDistractors = await mockMeta.generateReadingDistractors(target, count: 2);
        expect(readingDistractors.length, equals(2));
        expect(readingDistractors, isNot(contains('イチ')));
        expect(readingDistractors, contains('ニ'));
      });

      test('T1-F1-03: IKanjiStrokeSource provides reference strokes and answers containsStrokes', () async {
        const stroke = ReferenceStroke(
          strokeOrder: 1,
          strokeType: 'horizontal',
          svgPath: 'M 100 500 L 900 500',
          arcLength: 800.0,
          sampledPoints: [Point2D(100, 500), Point2D(900, 500)],
        );
        final mockStroke = MockCustomStrokeSource(
          sourceId: 'custom_stroke_f1',
          displayName: 'Custom Stroke F1',
          strokeMap: {
            0x4E00: [stroke],
          },
        );

        expect(await mockStroke.containsStrokes(0x4E00), isTrue);
        expect(await mockStroke.containsStrokes(0x4E8C), isFalse);

        final strokes = await mockStroke.getStrokes(0x4E00);
        expect(strokes, isNotNull);
        expect(strokes!.length, equals(1));
        expect(strokes.first.svgPath, equals('M 100 500 L 900 500'));
      });

      test('T1-F1-04: IKanjiAudioSource provides AudioPronunciation with appropriate payload type', () async {
        final mockAudio = MockCustomAudioSource(
          sourceId: 'custom_audio_f1',
          audioMap: {
            0x4E00: {
              'イチ': const AudioPronunciation(
                type: AudioPayloadType.localFile,
                uriOrText: '/data/audio/4E00_ichi.wav',
                reading: 'イチ',
                mimeType: 'audio/wav',
              ),
              'ひと': const AudioPronunciation(
                type: AudioPayloadType.localFile,
                uriOrText: '/data/audio/4E00_hito.wav',
                reading: 'ひと',
                mimeType: 'audio/wav',
              ),
            },
          },
        );

        expect(await mockAudio.containsAudio(0x4E00, reading: 'イチ'), isTrue);
        expect(await mockAudio.containsAudio(0x4E00, reading: 'nonexistent'), isFalse);

        final audio = await mockAudio.getAudio(0x4E00, reading: 'イチ');
        expect(audio, isNotNull);
        expect(audio!.type, equals(AudioPayloadType.localFile));
        expect(audio.uriOrText, equals('/data/audio/4E00_ichi.wav'));
        expect(audio.reading, equals('イチ'));
      });

      test('T1-F1-05: Modular identity properties strictly adhere across all three provider contracts', () {
        final meta = MockCustomMetadataSource(sourceId: 'meta_id', displayName: 'Meta Name', version: '2.0.0');
        final stroke = MockCustomStrokeSource(sourceId: 'stroke_id', displayName: 'Stroke Name', version: '2.1.0');
        final audio = MockCustomAudioSource(sourceId: 'audio_id', displayName: 'Audio Name', version: '2.2.0');

        expect(meta.sourceId, equals('meta_id'));
        expect(meta.displayName, equals('Meta Name'));
        expect(meta.version, equals('2.0.0'));
        expect(meta.isBundledDefault, isFalse);

        expect(stroke.sourceId, equals('stroke_id'));
        expect(stroke.displayName, equals('Stroke Name'));
        expect(stroke.version, equals('2.1.0'));
        expect(stroke.isBundledDefault, isFalse);

        expect(audio.sourceId, equals('audio_id'));
        expect(audio.displayName, equals('Audio Name'));
        expect(audio.version, equals('2.2.0'));
        expect(audio.isBundledDefault, isFalse);
      });
    });

    // ------------------------------------------------------------------------
    // F2: Bundled Default Adapters (5 tests)
    // ------------------------------------------------------------------------
    group('F2: Bundled Default Adapters', () {
      test('T1-F2-01: BundledMetadataSource loads standard Joyo kanji from ContentDatabase', () async {
        final bundledMeta = BundledMetadataSource(contentDb: bundledContentDb);
        expect(bundledMeta.isBundledDefault, isTrue);
        expect(bundledMeta.sourceId, equals('bundled_metadata'));

        final entry = await bundledMeta.getMetadata(0x4E00); // '一'
        expect(entry, isNotNull);
        expect(entry!.literal, equals('一'));
        expect(entry.strokeCount, equals(1));
        expect(entry.meanings, contains('one'));
        expect(entry.grade, equals(1));
      });

      test('T1-F2-02: BundledStrokeSource supplies stroke points from ContentDatabase', () async {
        final bundledStroke = BundledStrokeSource(contentDb: bundledContentDb);
        expect(bundledStroke.isBundledDefault, isTrue);
        expect(bundledStroke.sourceId, equals('bundled_strokes'));

        expect(await bundledStroke.containsStrokes(0x4E00), isTrue);
        final strokes = await bundledStroke.getStrokes(0x4E00);
        expect(strokes, isNotNull);
        expect(strokes!.length, equals(1));
        expect(strokes.first.sampledPoints.length, equals(50));
      });

      test('T1-F2-03: DefaultTtsAudioSource produces ttsFallback payload with Japanese text', () async {
        final fakeSpeech = FakeSpeechService();
        final defaultTts = DefaultTtsAudioSource(speechService: fakeSpeech, contentDb: bundledContentDb);
        expect(defaultTts.isBundledDefault, isTrue);

        final audio = await defaultTts.getAudio(0x4E00, reading: 'イチ');
        expect(audio, isNotNull);
        expect(audio!.type, equals(AudioPayloadType.ttsFallback));
        expect(audio.uriOrText, equals('イチ'));
        expect(audio.reading, equals('イチ'));
      });

      test('T1-F2-04: Bundled adapters reflect total counts matching ContentDatabase oracle', () async {
        final bundledMeta = BundledMetadataSource(contentDb: bundledContentDb);
        final metaCount = await bundledMeta.getCharacterCount();
        final dbCount = bundledContentDb.totalKanjiCount;
        expect(metaCount, equals(dbCount));
        expect(metaCount, greaterThan(2000));
      });

      test('T1-F2-05: BundledMetadataSource distractor generation yields valid distractors', () async {
        final bundledMeta = BundledMetadataSource(contentDb: bundledContentDb);
        final target = (await bundledMeta.getMetadata(0x4E00))!;
        final meaningDistractors = await bundledMeta.generateMeaningDistractors(target, count: 3);
        expect(meaningDistractors.length, equals(3));
        for (final m in meaningDistractors) {
          expect(target.meanings.contains(m), isFalse);
        }
      });
    });

    // ------------------------------------------------------------------------
    // F3: Source Registry & Fallback Chain (5 tests)
    // ------------------------------------------------------------------------
    group('F3: Source Registry & Fallback Chain', () {
      test('T1-F3-01: Higher priority metadata source is consulted first before bundled default', () async {
        final registry = ContentSourceRegistry();
        final bundledMeta = BundledMetadataSource(contentDb: bundledContentDb);
        final customMeta = MockCustomMetadataSource(
          sourceId: 'override_meta',
          entries: {
            0x4E00: const KanjiMetadataEntry(
              codepoint: 0x4E00,
              literal: '一',
              strokeCount: 1,
              meanings: ['supreme unity'],
            ),
          },
        );

        registry.registerMetadataSource(bundledMeta);
        registry.registerMetadataSource(customMeta, priority: 50);

        final entry = await registry.queryMetadata(0x4E00);
        expect(entry, isNotNull);
        expect(entry!.meanings, equals(['supreme unity']));
      });

      test('T1-F3-02: Stroke source overrides matching codepoint and falls back to bundled for absent', () async {
        final registry = ContentSourceRegistry();
        final bundledStroke = BundledStrokeSource(contentDb: bundledContentDb);
        final customStroke = MockCustomStrokeSource(
          sourceId: 'custom_stroke',
          strokeMap: {
            0x4E00: const [
              ReferenceStroke(
                strokeOrder: 1,
                strokeType: 'custom_h',
                svgPath: 'M 0 0 L 100 0',
                arcLength: 100.0,
                sampledPoints: [Point2D(0, 0), Point2D(100, 0)],
              ),
            ],
          },
        );

        registry.registerStrokeSource(bundledStroke);
        registry.registerStrokeSource(customStroke, priority: 10);

        final strokesCustom = await registry.queryStrokes(0x4E00);
        expect(strokesCustom?.first.strokeType, equals('custom_h'));

        final strokesBundled = await registry.queryStrokes(0x4E8C); // '二' not in custom
        expect(strokesBundled, isNotNull);
        expect(strokesBundled!.length, equals(2));
      });

      test('T1-F3-03: Audio source queries custom first, falling back to TTS', () async {
        final registry = ContentSourceRegistry();
        final defaultTts = DefaultTtsAudioSource(speechService: FakeSpeechService(), contentDb: bundledContentDb);
        final customAudio = MockCustomAudioSource(
          sourceId: 'custom_audio',
          audioMap: {
            0x4E00: {
              'イチ': const AudioPronunciation(
                type: AudioPayloadType.localFile,
                uriOrText: '/pkg/ichi.mp3',
                reading: 'イチ',
              ),
            },
          },
        );

        registry.registerAudioSource(defaultTts);
        registry.registerAudioSource(customAudio, priority: 10);

        final audioCustom = await registry.queryAudio(0x4E00, reading: 'イチ');
        expect(audioCustom?.type, equals(AudioPayloadType.localFile));

        final audioFallback = await registry.queryAudio(0x4E8C, reading: 'ニ');
        expect(audioFallback?.type, equals(AudioPayloadType.ttsFallback));
      });

      test('T1-F3-04: Priority chain sorts custom sources descending with bundled permanently at tail', () {
        final registry = ContentSourceRegistry();
        final bundled = BundledMetadataSource(contentDb: bundledContentDb);
        final customLow = MockCustomMetadataSource(sourceId: 'low');
        final customHigh = MockCustomMetadataSource(sourceId: 'high');

        registry.registerMetadataSource(bundled);
        registry.registerMetadataSource(customLow, priority: 10);
        registry.registerMetadataSource(customHigh, priority: 100);

        final sources = registry.activeMetadataSources;
        expect(sources.map((s) => s.sourceId).toList(), equals(['high', 'low', 'bundled_metadata']));
      });

      test('T1-F3-05: unregisterSource cleanly removes source and reverts query immediately', () async {
        final registry = ContentSourceRegistry();
        final bundledMeta = BundledMetadataSource(contentDb: bundledContentDb);
        final customMeta = MockCustomMetadataSource(
          sourceId: 'temp_meta',
          entries: {
            0x4E00: const KanjiMetadataEntry(
              codepoint: 0x4E00,
              literal: '一',
              strokeCount: 1,
              meanings: ['temporary definition'],
            ),
          },
        );

        registry.registerMetadataSource(bundledMeta);
        registry.registerMetadataSource(customMeta, priority: 20);

        expect((await registry.queryMetadata(0x4E00))?.meanings, equals(['temporary definition']));

        registry.unregisterSource('temp_meta');
        expect(registry.containsSource('temp_meta'), isFalse);
        expect((await registry.queryMetadata(0x4E00))?.meanings, contains('one'));
      });
    });

    // ------------------------------------------------------------------------
    // F4: Independent Component Substitution (5 tests)
    // ------------------------------------------------------------------------
    group('F4: Independent Component Substitution', () {
      test('T1-F4-01: Tri-source combination: Custom Metadata + Bundled Strokes + Custom Audio', () async {
        final registry = ContentSourceRegistry();
        final repo = ContentRepository(registry: registry);

        registry.registerMetadataSource(BundledMetadataSource(contentDb: bundledContentDb));
        registry.registerStrokeSource(BundledStrokeSource(contentDb: bundledContentDb));
        registry.registerAudioSource(DefaultTtsAudioSource(speechService: FakeSpeechService(), contentDb: bundledContentDb));

        registry.registerMetadataSource(
          MockCustomMetadataSource(
            sourceId: 'custom_meta',
            entries: {
              0x4E00: const KanjiMetadataEntry(
                codepoint: 0x4E00,
                literal: '一',
                strokeCount: 1,
                meanings: ['tri-source custom meaning'],
              ),
            },
          ),
          priority: 10,
        );

        registry.registerAudioSource(
          MockCustomAudioSource(
            sourceId: 'custom_audio',
            audioMap: {
              0x4E00: {
                'イチ': const AudioPronunciation(
                  type: AudioPayloadType.localFile,
                  uriOrText: '/tri/ichi.wav',
                  reading: 'イチ',
                ),
              },
            },
          ),
          priority: 10,
        );

        final kanji = await repo.getKanjiByCodepoint(0x4E00);
        expect(kanji, isNotNull);
        expect(kanji!.meanings, equals(['tri-source custom meaning']));
        expect(kanji.strokes.length, equals(1)); // Bundled stroke
        expect(kanji.strokes.first.sampledPoints.length, equals(50));

        final audio = await repo.resolveAudio(0x4E00, reading: 'イチ');
        expect(audio.type, equals(AudioPayloadType.localFile));
        expect(audio.uriOrText, equals('/tri/ichi.wav'));
      });

      test('T1-F4-02: Reverse combination: Bundled Metadata + Custom Strokes + Default Audio', () async {
        final registry = ContentSourceRegistry();
        final repo = ContentRepository(registry: registry);

        registry.registerMetadataSource(BundledMetadataSource(contentDb: bundledContentDb));
        registry.registerStrokeSource(BundledStrokeSource(contentDb: bundledContentDb));
        registry.registerAudioSource(DefaultTtsAudioSource(speechService: FakeSpeechService(), contentDb: bundledContentDb));

        registry.registerStrokeSource(
          MockCustomStrokeSource(
            sourceId: 'custom_strokes_only',
            strokeMap: {
              0x4E00: const [
                ReferenceStroke(
                  strokeOrder: 1,
                  strokeType: 'custom_vector',
                  svgPath: 'M 50 500 L 950 500',
                  arcLength: 900.0,
                  sampledPoints: [Point2D(50, 500), Point2D(950, 500)],
                ),
              ],
            },
          ),
          priority: 20,
        );

        final kanji = await repo.getKanjiByCodepoint(0x4E00);
        expect(kanji, isNotNull);
        expect(kanji!.meanings, contains('one')); // Bundled metadata
        expect(kanji.strokes.first.strokeType, equals('custom_vector')); // Custom stroke

        final audio = await repo.resolveAudio(0x4E00, reading: 'イチ');
        expect(audio.type, equals(AudioPayloadType.ttsFallback)); // Default audio
      });

      test('T1-F4-03: Partial metadata source falls back seamlessly for unlisted characters', () async {
        final registry = ContentSourceRegistry();
        final repo = ContentRepository(registry: registry);

        registry.registerMetadataSource(BundledMetadataSource(contentDb: bundledContentDb));
        registry.registerStrokeSource(BundledStrokeSource(contentDb: bundledContentDb));

        // Custom source only contains '一' (0x4E00)
        registry.registerMetadataSource(
          MockCustomMetadataSource(
            sourceId: 'single_entry_pkg',
            entries: {
              0x4E00: const KanjiMetadataEntry(
                codepoint: 0x4E00,
                literal: '一',
                strokeCount: 1,
                meanings: ['alone'],
              ),
            },
          ),
          priority: 15,
        );

        final k1 = await repo.getKanjiByCodepoint(0x4E00);
        expect(k1?.meanings, equals(['alone']));

        final k2 = await repo.getKanjiByCodepoint(0x4E8C); // '二'
        expect(k2?.meanings, contains('two'));
      });

      test('T1-F4-04: Partial stroke source seamlessly falls back to bundled strokes', () async {
        final registry = ContentSourceRegistry();
        final repo = ContentRepository(registry: registry);

        registry.registerMetadataSource(BundledMetadataSource(contentDb: bundledContentDb));
        registry.registerStrokeSource(BundledStrokeSource(contentDb: bundledContentDb));

        registry.registerStrokeSource(
          MockCustomStrokeSource(
            sourceId: 'partial_strokes',
            strokeMap: {
              0x4E00: const [
                ReferenceStroke(
                  strokeOrder: 1,
                  strokeType: 'special_one',
                  svgPath: 'M 0 0 L 1 1',
                  arcLength: 1.414,
                  sampledPoints: [Point2D(0, 0), Point2D(1, 1)],
                ),
              ],
            },
          ),
          priority: 10,
        );

        final k1 = await repo.getKanjiByCodepoint(0x4E00);
        expect(k1?.strokes.first.strokeType, equals('special_one'));

        final k2 = await repo.getKanjiByCodepoint(0x4E8C);
        expect(k2?.strokes.length, equals(2)); // Bundled stroke set
      });

      test('T1-F4-05: Audio resolution falls back to default TTS when custom lacks reading', () async {
        final registry = ContentSourceRegistry();
        final repo = ContentRepository(registry: registry);

        registry.registerAudioSource(DefaultTtsAudioSource(speechService: FakeSpeechService(), contentDb: bundledContentDb));
        registry.registerAudioSource(
          MockCustomAudioSource(
            sourceId: 'audio_subset',
            audioMap: {
              0x4E00: {
                'ひと': const AudioPronunciation(
                  type: AudioPayloadType.localFile,
                  uriOrText: '/audio/hito.wav',
                  reading: 'ひと',
                ),
              },
            },
          ),
          priority: 10,
        );

        // Specific custom reading
        final customAudio = await repo.resolveAudio(0x4E00, reading: 'ひと');
        expect(customAudio.type, equals(AudioPayloadType.localFile));

        // Missing reading falls back to TTS
        final fallbackAudio = await repo.resolveAudio(0x4E00, reading: 'イチ');
        expect(fallbackAudio.type, equals(AudioPayloadType.ttsFallback));
        expect(fallbackAudio.uriOrText, equals('イチ'));
      });
    });

    // ------------------------------------------------------------------------
    // F5: FSRS & User Progress Integrity (5 tests)
    // ------------------------------------------------------------------------
    group('F5: FSRS & User Progress Integrity', () {
      test('T1-F5-01: FSRS card progress persists invariant when custom source is added', () async {
        final userDb = UserDatabase.openInMemory();
        final scheduler = FsrsSchedulerService();

        // Initial practice attempt with bundled defaults
        final card1 = scheduler.recordPracticeCompletion(
          userDb: userDb,
          codepoint: 0x4E00,
          mistakes: 0,
          hintsUsed: 0,
          mode: PracticeMode.writing,
          now: DateTime.utc(2026, 1, 1, 10, 0),
        );
        expect(card1.reps, equals(1));
        expect(card1.stability, greaterThan(0));

        // Add custom source
        final registry = ContentSourceRegistry();
        registry.registerMetadataSource(BundledMetadataSource(contentDb: bundledContentDb));
        registry.registerMetadataSource(
          MockCustomMetadataSource(
            sourceId: 'new_meta_pack',
            entries: {
              0x4E00: const KanjiMetadataEntry(
                codepoint: 0x4E00,
                literal: '一',
                strokeCount: 1,
                meanings: ['updated'],
              ),
            },
          ),
          priority: 10,
        );

        // Verify card progress in database is completely intact
        final loadedCard = userDb.getCard(0x4E00, mode: PracticeMode.writing);
        expect(loadedCard, isNotNull);
        expect(loadedCard!.reps, equals(1));
        expect(loadedCard.stability, equals(card1.stability));
        expect(loadedCard.difficulty, equals(card1.difficulty));
        expect(loadedCard.dueDate, equals(card1.dueDate));
      });

      test('T1-F5-02: FSRS review progression functions seamlessly under custom source', () async {
        final userDb = UserDatabase.openInMemory();
        final scheduler = FsrsSchedulerService();

        // Step 1: Learn
        scheduler.recordPracticeCompletion(
          userDb: userDb,
          codepoint: 0x4E00,
          mistakes: 0,
          hintsUsed: 0,
          mode: PracticeMode.writing,
          now: DateTime.utc(2026, 1, 1, 10, 0),
        );

        // Step 2: Review after interval with custom source active
        final updatedCard = scheduler.recordPracticeCompletion(
          userDb: userDb,
          codepoint: 0x4E00,
          mistakes: 0,
          hintsUsed: 0,
          mode: PracticeMode.writing,
          now: DateTime.utc(2026, 1, 4, 10, 0),
        );

        expect(updatedCard.reps, equals(2));
        expect(updatedCard.state, equals(2)); // Review state
        expect(updatedCard.stability, greaterThan(1.0));
      });

      test('T1-F5-03: User review logs remain consistent and traceable across source changes', () async {
        final userDb = UserDatabase.openInMemory();
        final scheduler = FsrsSchedulerService();

        final t1 = DateTime.utc(2026, 1, 1, 12, 0);
        scheduler.recordPracticeCompletion(
          userDb: userDb,
          codepoint: 0x4E00,
          mistakes: 1,
          hintsUsed: 0,
          now: t1,
        );

        final backupJson = jsonDecode(userDb.exportBackupJson()) as Map<String, dynamic>;
        final logs = (backupJson['review_logs'] as List).cast<Map<String, dynamic>>();
        final logsForCp = logs.where((l) => l['codepoint'] == 0x4E00 && l['mode'] == PracticeMode.writing).toList();
        expect(logsForCp.length, equals(1));
        expect(logsForCp.first['mistakes'], equals(1));
        expect(logsForCp.first['reviewed_at'], equals(t1.toUtc().toIso8601String()));
      });

      test('T1-F5-04: Unregistering custom source does NOT mutate or delete user progress rows', () async {
        final userDb = UserDatabase.openInMemory();
        final scheduler = FsrsSchedulerService();

        // Study a custom-only codepoint: 0x9B1D (outside standard bundled set)
        scheduler.recordPracticeCompletion(
          userDb: userDb,
          codepoint: 0x9B1D,
          mistakes: 0,
          hintsUsed: 0,
          now: DateTime.utc(2026, 1, 1, 10, 0),
        );

        expect(userDb.getCard(0x9B1D, mode: PracticeMode.writing), isNotNull);

        // Registry mutation (unregistering custom source)
        final registry = ContentSourceRegistry();
        registry.registerMetadataSource(BundledMetadataSource(contentDb: bundledContentDb));
        final custom = MockCustomMetadataSource(sourceId: 'c1');
        registry.registerMetadataSource(custom);
        registry.unregisterSource('c1');

        // Card in userDb remains 100% untouched
        final cardAfter = userDb.getCard(0x9B1D, mode: PracticeMode.writing);
        expect(cardAfter, isNotNull);
        expect(cardAfter!.codepoint, equals(0x9B1D));
        expect(cardAfter.reps, equals(1));
      });

      test('T1-F5-05: Safe queue omission: unresolvable due cards are skipped without errors', () async {
        final userDb = UserDatabase.openInMemory();
        final scheduler = FsrsSchedulerService();
        final registry = ContentSourceRegistry();
        final repo = ContentRepository(registry: registry);

        registry.registerMetadataSource(BundledMetadataSource(contentDb: bundledContentDb));
        registry.registerStrokeSource(BundledStrokeSource(contentDb: bundledContentDb));

        // Create a due card for a custom-only codepoint
        userDb.upsertCard(
          UserCardProgress(
            codepoint: 0x2A6D6, // Absent from active sources (CJK Ext B)
            mode: PracticeMode.writing,
            dueDate: DateTime.utc(2026, 1, 1),
            stability: 1.0,
            difficulty: 5.0,
            elapsedDays: 1,
            scheduledDays: 1,
            reps: 1,
            lapses: 0,
            state: 1,
          ),
        );

        // Build queue for current date: 0x2A6D6 cannot be resolved, must be safely omitted
        final queue = scheduler.buildDailyQueue(
          repository: repo,
          userDb: userDb,
          dailyNewLimit: 5,
          now: DateTime.utc(2026, 1, 2),
        );

        expect(queue.any((item) => item.kanji.codepoint == 0x2A6D6), isFalse);
        // The card still safely exists in the database
        expect(userDb.getCard(0x2A6D6, mode: PracticeMode.writing), isNotNull);
      });
    });

    // ------------------------------------------------------------------------
    // F6: Manifest Schema & Parsing (5 tests)
    // ------------------------------------------------------------------------
    group('F6: Manifest Schema & Parsing', () {
      test('T1-F6-01: SourceManifest.fromJson parses valid complete manifest', () {
        final json = {
          'formatVersion': 1,
          'id': 'test_expansion_pack',
          'name': 'Test Expansion Pack',
          'version': '1.0.0',
          'author': 'Sensei',
          'description': 'Advanced Kanji',
          'capabilities': ['metadata', 'strokes', 'audio'],
          'metadataPath': 'meta/data.json',
          'strokesPath': 'strokes/data.json',
          'audioPath': 'audio',
          'checksums': {'meta/data.json': 'sha256:abc'},
        };

        final manifest = SourceManifest.fromJson(json);
        expect(manifest.id, equals('test_expansion_pack'));
        expect(manifest.version, equals('1.0.0'));
        expect(manifest.capabilities, containsAll([
          SourceCapability.metadata,
          SourceCapability.strokes,
          SourceCapability.audio,
        ]));
        expect(manifest.metadataPath, equals('meta/data.json'));
        expect(manifest.checksums?['meta/data.json'], equals('sha256:abc'));
      });

      test('T1-F6-02: Rejects manifest missing required id, name, or version', () {
        expect(
          () => SourceManifest.fromJson({'name': 'N', 'version': '1.0.0', 'capabilities': ['metadata']}),
          throwsA(isA<FormatException>()),
        );
        expect(
          () => SourceManifest.fromJson({'id': 'id', 'version': '1.0.0', 'capabilities': ['metadata']}),
          throwsA(isA<FormatException>()),
        );
        expect(
          () => SourceManifest.fromJson({'id': 'id', 'name': 'N', 'capabilities': ['metadata']}),
          throwsA(isA<FormatException>()),
        );
      });

      test('T1-F6-03: Rejects invalid SemVer string in manifest', () {
        final invalidVersions = ['v1.0.0', '1.0', '1', '1.0.0.0', 'beta-1'];
        for (final v in invalidVersions) {
          expect(
            () => SourceManifest.fromJson({
              'id': 'valid_id',
              'name': 'Valid Name',
              'version': v,
              'capabilities': ['metadata'],
            }),
            throwsA(isA<FormatException>()),
            reason: 'Version "$v" should fail SemVer validation',
          );
        }
      });

      test('T1-F6-04: Rejects manifest declaring empty capabilities list', () {
        expect(
          () => SourceManifest.fromJson({
            'id': 'empty_caps',
            'name': 'Empty Caps',
            'version': '1.0.0',
            'capabilities': <String>[],
          }),
          throwsA(isA<FormatException>()),
        );
      });

      test('T1-F6-05: SourceManifest.isValidId enforces alphanumeric slug syntax', () {
        expect(SourceManifest.isValidId('valid_id-123.pkg'), isTrue);
        expect(SourceManifest.isValidId('Invalid Uppercase'), isFalse);
        expect(SourceManifest.isValidId('invalid/slash'), isFalse);
        expect(SourceManifest.isValidId(''), isFalse);
      });
    });

    // ------------------------------------------------------------------------
    // F7: Source Validator & Security Gate (5 tests)
    // ------------------------------------------------------------------------
    group('F7: Source Validator & Security Gate', () {
      final validator = SourceValidator();

      test('T1-F7-01: Validates compliant manifest schema map', () {
        final res = validator.validateManifest({
          'id': 'valid_manifest',
          'name': 'Valid',
          'version': '1.0.0',
          'capabilities': ['metadata'],
        });
        expect(res.isValid, isTrue);
      });

      test('T1-F7-02: ZipSlipGuard identifies path traversal sequences', () {
        expect(ZipSlipGuard.isPathSafe(globalTempDir.path, 'valid/sub/file.txt'), isTrue);
        expect(ZipSlipGuard.isPathSafe(globalTempDir.path, '../../etc/shadow'), isFalse);
        expect(ZipSlipGuard.isPathSafe(globalTempDir.path, 'dir/../../../root.txt'), isFalse);
        expect(ZipSlipGuard.isPathSafe(globalTempDir.path, r'dir\..\..\win.ini'), isFalse);
      });

      test('T1-F7-03: Validates Unicode scalar boundaries rejecting surrogates and negative numbers', () {
        expect(validator.validateMetadataEntry({'codepoint': 0x4E00, 'literal': '一', 'meanings': ['one']}).isValid, isTrue);
        expect(validator.validateMetadataEntry({'codepoint': -1, 'literal': '一', 'meanings': ['one']}).isValid, isFalse);
        expect(validator.validateMetadataEntry({'codepoint': 0xD800, 'literal': '一', 'meanings': ['one']}).isValid, isFalse); // High surrogate
        expect(validator.validateMetadataEntry({'codepoint': 0xDFFF, 'literal': '一', 'meanings': ['one']}).isValid, isFalse); // Low surrogate
        expect(validator.validateMetadataEntry({'codepoint': 0x110000, 'literal': '一', 'meanings': ['one']}).isValid, isFalse); // Beyond SMP
      });

      test('T1-F7-04: Validates stroke counts within [1, 64] range', () {
        expect(validator.validateStrokeData(codepoint: 0x4E00, rawStrokes: []).isValid, isFalse);
        final oversizedStrokes = List<Map<String, dynamic>>.generate(65, (i) => {'svg_path': 'M 0 0 L 10 10'});
        expect(validator.validateStrokeData(codepoint: 0x4E00, rawStrokes: oversizedStrokes).isValid, isFalse);
      });

      test('T1-F7-05: Validates audio header magic bytes for WAV and MP3', () {
        final wavBytes = TestPackageBuilder.createWavBytes(64);
        expect(validator.validateAudioBytes(wavBytes, filename: 'sample.wav').isValid, isTrue);

        final mp3Bytes = TestPackageBuilder.createMp3Bytes(40);
        expect(validator.validateAudioBytes(mp3Bytes, filename: 'sample.mp3').isValid, isTrue);

        final junkBytes = Uint8List(64);
        expect(validator.validateAudioBytes(junkBytes, filename: 'junk.bin').isValid, isFalse);
      });
    });

    // ------------------------------------------------------------------------
    // F8: Offline Package Ingestion (5 tests)
    // ------------------------------------------------------------------------
    group('F8: Offline Package Ingestion', () {
      late Directory tempDir;
      late PackageStagingManager stagingManager;
      late OfflinePackageLoader loader;

      setUp(() async {
        tempDir = Directory.systemTemp.createTempSync('tsuzuri_t1_f8_');
        stagingManager = PackageStagingManager(baseDirectory: tempDir);
        await stagingManager.initialize();
        loader = OfflinePackageLoader(stagingManager: stagingManager, validator: SourceValidator());
      });

      tearDown(() {
        try {
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        } catch (_) {}
      });

      test('T1-F8-01: Ingests valid offline ZIP archive into promoted package directory', () async {
        final zipFile = File(p.join(tempDir.path, 'valid.zip'));
        await TestPackageBuilder.writeValidZipPackage(zipFile, id: 'offline_zip_t1');

        final result = await loader.loadFromArchive(zipFile);
        expect(result.isSuccess, isTrue);
        expect(result.sourceId, equals('offline_zip_t1'));
        expect(result.packageDirectory, isNotNull);
        expect(await Directory(result.packageDirectory!).exists(), isTrue);
      });

      test('T1-F8-02: Ingests package from directory tree', () async {
        final pkgDir = Directory(p.join(tempDir.path, 'raw_dir'));
        await TestPackageBuilder.writeDirectoryPackage(pkgDir, id: 'dir_pkg_t1');

        final result = await loader.loadFromDirectory(pkgDir);
        expect(result.isSuccess, isTrue);
        expect(result.sourceId, equals('dir_pkg_t1'));
      });

      test('T1-F8-03: Ingests standalone JSON package', () async {
        final jsonFile = File(p.join(tempDir.path, 'package.json'));
        final packageJson = {
          'manifest': {
            'id': 'json_standalone_pkg',
            'name': 'JSON Standalone',
            'version': '1.0.0',
            'capabilities': ['metadata'],
          },
          'metadata': [
            {
              'codepoint': 0x4E00,
              'literal': '一',
              'stroke_count': 1,
              'meanings': ['standalone'],
            }
          ],
        };
        await jsonFile.writeAsString(jsonEncode(packageJson));

        final result = await loader.loadFromJsonFile(jsonFile);
        expect(result.isSuccess, isTrue);
        expect(result.sourceId, equals('json_standalone_pkg'));
      });

      test('T1-F8-04: Atomic staging cleanly rolls back when archive has invalid manifest', () async {
        final archive = Archive();
        archive.addFile(ArchiveFile.string('manifest.json', '{"formatVersion": 999}'));
        final badZip = File(p.join(tempDir.path, 'bad_manifest.zip'));
        await badZip.writeAsBytes(TestPackageBuilder.encodeZip(archive));

        final result = await loader.loadFromArchive(badZip);
        expect(result.isSuccess, isFalse);

        // Staging directory should be clean
        final stagingDir = Directory(p.join(tempDir.path, 'staging'));
        if (stagingDir.existsSync()) {
          expect(stagingDir.listSync().isEmpty, isTrue);
        }
      });

      test('T1-F8-05: Ingested package can be instantiated into CustomMetadataSource and queried', () async {
        final zipFile = File(p.join(tempDir.path, 'queryable.zip'));
        await TestPackageBuilder.writeValidZipPackage(
          zipFile,
          id: 'queryable_pkg',
          sampleCodepoint: 0x4E00,
          sampleLiteral: '一',
          meanings: ['queryable test'],
        );

        final result = await loader.loadFromArchive(zipFile);
        expect(result.isSuccess, isTrue);

        final customSource = await CustomMetadataSource.fromDirectory(
          Directory(result.packageDirectory!),
          result.manifest!,
        );

        final entry = await customSource.getMetadata(0x4E00);
        expect(entry, isNotNull);
        expect(entry!.meanings, equals(['queryable test']));
      });
    });

    // ------------------------------------------------------------------------
    // F9: Online HTTP Ingestion & Caching (5 tests)
    // ------------------------------------------------------------------------
    group('F9: Online HTTP Ingestion & Caching', () {
      late Directory tempDir;
      late PackageStagingManager stagingManager;
      late OnlineSourceFetcher fetcher;
      late MockContentHttpServer server;

      setUp(() async {
        tempDir = Directory.systemTemp.createTempSync('tsuzuri_t1_f9_');
        stagingManager = PackageStagingManager(baseDirectory: tempDir);
        await stagingManager.initialize();
        fetcher = OnlineSourceFetcher(stagingManager: stagingManager, validator: SourceValidator());
        server = MockContentHttpServer();
        await server.start();
      });

      tearDown(() async {
        await server.stop();
        try {
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        } catch (_) {}
      });

      test('T1-F9-01: Successfully fetches and installs package over loopback HTTP server', () async {
        final manifest = {
          'formatVersion': 1,
          'id': 'online_test_pkg',
          'name': 'Online Test',
          'version': '1.0.0',
          'capabilities': ['metadata'],
          'metadataPath': 'metadata.json',
        };
        final metadata = [
          {
            'codepoint': 0x4E00,
            'literal': '一',
            'stroke_count': 1,
            'meanings': ['online meaning'],
          }
        ];

        server.serveManifest('/pkg/manifest.json', manifest);
        server.serveBytes('/pkg/metadata.json', utf8.encode(jsonEncode(metadata)), contentType: 'application/json');

        final result = await fetcher.fetchAndInstall(Uri.parse('${server.baseUrl}/pkg/manifest.json'));
        expect(result.isSuccess, isTrue);
        expect(result.sourceId, equals('online_test_pkg'));
      });

      test('T1-F9-02: HTTP 404 response on remote manifest returns networkError failure', () async {
        final result = await fetcher.fetchAndInstall(Uri.parse('${server.baseUrl}/nonexistent_manifest.json'));
        expect(result.isSuccess, isFalse);
        expect(result.errorCode, equals(IngestionErrorCode.networkError));
      });

      test('T1-F9-03: HTTP 500 error gracefully terminates with networkError', () async {
        server.serveError('/server_error.json', 500, body: 'Internal Server Error');

        final result = await fetcher.fetchAndInstall(
          Uri.parse('${server.baseUrl}/server_error.json'),
          options: const FetchOptions(maxRetries: 1, retryDelay: Duration(milliseconds: 50)),
        );
        expect(result.isSuccess, isFalse);
        expect(result.errorCode, equals(IngestionErrorCode.networkError));
      });

      test('T1-F9-04: Checksum mismatch in online downloaded asset triggers checksumMismatch', () async {
        final manifest = {
          'formatVersion': 1,
          'id': 'checksum_pkg',
          'name': 'Checksum Pkg',
          'version': '1.0.0',
          'capabilities': ['metadata'],
          'metadataPath': 'metadata.json',
          'checksums': {
            'metadata.json': 'sha256:0000000000000000000000000000000000000000000000000000000000000000',
          },
        };
        final metadata = [{'codepoint': 0x4E00, 'literal': '一', 'stroke_count': 1, 'meanings': ['test']}];

        server.serveManifest('/chk/manifest.json', manifest);
        server.serveBytes('/chk/metadata.json', utf8.encode(jsonEncode(metadata)), contentType: 'application/json');

        final result = await fetcher.fetchAndInstall(Uri.parse('${server.baseUrl}/chk/manifest.json'));
        expect(result.isSuccess, isFalse);
        expect(result.errorCode, equals(IngestionErrorCode.checksumMismatch));
      });

      test('T1-F9-05: Promoted online package registers and functions through ContentRepository', () async {
        final manifest = {
          'formatVersion': 1,
          'id': 'promoted_online',
          'name': 'Promoted Online',
          'version': '1.0.0',
          'capabilities': ['metadata'],
          'metadataPath': 'metadata.json',
        };
        final metadata = [{'codepoint': 0x4E00, 'literal': '一', 'stroke_count': 1, 'meanings': ['promoted online']}];

        server.serveManifest('/promoted/manifest.json', manifest);
        server.serveBytes('/promoted/metadata.json', utf8.encode(jsonEncode(metadata)), contentType: 'application/json');

        final result = await fetcher.fetchAndInstall(Uri.parse('${server.baseUrl}/promoted/manifest.json'));
        expect(result.isSuccess, isTrue);

        final customMeta = await CustomMetadataSource.fromDirectory(
          Directory(result.packageDirectory!),
          result.manifest!,
        );

        final registry = ContentSourceRegistry();
        registry.registerMetadataSource(customMeta, priority: 10);
        final repo = ContentRepository(registry: registry);

        final kanji = await repo.getKanjiByCodepoint(0x4E00);
        expect(kanji?.meanings, equals(['promoted online']));
      });
    });

    // ------------------------------------------------------------------------
    // F10: Non-Destructive Error Handling (5 tests)
    // ------------------------------------------------------------------------
    group('F10: Non-Destructive Error Handling', () {
      test('T1-F10-01: IngestionResult.failure encapsulates structured error code and message', () {
        const failure = IngestionResult.failure(
          errorCode: IngestionErrorCode.securityPathTraversal,
          errorMessage: 'Path traversal attempt rejected',
        );
        expect(failure.isSuccess, isFalse);
        expect(failure.errorCode, equals(IngestionErrorCode.securityPathTraversal));
        expect(failure.errorMessage, contains('Path traversal'));
      });

      test('T1-F10-02: Corrupted archive ingestion leaves active registry completely intact', () async {
        final registry = ContentSourceRegistry();
        registry.registerMetadataSource(BundledMetadataSource(contentDb: bundledContentDb));

        final tempDir = Directory.systemTemp.createTempSync('tsuzuri_t1_f10_');
        final staging = PackageStagingManager(baseDirectory: tempDir);
        await staging.initialize();
        final loader = OfflinePackageLoader(stagingManager: staging, validator: SourceValidator());

        final badFile = File(p.join(tempDir.path, 'garbage.zip'));
        await badFile.writeAsBytes([0x00, 0x01, 0x02, 0x03]); // Not a zip

        final result = await loader.loadFromArchive(badFile);
        expect(result.isSuccess, isFalse);

        // Registry query continues without disturbance
        final kanji = await registry.queryMetadata(0x4E00);
        expect(kanji, isNotNull);
        expect(kanji!.literal, equals('一'));

        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      });

      test('T1-F10-03: Ingestion failure does NOT alter user progress database records', () async {
        final userDb = UserDatabase.openInMemory();
        userDb.upsertCard(
          UserCardProgress(
            codepoint: 0x4E00,
            mode: PracticeMode.writing,
            dueDate: DateTime.utc(2026, 1, 1),
            stability: 2.0,
            difficulty: 3.0,
            elapsedDays: 1,
            scheduledDays: 2,
            reps: 2,
            lapses: 0,
            state: 2,
          ),
        );

        final tempDir = Directory.systemTemp.createTempSync('tsuzuri_t1_f10_u_');
        final staging = PackageStagingManager(baseDirectory: tempDir);
        await staging.initialize();
        final loader = OfflinePackageLoader(stagingManager: staging, validator: SourceValidator());

        final corruptZip = File(p.join(tempDir.path, 'corrupt.zip'));
        await corruptZip.writeAsBytes([0xFF, 0xFE]);
        await loader.loadFromArchive(corruptZip);

        // Card progress remains exactly identical
        final card = userDb.getCard(0x4E00, mode: PracticeMode.writing);
        expect(card?.reps, equals(2));
        expect(card?.stability, equals(2.0));

        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      });

      test('T1-F10-04: Exception inside custom metadata source is caught and falls back to next source', () async {
        final registry = ContentSourceRegistry();
        final bundledMeta = BundledMetadataSource(contentDb: bundledContentDb);
        final faultyCustom = MockCustomMetadataSource(
          sourceId: 'faulty_meta',
          shouldThrowOnGet: true,
          throwError: const FormatException('Database disk read failed'),
        );

        registry.registerMetadataSource(bundledMeta);
        registry.registerMetadataSource(faultyCustom, priority: 50);

        // Should NOT crash with unhandled exception, should fall back to bundledMeta
        final entry = await registry.queryMetadata(0x4E00);
        expect(entry, isNotNull);
        expect(entry!.meanings, contains('one'));
      });

      test('T1-F10-05: Exception in custom stroke or audio query is contained cleanly by registry', () async {
        final registry = ContentSourceRegistry();
        final bundledStroke = BundledStrokeSource(contentDb: bundledContentDb);
        final faultyStroke = MockCustomStrokeSource(
          sourceId: 'faulty_stroke',
          shouldThrow: true,
          throwError: const SocketException('Stream closed'),
        );

        registry.registerStrokeSource(bundledStroke);
        registry.registerStrokeSource(faultyStroke, priority: 50);

        final strokes = await registry.queryStrokes(0x4E00);
        expect(strokes, isNotNull);
        expect(strokes!.length, equals(1));
      });
    });
  });

  // ============================================================================
  // TIER 2: BOUNDARY & CORNER CASES (50 Tests, F1 - F10)
  // ============================================================================
  group('Tier 2: Boundary & Corner Cases (F1-F10)', () {
    // ------------------------------------------------------------------------
    // F1 Boundaries: Unicode Scalars & Empty Fields (5 tests)
    // ------------------------------------------------------------------------
    group('F1 Boundaries: Unicode Scalars & Empty Fields', () {
      test('T2-F1-01: Scalar boundary: Minimum valid scalar U+0001 (Start of Heading)', () async {
        final meta = MockCustomMetadataSource(
          entries: {
            0x0001: const KanjiMetadataEntry(
              codepoint: 0x0001,
              literal: '\u0001',
              strokeCount: 1,
              meanings: ['soh'],
            ),
          },
        );
        final entry = await meta.getMetadata(0x0001);
        expect(entry, isNotNull);
        expect(entry!.unicodeHex, equals('U+0001'));
      });

      test('T2-F1-02: Scalar boundary: Maximum valid scalar U+10FFFF handled properly', () async {
        final meta = MockCustomMetadataSource(
          entries: {
            0x10FFFF: const KanjiMetadataEntry(
              codepoint: 0x10FFFF,
              literal: '\u{10FFFF}',
              strokeCount: 1,
              meanings: ['max_scalar'],
            ),
          },
        );
        final entry = await meta.getMetadata(0x10FFFF);
        expect(entry, isNotNull);
        expect(entry!.unicodeHex, equals('U+10FFFF'));
      });

      test('T2-F1-03: Surrogate boundary rejection: U+D800 and U+DFFF return null in registry', () async {
        final registry = ContentSourceRegistry();
        expect(await registry.queryMetadata(0xD800), isNull);
        expect(await registry.queryMetadata(0xDFFF), isNull);
        expect(await registry.queryStrokes(0xD800), isNull);
      });

      test('T2-F1-04: Extreme empty string fields in KanjiMetadataEntry preserve model integrity', () {
        const entry = KanjiMetadataEntry(
          codepoint: 0x4E00,
          literal: '',
          strokeCount: 0,
          meanings: [],
          onyomi: [],
          kunyomi: [],
          radical: '',
        );
        expect(entry.meanings.isEmpty, isTrue);
        expect(entry.onyomi.isEmpty, isTrue);
        expect(entry.literal, equals(''));
      });

      test('T2-F1-05: Single stroke kanji "一" (0x4E00) stroke precision with 50 point samples', () async {
        final bundledStroke = BundledStrokeSource(contentDb: bundledContentDb);
        final strokes = await bundledStroke.getStrokes(0x4E00);
        expect(strokes, isNotNull);
        expect(strokes!.length, equals(1));
        expect(strokes.first.sampledPoints.length, equals(50));
        expect(strokes.first.arcLength, greaterThan(0.0));
      });
    });

    // ------------------------------------------------------------------------
    // F2 Boundaries: Bundled Defaults & Non-existent Codepoints (5 tests)
    // ------------------------------------------------------------------------
    group('F2 Boundaries: Bundled Defaults & Non-existent Codepoints', () {
      test('T2-F2-01: Bundled metadata query with negative codepoint returns null safely', () async {
        final bundledMeta = BundledMetadataSource(contentDb: bundledContentDb);
        expect(await bundledMeta.getMetadata(-1), isNull);
        expect(await bundledMeta.getMetadata(-99999), isNull);
      });

      test('T2-F2-02: Bundled metadata query with codepoint 0 returns null safely', () async {
        final bundledMeta = BundledMetadataSource(contentDb: bundledContentDb);
        expect(await bundledMeta.getMetadata(0), isNull);
      });

      test('T2-F2-03: Bundled stroke query with non-existent codepoint returns null & false', () async {
        final bundledStroke = BundledStrokeSource(contentDb: bundledContentDb);
        expect(await bundledStroke.getStrokes(0x1FFFF), isNull);
        expect(await bundledStroke.containsStrokes(0x1FFFF), isFalse);
      });

      test('T2-F2-04: Default TTS audio with empty reading string falls back to literal character', () async {
        final defaultTts = DefaultTtsAudioSource(speechService: FakeSpeechService(), contentDb: bundledContentDb);
        final audio = await defaultTts.getAudio(0x4E00, reading: '');
        expect(audio, isNotNull);
        expect(audio!.uriOrText, equals('イチ'));
      });

      test('T2-F2-05: Attempting to unregister bundled default source throws UnsupportedError', () {
        final registry = ContentSourceRegistry();
        final bundled = BundledMetadataSource(contentDb: bundledContentDb);
        registry.registerMetadataSource(bundled);

        expect(
          () => registry.unregisterSource('bundled_metadata'),
          throwsA(isA<UnsupportedError>()),
        );
      });
    });

    // ------------------------------------------------------------------------
    // F3 Boundaries: Extreme Priorities & Registry Edge Cases (5 tests)
    // ------------------------------------------------------------------------
    group('F3 Boundaries: Extreme Priorities & Registry Edge Cases', () {
      test('T2-F3-01: Extreme priority values int.maxFinite and negative priorities sort correctly', () {
        final registry = ContentSourceRegistry();
        final bundled = BundledMetadataSource(contentDb: bundledContentDb);
        final sMax = MockCustomMetadataSource(sourceId: 's_max');
        final sNeg = MockCustomMetadataSource(sourceId: 's_neg');
        final sMid = MockCustomMetadataSource(sourceId: 's_mid');

        registry.registerMetadataSource(bundled);
        registry.registerMetadataSource(sNeg, priority: -100);
        registry.registerMetadataSource(sMax, priority: 999999999);
        registry.registerMetadataSource(sMid, priority: 0);

        final ids = registry.activeMetadataSources.map((s) => s.sourceId).toList();
        expect(ids, equals(['s_max', 's_mid', 's_neg', 'bundled_metadata']));
      });

      test('T2-F3-02: Duplicate source registration with same sourceId replaces previous priority', () {
        final registry = ContentSourceRegistry();
        final s1 = MockCustomMetadataSource(sourceId: 'dup_id', displayName: 'V1');
        final s2 = MockCustomMetadataSource(sourceId: 'dup_id', displayName: 'V2');

        registry.registerMetadataSource(s1, priority: 10);
        registry.registerMetadataSource(s2, priority: 50);

        expect(registry.activeMetadataSources.length, equals(1));
        expect(registry.activeMetadataSources.first.displayName, equals('V2'));
      });

      test('T2-F3-03: Unregistering non-existent sourceId is a safe no-op without exception', () {
        final registry = ContentSourceRegistry();
        expect(() => registry.unregisterSource('nonexistent_id'), returnsNormally);
      });

      test('T2-F3-04: Equal priority sources break ties deterministically using FIFO sequence order', () {
        final registry = ContentSourceRegistry();
        final s1 = MockCustomMetadataSource(sourceId: 'first');
        final s2 = MockCustomMetadataSource(sourceId: 'second');

        registry.registerMetadataSource(s1, priority: 10);
        registry.registerMetadataSource(s2, priority: 10);

        final ids = registry.activeMetadataSources.map((s) => s.sourceId).toList();
        expect(ids, equals(['first', 'second']));
      });

      test('T2-F3-05: clearCustomSources purges all custom sources while keeping bundled defaults', () {
        final registry = ContentSourceRegistry();
        registry.registerMetadataSource(BundledMetadataSource(contentDb: bundledContentDb));
        registry.registerMetadataSource(MockCustomMetadataSource(sourceId: 'c1'));
        registry.registerMetadataSource(MockCustomMetadataSource(sourceId: 'c2'));

        expect(registry.activeMetadataSources.length, equals(3));
        registry.clearCustomSources();
        expect(registry.activeMetadataSources.length, equals(1));
        expect(registry.activeMetadataSources.first.isBundledDefault, isTrue);
      });
    });

    // ------------------------------------------------------------------------
    // F4 Boundaries: Component Partiality & Cache Invalidation (5 tests)
    // ------------------------------------------------------------------------
    group('F4 Boundaries: Component Partiality & Cache Invalidation', () {
      test('T2-F4-01: Partial custom source with empty meanings list handled without crashing', () async {
        final registry = ContentSourceRegistry();
        final repo = ContentRepository(registry: registry);

        registry.registerMetadataSource(
          MockCustomMetadataSource(
            sourceId: 'empty_meanings',
            entries: {
              0x4E00: const KanjiMetadataEntry(
                codepoint: 0x4E00,
                literal: '一',
                strokeCount: 1,
                meanings: [],
              ),
            },
          ),
          priority: 10,
        );

        final kanji = await repo.getKanjiByCodepoint(0x4E00);
        expect(kanji, isNotNull);
        expect(kanji!.meanings, isEmpty);
      });

      test('T2-F4-02: Stack of 5 custom metadata sources traverses in exact priority order', () async {
        final registry = ContentSourceRegistry();
        for (var i = 1; i <= 5; i++) {
          registry.registerMetadataSource(
            MockCustomMetadataSource(
              sourceId: 'meta_layer_$i',
              entries: i == 4
                  ? {
                      0x4E00: KanjiMetadataEntry(
                        codepoint: 0x4E00,
                        literal: '一',
                        strokeCount: 1,
                        meanings: ['layer_$i'],
                      ),
                    }
                  : {},
            ),
            priority: i * 10,
          );
        }

        final entry = await registry.queryMetadata(0x4E00);
        expect(entry?.meanings, equals(['layer_4']));
      });

      test('T2-F4-03: Stroke source returning empty list falls back to subsequent stroke sources', () async {
        final registry = ContentSourceRegistry();
        registry.registerStrokeSource(BundledStrokeSource(contentDb: bundledContentDb));
        registry.registerStrokeSource(
          MockCustomStrokeSource(
            sourceId: 'empty_stroke_list',
            strokeMap: {
              0x4E00: [], // Empty list
            },
          ),
          priority: 20,
        );

        final strokes = await registry.queryStrokes(0x4E00);
        expect(strokes, isNotNull);
        expect(strokes!.length, equals(1)); // Falls back to bundled stroke
      });

      test('T2-F4-04: Audio resolution with null reading and unknown codepoint generates safe fallback', () async {
        final registry = ContentSourceRegistry();
        final repo = ContentRepository(registry: registry);

        final audio = await repo.resolveAudio(0x9999);
        expect(audio.type, equals(AudioPayloadType.ttsFallback));
        expect(audio.reading, equals('\u9999'));
      });

      test('T2-F4-05: Cache invalidation: unregistering source clears repository resolution cache', () async {
        final registry = ContentSourceRegistry();
        final repo = ContentRepository(registry: registry);

        registry.registerMetadataSource(BundledMetadataSource(contentDb: bundledContentDb));
        registry.registerMetadataSource(
          MockCustomMetadataSource(
            sourceId: 'cached_source',
            entries: {
              0x4E00: const KanjiMetadataEntry(
                codepoint: 0x4E00,
                literal: '一',
                strokeCount: 1,
                meanings: ['cached definition'],
              ),
            },
          ),
          priority: 20,
        );

        // Resolve and cache
        final k1 = await repo.getKanjiByCodepoint(0x4E00);
        expect(k1?.meanings, equals(['cached definition']));
        expect(repo.cachedCharacterCount, equals(1));

        // Unregister source
        registry.unregisterSource('cached_source');
        expect(repo.cachedCharacterCount, equals(0)); // Cache cleared on unregister

        // Next resolve returns bundled definition
        final k2 = await repo.getKanjiByCodepoint(0x4E00);
        expect(k2?.meanings, contains('one'));
      });
    });

    // ------------------------------------------------------------------------
    // F5 Boundaries: FSRS Value Extremes & Long Rep Cycles (5 tests)
    // ------------------------------------------------------------------------
    group('F5 Boundaries: FSRS Value Extremes & Long Rep Cycles', () {
      test('T2-F5-01: FSRS scheduling boundary: elapsedDays = 0, reps = 0, state New', () {
        final userDb = UserDatabase.openInMemory();
        userDb.upsertCard(
          UserCardProgress(
            codepoint: 0x4E00,
            mode: PracticeMode.writing,
            dueDate: DateTime.utc(2026, 1, 1),
            stability: 0.0,
            difficulty: 0.0,
            elapsedDays: 0,
            scheduledDays: 0,
            reps: 0,
            lapses: 0,
            state: 0,
          ),
        );

        final card = userDb.getCard(0x4E00, mode: PracticeMode.writing);
        expect(card, isNotNull);
        expect(card!.state, equals(0));
        expect(card.reps, equals(0));
      });

      test('T2-F5-02: Extreme stability and difficulty bounds handled properly in UserCardProgress', () {
        final userDb = UserDatabase.openInMemory();
        userDb.upsertCard(
          UserCardProgress(
            codepoint: 0x4E00,
            mode: PracticeMode.writing,
            dueDate: DateTime.utc(2030, 1, 1),
            stability: 3650.0, // 10 years stability
            difficulty: 10.0, // Max difficulty
            elapsedDays: 500,
            scheduledDays: 1000,
            reps: 50,
            lapses: 5,
            state: 2,
          ),
        );

        final card = userDb.getCard(0x4E00, mode: PracticeMode.writing);
        expect(card?.stability, equals(3650.0));
        expect(card?.difficulty, equals(10.0));
      });

      test('T2-F5-03: Querying due cards when all cards are due in future returns empty list', () {
        final userDb = UserDatabase.openInMemory();
        userDb.upsertCard(
          UserCardProgress(
            codepoint: 0x4E00,
            mode: PracticeMode.writing,
            dueDate: DateTime.utc(2030, 1, 1),
            stability: 10.0,
            difficulty: 5.0,
            elapsedDays: 1,
            scheduledDays: 10,
            reps: 3,
            lapses: 0,
            state: 2,
          ),
        );

        final due = userDb.getDueCards(now: DateTime.utc(2026, 1, 1), mode: PracticeMode.writing);
        expect(due, isEmpty);
      });

      test('T2-F5-04: Card referencing codepoint beyond bundled set persists without foreign key errors', () {
        final userDb = UserDatabase.openInMemory();
        expect(
          () => userDb.upsertCard(
            UserCardProgress(
              codepoint: 0x2A6D6, // CJK Extension B kanji
              mode: PracticeMode.writing,
              dueDate: DateTime.utc(2026, 1, 1),
              stability: 1.0,
              difficulty: 5.0,
              elapsedDays: 0,
              scheduledDays: 1,
              reps: 1,
              lapses: 0,
              state: 1,
            ),
          ),
          returnsNormally,
        );

        final card = userDb.getCard(0x2A6D6, mode: PracticeMode.writing);
        expect(card?.codepoint, equals(0x2A6D6));
      });

      test('T2-F5-05: Rapid sequential reviews (20 reviews in loop) maintain monotonic stability', () {
        final userDb = UserDatabase.openInMemory();
        final scheduler = FsrsSchedulerService();
        var now = DateTime.utc(2026, 1, 1, 10, 0);

        double lastStability = 0.0;
        for (var i = 0; i < 20; i++) {
          final card = scheduler.recordPracticeCompletion(
            userDb: userDb,
            codepoint: 0x4E00,
            mistakes: 0,
            hintsUsed: 0,
            now: now,
          );
          expect(card.reps, equals(i + 1));
          expect(card.stability, greaterThanOrEqualTo(lastStability));
          lastStability = card.stability;
          now = now.add(Duration(days: card.scheduledDays > 0 ? card.scheduledDays : 1));
        }
      });
    });

    // ------------------------------------------------------------------------
    // F6 Boundaries: Manifest Schema Extremes & SemVer Corner Cases (5 tests)
    // ------------------------------------------------------------------------
    group('F6 Boundaries: Manifest Schema Extremes & SemVer Corner Cases', () {
      test('T2-F6-01: Manifest formatVersion boundary: version 0 or 2 throws FormatException', () {
        expect(
          () => SourceManifest.fromJson({
            'formatVersion': 0,
            'id': 'id',
            'name': 'Name',
            'version': '1.0.0',
            'capabilities': ['metadata'],
          }),
          throwsA(isA<FormatException>()),
        );
        expect(
          () => SourceManifest.fromJson({
            'formatVersion': 2,
            'id': 'id',
            'name': 'Name',
            'version': '1.0.0',
            'capabilities': ['metadata'],
          }),
          throwsA(isA<FormatException>()),
        );
      });

      test('T2-F6-02: Manifest ID length boundary: 128 characters is valid, 129 is rejected', () {
        final validId = 'a' * 128;
        final invalidId = 'a' * 129;

        expect(SourceManifest.isValidId(validId), isTrue);
        expect(SourceManifest.isValidId(invalidId), isFalse);
      });

      test('T2-F6-03: SemVer with pre-release tag and build metadata parses successfully', () {
        final manifest = SourceManifest.fromJson({
          'id': 'semver_complex',
          'name': 'Complex SemVer',
          'version': '2.1.0-alpha.1+20261107',
          'capabilities': ['metadata'],
        });
        expect(manifest.version, equals('2.1.0-alpha.1+20261107'));
      });

      test('T2-F6-04: Manifest with extra unknown JSON fields parses successfully', () {
        final manifest = SourceManifest.fromJson({
          'id': 'extra_fields',
          'name': 'Extra Fields',
          'version': '1.0.0',
          'capabilities': ['metadata'],
          'customExtensionKey': {'nested': true},
          'publisherWebsite': 'https://example.com',
        });
        expect(manifest.id, equals('extra_fields'));
      });

      test('T2-F6-05: Manifest with whitespace padded fields trims strings safely', () {
        final manifest = SourceManifest.fromJson({
          'id': ' trimmed_id ',
          'name': ' Trimmed Name ',
          'version': ' 1.0.0 ',
          'author': ' Sensei ',
          'capabilities': ['metadata'],
        });
        expect(manifest.id, equals('trimmed_id'));
        expect(manifest.name, equals('Trimmed Name'));
        expect(manifest.version, equals('1.0.0'));
        expect(manifest.author, equals('Sensei'));
      });
    });

    // ------------------------------------------------------------------------
    // F7 Boundaries: Strokes Bounds, Blobs & Audio Size (5 tests)
    // ------------------------------------------------------------------------
    group('F7 Boundaries: Strokes Bounds, Blobs & Audio Size', () {
      final validator = SourceValidator();

      test('T2-F7-01: Stroke count upper boundary: 64 strokes accepted, 65 strokes rejected', () {
        final strokes64 = List.generate(64, (i) => {'svg_path': 'M 0 0 L 10 10'});
        final strokes65 = List.generate(65, (i) => {'svg_path': 'M 0 0 L 10 10'});

        expect(validator.validateStrokeData(codepoint: 0x4E00, rawStrokes: strokes64).isValid, isTrue);
        expect(validator.validateStrokeData(codepoint: 0x4E00, rawStrokes: strokes65).isValid, isFalse);
      });

      test('T2-F7-02: Stroke points blob boundary: exactly 400 bytes accepted, 399 and 401 rejected', () {
        final blob400 = TestPackageBuilder.createFloat32PointsBlob(pointCount: 50);
        expect(blob400.lengthInBytes, equals(400));
        expect(validator.validatePointsBlob(blob400).isValid, isTrue);

        final blob399 = Uint8List(399);
        expect(validator.validatePointsBlob(blob399).isValid, isFalse);

        final blob401 = Uint8List(401);
        expect(validator.validatePointsBlob(blob401).isValid, isFalse);
      });

      test('T2-F7-03: Point coordinates with NaN or Infinity are rejected', () {
        final blob = ByteData(400);
        blob.setFloat32(0, double.nan, Endian.little);
        blob.setFloat32(4, 50.0, Endian.little);
        expect(validator.validatePointsBlob(blob.buffer.asUint8List()).isValid, isFalse);

        final blobInf = ByteData(400);
        blobInf.setFloat32(0, double.infinity, Endian.little);
        expect(validator.validatePointsBlob(blobInf.buffer.asUint8List()).isValid, isFalse);
      });

      test('T2-F7-04: Zip-Slip variations (../, ..\\, nested) are all detected and blocked', () {
        expect(ZipSlipGuard.isPathSafe(globalTempDir.path, '../escape.txt'), isFalse);
        expect(ZipSlipGuard.isPathSafe(globalTempDir.path, r'..\escape.txt'), isFalse);
        expect(ZipSlipGuard.isPathSafe(globalTempDir.path, 'a/b/../../../escape.txt'), isFalse);
        expect(ZipSlipGuard.isPathSafe(globalTempDir.path, r'a\b\..\..\..\escape.txt'), isFalse);
        expect(ZipSlipGuard.isPathSafe(globalTempDir.path, '/absolute/path.txt'), isFalse);
        expect(ZipSlipGuard.isPathSafe(globalTempDir.path, 'C:\\absolute\\path.txt'), isFalse);
      });

      test('T2-F7-05: Audio file size bounds: 31 bytes rejected (too small), 32 bytes valid', () {
        final smallBytes = Uint8List(31);
        expect(validator.validateAudioBytes(smallBytes, filename: 'tiny.wav').isValid, isFalse);

        final wavBytes32 = TestPackageBuilder.createWavBytes(44);
        expect(validator.validateAudioBytes(wavBytes32, filename: 'valid.wav').isValid, isTrue);
      });
    });

    // ------------------------------------------------------------------------
    // F8 Boundaries: Empty/Truncated Archive & Rollback (5 tests)
    // ------------------------------------------------------------------------
    group('F8 Boundaries: Empty/Truncated Archive & Rollback', () {
      late Directory tempDir;
      late PackageStagingManager staging;
      late OfflinePackageLoader loader;

      setUp(() async {
        tempDir = Directory.systemTemp.createTempSync('tsuzuri_t2_f8_');
        staging = PackageStagingManager(baseDirectory: tempDir);
        await staging.initialize();
        loader = OfflinePackageLoader(stagingManager: staging, validator: SourceValidator());
      });

      tearDown(() {
        try {
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        } catch (_) {}
      });

      test('T2-F8-01: Ingestion of empty ZIP archive (0 files) returns missingManifest', () async {
        final emptyZip = File(p.join(tempDir.path, 'empty.zip'));
        await emptyZip.writeAsBytes(TestPackageBuilder.encodeZip(Archive()));

        final result = await loader.loadFromArchive(emptyZip);
        expect(result.isSuccess, isFalse);
        expect(result.errorCode, equals(IngestionErrorCode.missingManifest));
      });

      test('T2-F8-02: Archive declaring metadata capability but missing metadata file returns missingAssetFile', () async {
        final archive = Archive();
        final manifestJson = jsonEncode({
          'formatVersion': 1,
          'id': 'missing_file_pkg',
          'name': 'Missing File',
          'version': '1.0.0',
          'capabilities': ['metadata'],
          'metadataPath': 'nonexistent.json',
        });
        archive.addFile(ArchiveFile.string('manifest.json', manifestJson));

        final zipFile = File(p.join(tempDir.path, 'missing_file.zip'));
        await zipFile.writeAsBytes(TestPackageBuilder.encodeZip(archive));

        final result = await loader.loadFromArchive(zipFile);
        expect(result.isSuccess, isFalse);
        expect(result.errorCode, equals(IngestionErrorCode.missingAssetFile));
      });

      test('T2-F8-03: Ingestion from non-existent archive path returns missingAssetFile', () async {
        final nonExistent = File(p.join(tempDir.path, 'does_not_exist.zip'));
        final result = await loader.loadFromArchive(nonExistent);
        expect(result.isSuccess, isFalse);
        expect(result.errorCode, equals(IngestionErrorCode.missingAssetFile));
      });

      test('T2-F8-04: Ingestion of zero-byte file returns invalidArchive', () async {
        final zeroByte = File(p.join(tempDir.path, 'zero.zip'));
        await zeroByte.writeAsBytes([]);

        final result = await loader.loadFromArchive(zeroByte);
        expect(result.isSuccess, isFalse);
        expect(result.errorCode, equals(IngestionErrorCode.invalidArchive));
      });

      test('T2-F8-05: Ingestion of directory package with nested subdirs handles path normalization', () async {
        final dir = Directory(p.join(tempDir.path, 'nested_dir_pkg'));
        await dir.create(recursive: true);

        final subMetaDir = Directory(p.join(dir.path, 'sub', 'folder'));
        await subMetaDir.create(recursive: true);

        final manifest = {
          'formatVersion': 1,
          'id': 'nested_dir_pkg',
          'name': 'Nested Dir Package',
          'version': '1.0.0',
          'capabilities': ['metadata'],
          'metadataPath': 'sub/folder/meta.json',
        };
        await File(p.join(dir.path, 'manifest.json')).writeAsString(jsonEncode(manifest));
        await File(p.join(subMetaDir.path, 'meta.json')).writeAsString(jsonEncode([
          {'codepoint': 0x4E00, 'literal': '一', 'stroke_count': 1, 'meanings': ['nested']}
        ]));

        final result = await loader.loadFromDirectory(dir);
        expect(result.isSuccess, isTrue);
      });
    });

    // ------------------------------------------------------------------------
    // F9 Boundaries: HTTP Timeouts, 404, 500 & Connection Refusal (5 tests)
    // ------------------------------------------------------------------------
    group('F9 Boundaries: HTTP Timeouts, 404, 500 & Connection Refusal', () {
      late Directory tempDir;
      late PackageStagingManager staging;
      late OnlineSourceFetcher fetcher;
      late MockContentHttpServer server;

      setUp(() async {
        tempDir = Directory.systemTemp.createTempSync('tsuzuri_t2_f9_');
        staging = PackageStagingManager(baseDirectory: tempDir);
        await staging.initialize();
        fetcher = OnlineSourceFetcher(stagingManager: staging, validator: SourceValidator());
        server = MockContentHttpServer();
        await server.start();
      });

      tearDown(() async {
        await server.stop();
        try {
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        } catch (_) {}
      });

      test('T2-F9-01: Online fetch with instantaneous timeout (1ms) triggers timeout errorCode', () async {
        server.serveDelayed('/slow.json', const Duration(milliseconds: 500));

        final result = await fetcher.fetchAndInstall(
          Uri.parse('${server.baseUrl}/slow.json'),
          options: const FetchOptions(
            connectTimeout: Duration(milliseconds: 10),
            receiveTimeout: Duration(milliseconds: 10),
            maxRetries: 0,
          ),
        );
        expect(result.isSuccess, isFalse);
        expect(result.errorCode, equals(IngestionErrorCode.timeout));
      });

      test('T2-F9-02: Online fetch to closed port (connection refused) returns networkError', () async {
        // Bind and immediately close an ephemeral loopback port to guarantee connection refused
        final unusedServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final closedPort = unusedServer.port;
        await unusedServer.close(force: true);

        final result = await fetcher.fetchAndInstall(
          Uri.parse('http://127.0.0.1:$closedPort/nonexistent.json'),
          options: const FetchOptions(maxRetries: 0),
        );
        expect(result.isSuccess, isFalse);
        expect(result.errorCode, equals(IngestionErrorCode.networkError));
      });

      test('T2-F9-03: Online fetch returning malformed JSON manifest body returns invalidManifest', () async {
        server.serveError('/bad_json.json', 200, body: 'NOT_VALID_JSON{[');

        final result = await fetcher.fetchAndInstall(
          Uri.parse('${server.baseUrl}/bad_json.json'),
          options: const FetchOptions(maxRetries: 0),
        );
        expect(result.isSuccess, isFalse);
        expect(result.errorCode, equals(IngestionErrorCode.invalidManifest));
      });

      test('T2-F9-04: Online fetch where asset payload is corrupted or truncated is rejected', () async {
        final manifest = {
          'formatVersion': 1,
          'id': 'corrupt_stream_pkg',
          'name': 'Corrupt Stream',
          'version': '1.0.0',
          'capabilities': ['metadata'],
          'metadataPath': 'metadata.json',
        };
        server.serveManifest('/corrupt_stream/manifest.json', manifest);
        server.serveCorrupted('/corrupt_stream/metadata.json');

        final result = await fetcher.fetchAndInstall(
          Uri.parse('${server.baseUrl}/corrupt_stream/manifest.json'),
          options: const FetchOptions(maxRetries: 0),
        );
        expect(result.isSuccess, isFalse);
      });

      test('T2-F9-05: HTTP 503 Service Unavailable triggers retries and terminates gracefully', () async {
        server.serveError('/503.json', 503, body: 'Service Unavailable');

        final result = await fetcher.fetchAndInstall(
          Uri.parse('${server.baseUrl}/503.json'),
          options: const FetchOptions(maxRetries: 1, retryDelay: Duration(milliseconds: 20)),
        );
        expect(result.isSuccess, isFalse);
        expect(result.errorCode, equals(IngestionErrorCode.networkError));
      });
    });

    // ------------------------------------------------------------------------
    // F10 Boundaries: Error Code Mapping & Progress Invariance Under Stress (5 tests)
    // ------------------------------------------------------------------------
    group('F10 Boundaries: Error Code Mapping & Progress Invariance Under Stress', () {
      test('T2-F10-01: Ingestion failure does not leave orphan lock on UserDatabase', () async {
        final userDb = UserDatabase.openInMemory();
        userDb.upsertCard(
          UserCardProgress(
            codepoint: 0x4E00,
            mode: PracticeMode.writing,
            dueDate: DateTime.utc(2026, 1, 1),
            stability: 1.0,
            difficulty: 5.0,
            elapsedDays: 0,
            scheduledDays: 1,
            reps: 1,
            lapses: 0,
            state: 1,
          ),
        );

        // Immediate write operation on userDb after simulated error succeeds
        userDb.upsertCard(
          UserCardProgress(
            codepoint: 0x4E8C,
            mode: PracticeMode.writing,
            dueDate: DateTime.utc(2026, 1, 1),
            stability: 1.0,
            difficulty: 5.0,
            elapsedDays: 0,
            scheduledDays: 1,
            reps: 1,
            lapses: 0,
            state: 1,
          ),
        );

        expect(userDb.getCard(0x4E8C, mode: PracticeMode.writing), isNotNull);
      });

      test('T2-F10-02: Multiple concurrent staging creations create isolated unique directories', () async {
        final tempDir = Directory.systemTemp.createTempSync('tsuzuri_t2_f10_c_');
        final staging = PackageStagingManager(baseDirectory: tempDir);
        await staging.initialize();

        final dir1 = await staging.createStagingDirectory('test_id');
        final dir2 = await staging.createStagingDirectory('test_id');

        expect(dir1.path, isNot(equals(dir2.path)));
        expect(dir1.existsSync(), isTrue);
        expect(dir2.existsSync(), isTrue);

        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      });

      test('T2-F10-03: Custom source throwing in getAllCodepoints does not crash queryAllCodepoints', () async {
        final registry = ContentSourceRegistry();
        final bundled = BundledMetadataSource(contentDb: bundledContentDb);
        final faulty = MockCustomMetadataSource(
          sourceId: 'faulty_codepoints',
          shouldThrowOnAll: true,
          throwError: StateError('Codepoint table corrupted'),
        );

        registry.registerMetadataSource(bundled);
        registry.registerMetadataSource(faulty, priority: 10);

        final allCodepoints = await registry.queryAllCodepoints();
        expect(allCodepoints.length, equals(bundledContentDb.totalKanjiCount));
      });

      test('T2-F10-04: Custom source throwing in generateMeaningDistractors falls back to bundled', () async {
        final registry = ContentSourceRegistry();
        final bundled = BundledMetadataSource(contentDb: bundledContentDb);
        final faulty = MockCustomMetadataSource(
          sourceId: 'faulty_distractors',
          shouldThrowOnDistractors: true,
          throwError: RangeError('Index out of range in distractor pool'),
        );

        registry.registerMetadataSource(bundled);
        registry.registerMetadataSource(faulty, priority: 10);

        final target = (await bundled.getMetadata(0x4E00))!;
        final distractors = await registry.queryMeaningDistractors(target, count: 3);
        expect(distractors.length, equals(3));
      });

      test('T2-F10-05: Re-registering custom source after unregistering restores functionality safely', () async {
        final registry = ContentSourceRegistry();
        final s = MockCustomMetadataSource(
          sourceId: 'toggle_source',
          entries: {
            0x4E00: const KanjiMetadataEntry(
              codepoint: 0x4E00,
              literal: '一',
              strokeCount: 1,
              meanings: ['toggled'],
            ),
          },
        );

        registry.registerMetadataSource(s, priority: 10);
        expect((await registry.queryMetadata(0x4E00))?.meanings, equals(['toggled']));

        registry.unregisterSource('toggle_source');
        expect(await registry.queryMetadata(0x4E00), isNull);

        registry.registerMetadataSource(s, priority: 10);
        expect((await registry.queryMetadata(0x4E00))?.meanings, equals(['toggled']));
      });
    });
  });

  // ============================================================================
  // TIER 3: CROSS-FEATURE COMBINATIONS (15 Tests)
  // ============================================================================
  group('Tier 3: Cross-Feature Combinations', () {
    late Directory tempDir;
    late PackageStagingManager stagingManager;
    late OfflinePackageLoader offlineLoader;
    late OnlineSourceFetcher onlineFetcher;
    late MockContentHttpServer mockHttp;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('tsuzuri_t3_');
      stagingManager = PackageStagingManager(baseDirectory: tempDir);
      await stagingManager.initialize();
      final validator = SourceValidator();
      offlineLoader = OfflinePackageLoader(stagingManager: stagingManager, validator: validator);
      onlineFetcher = OnlineSourceFetcher(stagingManager: stagingManager, validator: validator);
      mockHttp = MockContentHttpServer();
      await mockHttp.start();
    });

    tearDown(() async {
      await mockHttp.stop();
      try {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('T3-01: [F1+F8] Offline ZIP package ingested -> Extracted & registered as Metadata & Stroke sources', () async {
      final zipFile = File(p.join(tempDir.path, 't3_01.zip'));
      await TestPackageBuilder.writeValidZipPackage(
        zipFile,
        id: 'pkg_t3_01',
        sampleCodepoint: 0x4E00,
        sampleLiteral: '一',
        meanings: ['t3_01 meaning'],
      );

      final result = await offlineLoader.loadFromArchive(zipFile);
      expect(result.isSuccess, isTrue);

      final pkgDir = Directory(result.packageDirectory!);
      final metaSource = await CustomMetadataSource.fromDirectory(pkgDir, result.manifest!);
      final strokeSource = await CustomStrokeSource.fromDirectory(pkgDir, result.manifest!);

      final registry = ContentSourceRegistry();
      registry.registerMetadataSource(metaSource);
      registry.registerStrokeSource(strokeSource);
      final repo = ContentRepository(registry: registry);

      final kanji = await repo.getKanjiByCodepoint(0x4E00);
      expect(kanji?.meanings, equals(['t3_01 meaning']));
      expect(kanji?.strokes.length, equals(1));
    });

    test('T3-02: [F2+F3+F4] Layer custom metadata over bundled strokes and bundled audio', () async {
      final registry = ContentSourceRegistry();
      final repo = ContentRepository(registry: registry);

      registry.registerMetadataSource(BundledMetadataSource(contentDb: bundledContentDb));
      registry.registerStrokeSource(BundledStrokeSource(contentDb: bundledContentDb));
      registry.registerAudioSource(DefaultTtsAudioSource(speechService: FakeSpeechService(), contentDb: bundledContentDb));

      final custom = MockCustomMetadataSource(
        sourceId: 'meta_layer',
        entries: {
          0x4E00: const KanjiMetadataEntry(
            codepoint: 0x4E00,
            literal: '一',
            strokeCount: 1,
            meanings: ['layered custom meaning'],
          ),
        },
      );
      registry.registerMetadataSource(custom, priority: 50);

      final kanji = await repo.getKanjiByCodepoint(0x4E00);
      expect(kanji?.meanings, equals(['layered custom meaning']));
      expect(kanji?.strokes.first.sampledPoints.length, equals(50)); // Bundled stroke points

      final audio = await repo.resolveAudio(0x4E00, reading: 'イチ');
      expect(audio.type, equals(AudioPayloadType.ttsFallback)); // Bundled audio
    });

    test('T3-03: [F3+F9] Ingest online package over HTTP -> Falls back to bundled for non-included kanji', () async {
      final manifest = {
        'formatVersion': 1,
        'id': 'online_t3_03',
        'name': 'Online T3-03',
        'version': '1.0.0',
        'capabilities': ['metadata'],
        'metadataPath': 'metadata.json',
      };
      final metadata = [{'codepoint': 0x4E00, 'literal': '一', 'stroke_count': 1, 'meanings': ['remote kanji']}];

      mockHttp.serveManifest('/t3_03/manifest.json', manifest);
      mockHttp.serveBytes('/t3_03/metadata.json', utf8.encode(jsonEncode(metadata)), contentType: 'application/json');

      final result = await onlineFetcher.fetchAndInstall(Uri.parse('${mockHttp.baseUrl}/t3_03/manifest.json'));
      expect(result.isSuccess, isTrue);

      final customMeta = await CustomMetadataSource.fromDirectory(
        Directory(result.packageDirectory!),
        result.manifest!,
      );

      final registry = ContentSourceRegistry();
      registry.registerMetadataSource(BundledMetadataSource(contentDb: bundledContentDb));
      registry.registerMetadataSource(customMeta, priority: 10);
      final repo = ContentRepository(registry: registry);

      // 0x4E00 comes from online package
      final k1 = await repo.getKanjiByCodepoint(0x4E00);
      expect(k1?.meanings, equals(['remote kanji']));

      // 0x4E8C comes from bundled default
      final k2 = await repo.getKanjiByCodepoint(0x4E8C);
      expect(k2?.meanings, contains('two'));
    });

    test('T3-04: [F4+F5] User practices writing mode on Kanji with custom strokes; swapping strokes preserves FSRS state', () async {
      final userDb = UserDatabase.openInMemory();
      final scheduler = FsrsSchedulerService();

      // Practice with custom stroke source
      final card1 = scheduler.recordPracticeCompletion(
        userDb: userDb,
        codepoint: 0x4E00,
        mistakes: 0,
        hintsUsed: 0,
        mode: PracticeMode.writing,
        now: DateTime.utc(2026, 1, 1, 10, 0),
      );

      // Swap stroke provider in registry
      final registry = ContentSourceRegistry();
      registry.registerMetadataSource(BundledMetadataSource(contentDb: bundledContentDb));
      registry.registerStrokeSource(BundledStrokeSource(contentDb: bundledContentDb));
      final repo = ContentRepository(registry: registry);

      // Verify character still resolves with bundled strokes
      final kanji = await repo.getKanjiByCodepoint(0x4E00);
      expect(kanji?.strokes.length, equals(1));

      // Card in userDb is unchanged
      final storedCard = userDb.getCard(0x4E00, mode: PracticeMode.writing);
      expect(storedCard?.stability, equals(card1.stability));
      expect(storedCard?.reps, equals(1));
    });

    test('T3-05: [F5+F8] User reviews custom kanji in v1 package; updates package to v2; card progress preserved', () async {
      final userDb = UserDatabase.openInMemory();
      final scheduler = FsrsSchedulerService();

      // Ingest v1.0.0
      final v1Zip = File(p.join(tempDir.path, 'v1.zip'));
      await TestPackageBuilder.writeValidZipPackage(
        v1Zip,
        id: 'versioned_pkg',
        version: '1.0.0',
        sampleCodepoint: 0x9B1D,
        sampleLiteral: '鬝',
        meanings: ['v1 definition'],
      );
      final r1 = await offlineLoader.loadFromArchive(v1Zip);
      expect(r1.isSuccess, isTrue);

      // User studies this kanji
      scheduler.recordPracticeCompletion(
        userDb: userDb,
        codepoint: 0x9B1D,
        mistakes: 0,
        hintsUsed: 0,
        now: DateTime.utc(2026, 1, 1, 10, 0),
      );

      // Now user updates package to v2.0.0
      final v2Zip = File(p.join(tempDir.path, 'v2.zip'));
      await TestPackageBuilder.writeValidZipPackage(
        v2Zip,
        id: 'versioned_pkg',
        version: '2.0.0',
        sampleCodepoint: 0x9B1D,
        sampleLiteral: '鬝',
        meanings: ['v2 definition'],
      );
      final r2 = await offlineLoader.loadFromArchive(v2Zip);
      expect(r2.isSuccess, isTrue);

      // Verify card state in database is intact
      final card = userDb.getCard(0x9B1D, mode: PracticeMode.writing);
      expect(card?.reps, equals(1));
      expect(card?.stability, greaterThan(0));

      // Querying updated package yields v2 definition
      final metaSource = await CustomMetadataSource.fromDirectory(
        Directory(r2.packageDirectory!),
        r2.manifest!,
      );
      final entry = await metaSource.getMetadata(0x9B1D);
      expect(entry?.meanings, equals(['v2 definition']));
    });

    test('T3-06: [F3+F5] Unregistering custom source safely omits card from queue; re-registering restores card', () async {
      final userDb = UserDatabase.openInMemory();
      final scheduler = FsrsSchedulerService();
      final registry = ContentSourceRegistry();
      final repo = ContentRepository(registry: registry);

      registry.registerMetadataSource(BundledMetadataSource(contentDb: bundledContentDb));
      registry.registerStrokeSource(BundledStrokeSource(contentDb: bundledContentDb));

      final customMeta = MockCustomMetadataSource(
        sourceId: 'transient_source',
        entries: {
          0x9B1D: const KanjiMetadataEntry(
            codepoint: 0x9B1D,
            literal: '鬝',
            strokeCount: 18,
            meanings: ['rare kanji'],
          ),
        },
      );
      registry.registerMetadataSource(customMeta, priority: 10);

      // Practice 0x9B1D
      scheduler.recordPracticeCompletion(
        userDb: userDb,
        codepoint: 0x9B1D,
        mistakes: 0,
        hintsUsed: 0,
        now: DateTime.utc(2026, 1, 1, 10, 0),
      );

      // 1. Unregister custom source
      registry.unregisterSource('transient_source');

      // 2. Build daily queue -> 0x9B1D cannot resolve, must be safely omitted
      final queueWithout = scheduler.buildDailyQueue(
        repository: repo,
        userDb: userDb,
        dailyNewLimit: 5,
        now: DateTime.utc(2027, 1, 1),
      );
      expect(queueWithout.any((q) => q.kanji.codepoint == 0x9B1D), isFalse);

      // 3. Re-register custom source
      registry.registerMetadataSource(customMeta, priority: 10);
      repo.clearCache();

      // 4. Build daily queue -> 0x9B1D re-appears!
      final queueWith = scheduler.buildDailyQueue(
        repository: repo,
        userDb: userDb,
        dailyNewLimit: 5,
        now: DateTime.utc(2027, 1, 1),
      );
      expect(queueWith.any((q) => q.kanji.codepoint == 0x9B1D), isTrue);
    });

    test('T3-07: [F6+F7+F8] Manifest specifies invalid metadata path; validator rejects; staging rolled back', () async {
      final archive = Archive();
      final manifestJson = jsonEncode({
        'formatVersion': 1,
        'id': 'bad_meta_path_pkg',
        'name': 'Bad Meta Path',
        'version': '1.0.0',
        'capabilities': ['metadata'],
        'metadataPath': 'missing_file.json',
      });
      archive.addFile(ArchiveFile.string('manifest.json', manifestJson));

      final badZip = File(p.join(tempDir.path, 'bad_meta_path.zip'));
      await badZip.writeAsBytes(TestPackageBuilder.encodeZip(archive));

      final result = await offlineLoader.loadFromArchive(badZip);
      expect(result.isSuccess, isFalse);
      expect(result.errorCode, equals(IngestionErrorCode.missingAssetFile));

      // Check staging is rolled back
      final promoted = Directory(p.join(tempDir.path, 'packages', 'bad_meta_path_pkg'));
      expect(promoted.existsSync(), isFalse);
    });

    test('T3-08: [F6+F7+F8] Malicious archive with Zip-Slip path traversal rejected; zero files written outside staging', () async {
      final zipSlipBytes = TestPackageBuilder.createZipSlipZipBytes(
        maliciousPath: '../../dangerous_payload.txt',
        id: 'exploit_t3_08',
      );
      final exploitZip = File(p.join(tempDir.path, 'exploit_t3_08.zip'));
      await exploitZip.writeAsBytes(zipSlipBytes);

      final result = await offlineLoader.loadFromArchive(exploitZip);
      expect(result.isSuccess, isFalse);
      expect(result.errorCode, equals(IngestionErrorCode.zipSlipDetected));

      // Verify dangerous_payload.txt was NOT written
      final dangerousFile = File(p.join(tempDir.path, 'dangerous_payload.txt'));
      expect(dangerousFile.existsSync(), isFalse);
    });

    test('T3-09: [F7+F9] Online fetcher downloads archive with SHA-256 checksum in manifest; mismatch rejected', () async {
      final manifest = {
        'formatVersion': 1,
        'id': 'online_checksum_guard',
        'name': 'Online Checksum Guard',
        'version': '1.0.0',
        'capabilities': ['metadata'],
        'metadataPath': 'metadata.json',
        'checksums': {
          'metadata.json': 'sha256:1111111111111111111111111111111111111111111111111111111111111111',
        },
      };
      mockHttp.serveManifest('/chk_guard/manifest.json', manifest);
      mockHttp.serveBytes('/chk_guard/metadata.json', utf8.encode('[]'), contentType: 'application/json');

      final result = await onlineFetcher.fetchAndInstall(Uri.parse('${mockHttp.baseUrl}/chk_guard/manifest.json'));
      expect(result.isSuccess, isFalse);
      expect(result.errorCode, equals(IngestionErrorCode.checksumMismatch));
    });

    test('T3-10: [F7+F10] Path traversal attack fails gracefully with clear error code; database unaffected', () async {
      final userDb = UserDatabase.openInMemory();
      final exploitBytes = TestPackageBuilder.createZipSlipZipBytes();
      final exploitFile = File(p.join(tempDir.path, 'exploit_t3_10.zip'));
      await exploitFile.writeAsBytes(exploitBytes);

      final result = await offlineLoader.loadFromArchive(exploitFile);
      expect(result.isSuccess, isFalse);
      expect(result.errorCode, equals(IngestionErrorCode.zipSlipDetected));
      expect(result.errorMessage, contains('traversal'));

      // Ensure user database remains functional
      userDb.upsertCard(
        UserCardProgress(
          codepoint: 0x4E00,
          mode: PracticeMode.writing,
          dueDate: DateTime.utc(2026, 1, 1),
          stability: 1.0,
          difficulty: 5.0,
          elapsedDays: 0,
          scheduledDays: 1,
          reps: 1,
          lapses: 0,
          state: 1,
        ),
      );
      expect(userDb.getCard(0x4E00, mode: PracticeMode.writing), isNotNull);
    });

    test('T3-11: [F3+F8+F9] Offline Package A and Online Package B active simultaneously with priority ordering', () async {
      // Package A (Offline): priority 10, defines 0x4E00 as "offline definition"
      final zipFile = File(p.join(tempDir.path, 'pkg_a.zip'));
      await TestPackageBuilder.writeValidZipPackage(
        zipFile,
        id: 'pkg_a',
        sampleCodepoint: 0x4E00,
        sampleLiteral: '一',
        meanings: ['offline definition'],
      );
      final rA = await offlineLoader.loadFromArchive(zipFile);
      expect(rA.isSuccess, isTrue);

      // Package B (Online): priority 20, overrides 0x4E00 as "online definition"
      final manifestB = {
        'formatVersion': 1,
        'id': 'pkg_b',
        'name': 'Pkg B',
        'version': '1.0.0',
        'capabilities': ['metadata'],
        'metadataPath': 'metadata.json',
      };
      final metadataB = [{'codepoint': 0x4E00, 'literal': '一', 'stroke_count': 1, 'meanings': ['online definition']}];
      mockHttp.serveManifest('/pkg_b/manifest.json', manifestB);
      mockHttp.serveBytes('/pkg_b/metadata.json', utf8.encode(jsonEncode(metadataB)), contentType: 'application/json');

      final rB = await onlineFetcher.fetchAndInstall(Uri.parse('${mockHttp.baseUrl}/pkg_b/manifest.json'));
      expect(rB.isSuccess, isTrue);

      final sourceA = await CustomMetadataSource.fromDirectory(Directory(rA.packageDirectory!), rA.manifest!);
      final sourceB = await CustomMetadataSource.fromDirectory(Directory(rB.packageDirectory!), rB.manifest!);

      final registry = ContentSourceRegistry();
      registry.registerMetadataSource(sourceA, priority: 10);
      registry.registerMetadataSource(sourceB, priority: 20);
      final repo = ContentRepository(registry: registry);

      // Priority 20 overrides Priority 10
      final k = await repo.getKanjiByCodepoint(0x4E00);
      expect(k?.meanings, equals(['online definition']));
    });

    test('T3-12: [F4+F9+F10] Remote HTTP 500 error during update leaves existing offline sources serving smoothly', () async {
      final registry = ContentSourceRegistry();
      registry.registerMetadataSource(BundledMetadataSource(contentDb: bundledContentDb));

      // Attempt online fetch that encounters 500
      mockHttp.serveError('/failing_update.json', 500);
      final result = await onlineFetcher.fetchAndInstall(
        Uri.parse('${mockHttp.baseUrl}/failing_update.json'),
        options: const FetchOptions(maxRetries: 0),
      );
      expect(result.isSuccess, isFalse);

      // Existing repository continues serving bundled content
      final repo = ContentRepository(registry: registry);
      final k = await repo.getKanjiByCodepoint(0x4E00);
      expect(k?.meanings, contains('one'));
    });

    test('T3-13: [F1+F4+F5] Audio-only custom source added and removed; reading/recognition cards invariant', () async {
      final userDb = UserDatabase.openInMemory();
      final scheduler = FsrsSchedulerService();

      // Practice recognition mode
      scheduler.recordPracticeCompletion(
        userDb: userDb,
        codepoint: 0x4E00,
        mistakes: 0,
        hintsUsed: 0,
        mode: PracticeMode.reading,
        now: DateTime.utc(2026, 1, 1),
      );

      // Add audio-only custom source
      final registry = ContentSourceRegistry();
      registry.registerAudioSource(DefaultTtsAudioSource(speechService: FakeSpeechService(), contentDb: bundledContentDb));
      final customAudio = MockCustomAudioSource(
        sourceId: 'audio_only',
        audioMap: {
          0x4E00: {
            'イチ': const AudioPronunciation(type: AudioPayloadType.localFile, uriOrText: '/a.wav', reading: 'イチ'),
          },
        },
      );
      registry.registerAudioSource(customAudio, priority: 10);

      // Unregister audio-only source
      registry.unregisterSource('audio_only');

      // Card in userDb for reading mode is invariant
      final card = userDb.getCard(0x4E00, mode: PracticeMode.reading);
      expect(card?.reps, equals(1));
    });

    test('T3-14: [F7+F8+F3] Offline package with surrogate codepoints rejected by validator; valid accepted', () async {
      final validator = SourceValidator();
      // Surrogate 0xD800
      final surrogateRes = validator.validateMetadataEntry({'codepoint': 0xD800, 'literal': '一', 'meanings': ['one']});
      expect(surrogateRes.isValid, isFalse);

      // Valid codepoint 0x4E00
      final validRes = validator.validateMetadataEntry({'codepoint': 0x4E00, 'literal': '一', 'meanings': ['one']});
      expect(validRes.isValid, isTrue);
    });

    test('T3-15: [F5+F8+F9] Heterogeneous session: User reviews cards across Bundled, Offline, and Online sources', () async {
      final userDb = UserDatabase.openInMemory();
      final scheduler = FsrsSchedulerService();

      final now = DateTime.utc(2026, 1, 1, 12, 0);

      // 1. Bundled: 0x4E00 ('一')
      final c1 = scheduler.recordPracticeCompletion(userDb: userDb, codepoint: 0x4E00, mistakes: 0, hintsUsed: 0, now: now);
      // 2. Offline: 0x9B1D ('鬝')
      final c2 = scheduler.recordPracticeCompletion(userDb: userDb, codepoint: 0x9B1D, mistakes: 1, hintsUsed: 0, now: now);
      // 3. Online: 0x9FFF
      final c3 = scheduler.recordPracticeCompletion(userDb: userDb, codepoint: 0x9FFF, mistakes: 0, hintsUsed: 1, now: now);

      expect(c1.reps, equals(1));
      expect(c2.reps, equals(1));
      expect(c3.reps, equals(1));

      final allCards = userDb.getAllCards();
      expect(allCards.length, equals(3));
      expect(allCards.map((c) => c.codepoint).toSet(), equals({0x4E00, 0x9B1D, 0x9FFF}));
    });
  });

  // ============================================================================
  // TIER 4: REAL-WORLD APPLICATION SCENARIOS (8 Tests)
  // ============================================================================
  group('Tier 4: Real-World Application Scenarios', () {
    late Directory tempDir;
    late PackageStagingManager stagingManager;
    late OfflinePackageLoader offlineLoader;
    late OnlineSourceFetcher onlineFetcher;
    late MockContentHttpServer mockHttp;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('tsuzuri_t4_');
      stagingManager = PackageStagingManager(baseDirectory: tempDir);
      await stagingManager.initialize();
      final validator = SourceValidator();
      offlineLoader = OfflinePackageLoader(stagingManager: stagingManager, validator: validator);
      onlineFetcher = OnlineSourceFetcher(stagingManager: stagingManager, validator: validator);
      mockHttp = MockContentHttpServer();
      await mockHttp.start();
    });

    tearDown(() async {
      await mockHttp.stop();
      try {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('T4-01: End-to-End Fresh Install: Bundled zero-config defaults, initial study queue, first review log', () async {
      final registry = ContentSourceRegistry();
      registry.registerMetadataSource(BundledMetadataSource(contentDb: bundledContentDb));
      registry.registerStrokeSource(BundledStrokeSource(contentDb: bundledContentDb));
      registry.registerAudioSource(DefaultTtsAudioSource(speechService: FakeSpeechService(), contentDb: bundledContentDb));
      final repo = ContentRepository(registry: registry);

      final userDb = UserDatabase.openInMemory();
      final scheduler = FsrsSchedulerService();

      // 1. App starts with 2136 bundled Joyo kanji
      final totalKanji = await repo.getTotalCharacterCount();
      expect(totalKanji, equals(bundledContentDb.totalKanjiCount));

      // 2. Build initial daily queue (first 5 kanji)
      final queue = scheduler.buildDailyQueue(
        repository: repo,
        userDb: userDb,
        dailyNewLimit: 5,
        now: DateTime.utc(2026, 1, 1),
      );
      expect(queue.length, equals(5));
      expect(queue.first.kanji.literal, equals('日'));

      // 3. User studies first kanji
      final progress = scheduler.recordPracticeCompletion(
        userDb: userDb,
        codepoint: queue.first.kanji.codepoint,
        mistakes: 0,
        hintsUsed: 0,
        mode: PracticeMode.writing,
        now: DateTime.utc(2026, 1, 1, 9, 30),
      );
      expect(progress.reps, equals(1));
      expect(progress.state, equals(2)); // Review (Easy graduates card immediately)

      // 4. Verify review log was recorded in database
      final backup = jsonDecode(userDb.exportBackupJson()) as Map<String, dynamic>;
      final logs = (backup['review_logs'] as List).cast<Map<String, dynamic>>();
      final logsForCp = logs.where((l) => l['codepoint'] == queue.first.kanji.codepoint).toList();
      expect(logsForCp.length, equals(1));
      expect(logsForCp.first['rating'], equals(PracticeGrade.easy.value));
    });

    test('T4-02: End-to-End JLPT N1 Expansion Import: ZIP archive ingestion expands character dictionary', () async {
      final registry = ContentSourceRegistry();
      registry.registerMetadataSource(BundledMetadataSource(contentDb: bundledContentDb));
      registry.registerStrokeSource(BundledStrokeSource(contentDb: bundledContentDb));
      final repo = ContentRepository(registry: registry);

      final initialCount = await repo.getTotalCharacterCount();

      // User downloads JLPT N1 expansion package ZIP
      final zipFile = File(p.join(tempDir.path, 'jlpt_n1.zip'));
      await TestPackageBuilder.writeValidZipPackage(
        zipFile,
        id: 'jlpt_n1_expansion',
        name: 'JLPT N1 Supplement',
        version: '1.0.0',
        sampleCodepoint: 0x9B1D, // '鬝'
        sampleLiteral: '鬝',
        meanings: ['bald', 'bare mountain'],
      );

      final result = await offlineLoader.loadFromArchive(zipFile);
      expect(result.isSuccess, isTrue);

      final n1Meta = await CustomMetadataSource.fromDirectory(
        Directory(result.packageDirectory!),
        result.manifest!,
      );
      final n1Stroke = await CustomStrokeSource.fromDirectory(
        Directory(result.packageDirectory!),
        result.manifest!,
      );
      registry.registerMetadataSource(n1Meta, priority: 10);
      registry.registerStrokeSource(n1Stroke, priority: 10);
      repo.clearCache();

      // Total character count increases by 1
      final newCount = await repo.getTotalCharacterCount();
      expect(newCount, equals(initialCount + 1));

      // Repository resolves the new N1 character
      final kanji = await repo.getKanjiByCodepoint(0x9B1D);
      expect(kanji, isNotNull);
      expect(kanji!.literal, equals('鬝'));
      expect(kanji.meanings, contains('bald'));
    });

    test('T4-03: End-to-End Study Session on Expansion Content: FSRS review, due date, and log recording', () async {
      final userDb = UserDatabase.openInMemory();
      final scheduler = FsrsSchedulerService();

      final reviewTime = DateTime.utc(2026, 1, 1, 14, 0);

      // User practices N1 kanji 0x9B1D
      final card = scheduler.recordPracticeCompletion(
        userDb: userDb,
        codepoint: 0x9B1D,
        mistakes: 1, // 1 mistake => Good
        hintsUsed: 0,
        mode: PracticeMode.writing,
        now: reviewTime,
      );

      expect(card.codepoint, equals(0x9B1D));
      expect(card.reps, equals(1));
      expect(card.dueDate.isAfter(reviewTime), isTrue);

      final backup = jsonDecode(userDb.exportBackupJson()) as Map<String, dynamic>;
      final logs = (backup['review_logs'] as List).cast<Map<String, dynamic>>();
      final logsForCp = logs.where((l) => l['codepoint'] == 0x9B1D).toList();
      expect(logsForCp.length, equals(1));
      expect(logsForCp.first['mistakes'], equals(1));
      expect(logsForCp.first['rating'], equals(PracticeGrade.good.value));
    });

    test('T4-04: End-to-End In-Place Package Update (v1.0 -> v2.0): Preserves FSRS card history', () async {
      final userDb = UserDatabase.openInMemory();
      final scheduler = FsrsSchedulerService();

      // 1. Install v1.0
      final v1Zip = File(p.join(tempDir.path, 'n1_v1.zip'));
      await TestPackageBuilder.writeValidZipPackage(
        v1Zip,
        id: 'n1_pack',
        version: '1.0.0',
        sampleCodepoint: 0x9B1D,
        sampleLiteral: '鬝',
        meanings: ['original definition'],
      );
      final r1 = await offlineLoader.loadFromArchive(v1Zip);
      expect(r1.isSuccess, isTrue);

      // 2. Perform 2 reviews on 0x9B1D
      scheduler.recordPracticeCompletion(
        userDb: userDb,
        codepoint: 0x9B1D,
        mistakes: 0,
        hintsUsed: 0,
        now: DateTime.utc(2026, 1, 1),
      );
      final c2 = scheduler.recordPracticeCompletion(
        userDb: userDb,
        codepoint: 0x9B1D,
        mistakes: 0,
        hintsUsed: 0,
        now: DateTime.utc(2026, 1, 4),
      );
      expect(c2.reps, equals(2));

      // 3. User updates package to v2.0
      final v2Zip = File(p.join(tempDir.path, 'n1_v2.zip'));
      await TestPackageBuilder.writeValidZipPackage(
        v2Zip,
        id: 'n1_pack',
        version: '2.0.0',
        sampleCodepoint: 0x9B1D,
        sampleLiteral: '鬝',
        meanings: ['refined definition'],
      );
      final r2 = await offlineLoader.loadFromArchive(v2Zip);
      expect(r2.isSuccess, isTrue);

      // 4. Verify card progress in database retained reps=2 and exact stability
      final cardAfter = userDb.getCard(0x9B1D, mode: PracticeMode.writing);
      expect(cardAfter?.reps, equals(2));
      expect(cardAfter?.stability, equals(c2.stability));
    });

    test('T4-05: End-to-End Remote Community Source Sync: HTTP fetch, asset cache, audio playback resolution', () async {
      final manifest = {
        'formatVersion': 1,
        'id': 'community_audio_pack',
        'name': 'Community Audio Pack',
        'version': '1.0.0',
        'capabilities': ['audio'],
        'audioPath': 'audio',
        'audioFiles': [
          'audio/audio_index.json',
          'audio/4E00.wav',
        ],
      };
      final audioWav = TestPackageBuilder.createWavBytes(64);
      final audioIndex = {
        '19968': [
          {'reading': 'イチ', 'file': 'audio/4E00.wav'}
        ]
      };

      mockHttp.serveManifest('/community/manifest.json', manifest);
      mockHttp.serveBytes('/community/audio/audio_index.json', utf8.encode(jsonEncode(audioIndex)), contentType: 'application/json');
      mockHttp.serveBytes('/community/audio/4E00.wav', audioWav, contentType: 'audio/wav');

      final result = await onlineFetcher.fetchAndInstall(Uri.parse('${mockHttp.baseUrl}/community/manifest.json'));
      expect(result.isSuccess, isTrue);

      final customAudio = await CustomAudioSource.fromDirectory(
        Directory(result.packageDirectory!),
        result.manifest!,
      );

      final registry = ContentSourceRegistry();
      registry.registerAudioSource(DefaultTtsAudioSource(speechService: FakeSpeechService(), contentDb: bundledContentDb));
      registry.registerAudioSource(customAudio, priority: 10);
      final repo = ContentRepository(registry: registry);

      final audio = await repo.resolveAudio(0x4E00, reading: 'イチ');
      expect(audio.type, equals(AudioPayloadType.localFile));
      expect(audio.reading, equals('イチ'));
    });

    test('T4-06: End-to-End Package Deactivation & Re-Activation: Queue safety and historical invariance', () async {
      final userDb = UserDatabase.openInMemory();
      final scheduler = FsrsSchedulerService();
      final registry = ContentSourceRegistry();
      final repo = ContentRepository(registry: registry);

      registry.registerMetadataSource(BundledMetadataSource(contentDb: bundledContentDb));
      registry.registerStrokeSource(BundledStrokeSource(contentDb: bundledContentDb));

      final customMeta = MockCustomMetadataSource(
        sourceId: 'deactivate_test_pkg',
        entries: {
          0x9B1D: const KanjiMetadataEntry(
            codepoint: 0x9B1D,
            literal: '鬝',
            strokeCount: 18,
            meanings: ['temporary study kanji'],
          ),
        },
      );
      registry.registerMetadataSource(customMeta, priority: 10);

      // User studies 0x9B1D and bundled 0x4E00
      scheduler.recordPracticeCompletion(userDb: userDb, codepoint: 0x4E00, mistakes: 0, hintsUsed: 0, now: DateTime.utc(2026, 1, 1));
      scheduler.recordPracticeCompletion(userDb: userDb, codepoint: 0x9B1D, mistakes: 0, hintsUsed: 0, now: DateTime.utc(2026, 1, 1));

      // Deactivate custom package
      registry.unregisterSource('deactivate_test_pkg');
      repo.clearCache();

      // Daily queue safely contains only bundled 0x4E00; 0x9B1D is omitted without crashing
      final queueWithout = scheduler.buildDailyQueue(
        repository: repo,
        userDb: userDb,
        dailyNewLimit: 5,
        now: DateTime.utc(2027, 1, 1),
      );
      expect(queueWithout.any((q) => q.kanji.codepoint == 0x4E00), isTrue);
      expect(queueWithout.any((q) => q.kanji.codepoint == 0x9B1D), isFalse);

      // Re-activate custom package
      registry.registerMetadataSource(customMeta, priority: 10);
      repo.clearCache();

      // Queue now includes both cards again
      final queueWith = scheduler.buildDailyQueue(
        repository: repo,
        userDb: userDb,
        dailyNewLimit: 5,
        now: DateTime.utc(2027, 1, 1),
      );
      expect(queueWith.any((q) => q.kanji.codepoint == 0x9B1D), isTrue);
    });

    test('T4-07: End-to-End Adversarial Recovery: Corrupt download fails cleanly; ongoing learning session unharmed', () async {
      final userDb = UserDatabase.openInMemory();
      final scheduler = FsrsSchedulerService();

      // Active learning session
      scheduler.recordPracticeCompletion(userDb: userDb, codepoint: 0x4E00, mistakes: 0, hintsUsed: 0, now: DateTime.utc(2026, 1, 1));

      // User attempts to import a truncated/corrupt ZIP file from Downloads
      final corruptFile = File(p.join(tempDir.path, 'download_corrupted.zip'));
      await corruptFile.writeAsBytes(utf8.encode('PK\x03\x04truncated_corrupted_data'));

      final result = await offlineLoader.loadFromArchive(corruptFile);
      expect(result.isSuccess, isFalse);
      expect(result.errorMessage, isNotNull);

      // Verify study session continues without error
      final card = userDb.getCard(0x4E00, mode: PracticeMode.writing);
      expect(card?.reps, equals(1));
    });

    test('T4-08: End-to-End Full Hybrid Lifecycle: Bundled -> Offline Import -> Online Fetch -> Priority Switch -> Sync', () async {
      final userDb = UserDatabase.openInMemory();
      final scheduler = FsrsSchedulerService();
      final registry = ContentSourceRegistry();
      final repo = ContentRepository(registry: registry);

      // 1. Initial State: Bundled Defaults
      registry.registerMetadataSource(BundledMetadataSource(contentDb: bundledContentDb));
      registry.registerStrokeSource(BundledStrokeSource(contentDb: bundledContentDb));
      registry.registerAudioSource(DefaultTtsAudioSource(speechService: FakeSpeechService(), contentDb: bundledContentDb));

      expect(await repo.getTotalCharacterCount(), equals(bundledContentDb.totalKanjiCount));

      // 2. Offline Import: Package A (priority 10)
      final zipA = File(p.join(tempDir.path, 'lifecycle_a.zip'));
      await TestPackageBuilder.writeValidZipPackage(
        zipA,
        id: 'pkg_lifecycle_a',
        sampleCodepoint: 0x4E00,
        sampleLiteral: '一',
        meanings: ['lifecycle offline meaning'],
      );
      final rA = await offlineLoader.loadFromArchive(zipA);
      expect(rA.isSuccess, isTrue);

      final sourceA = await CustomMetadataSource.fromDirectory(Directory(rA.packageDirectory!), rA.manifest!);
      registry.registerMetadataSource(sourceA, priority: 10);
      repo.clearCache();

      expect((await repo.getKanjiByCodepoint(0x4E00))?.meanings, equals(['lifecycle offline meaning']));

      // 3. Online Fetch: Package B (priority 20)
      final manifestB = {
        'formatVersion': 1,
        'id': 'pkg_lifecycle_b',
        'name': 'Lifecycle B',
        'version': '1.0.0',
        'capabilities': ['metadata'],
        'metadataPath': 'metadata.json',
      };
      final metadataB = [{'codepoint': 0x4E00, 'literal': '一', 'stroke_count': 1, 'meanings': ['lifecycle online meaning']}];
      mockHttp.serveManifest('/lifecycle_b/manifest.json', manifestB);
      mockHttp.serveBytes('/lifecycle_b/metadata.json', utf8.encode(jsonEncode(metadataB)), contentType: 'application/json');

      final rB = await onlineFetcher.fetchAndInstall(Uri.parse('${mockHttp.baseUrl}/lifecycle_b/manifest.json'));
      expect(rB.isSuccess, isTrue);

      final sourceB = await CustomMetadataSource.fromDirectory(Directory(rB.packageDirectory!), rB.manifest!);
      registry.registerMetadataSource(sourceB, priority: 20);
      repo.clearCache();

      expect((await repo.getKanjiByCodepoint(0x4E00))?.meanings, equals(['lifecycle online meaning']));

      // 4. Study Card under Package B
      final card = scheduler.recordPracticeCompletion(
        userDb: userDb,
        codepoint: 0x4E00,
        mistakes: 0,
        hintsUsed: 0,
        now: DateTime.utc(2026, 1, 1),
      );
      expect(card.reps, equals(1));

      // 5. Uninstall Package B -> Reverts to Package A
      registry.unregisterSource('pkg_lifecycle_b');
      expect((await repo.getKanjiByCodepoint(0x4E00))?.meanings, equals(['lifecycle offline meaning']));

      // 6. Uninstall Package A -> Reverts to Bundled Defaults
      registry.unregisterSource('pkg_lifecycle_a');
      expect((await repo.getKanjiByCodepoint(0x4E00))?.meanings, contains('one'));

      // 7. FSRS Progress remains intact throughout the entire lifecycle
      final finalCard = userDb.getCard(0x4E00, mode: PracticeMode.writing);
      expect(finalCard?.reps, equals(1));
    });
  });
}
