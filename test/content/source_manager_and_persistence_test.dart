import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_kanji_practice/src/content/contracts/kanji_audio_source.dart';
import 'package:offline_kanji_practice/src/content/ingestion/staging/package_staging_manager.dart';
import 'package:offline_kanji_practice/src/content/registry/content_repository.dart';
import 'package:offline_kanji_practice/src/content/registry/content_source_registry.dart';
import 'package:offline_kanji_practice/src/content/services/content_source_manager.dart';
import 'package:offline_kanji_practice/src/content/sources/bundled/bundled_metadata_source.dart';
import 'package:offline_kanji_practice/src/content/sources/bundled/bundled_stroke_source.dart';
import 'package:offline_kanji_practice/src/content/sources/bundled/default_tts_audio_source.dart';
import 'package:offline_kanji_practice/src/data/content_db.dart';
import 'package:offline_kanji_practice/src/data/models.dart';
import 'package:offline_kanji_practice/src/data/user_db.dart';
import 'package:offline_kanji_practice/src/domain/exercises/exercise_prompt.dart';
import 'package:offline_kanji_practice/src/domain/exercises/practice_configuration.dart';
import 'package:offline_kanji_practice/src/scheduling/fsrs_scheduler.dart';
import 'package:offline_kanji_practice/src/services/exercise_engine.dart';
import 'package:offline_kanji_practice/src/services/speech_service.dart';
import 'package:path/path.dart' as p;

import 'fixtures/mock_content_http_server.dart';
import 'fixtures/test_package_builder.dart';

void main() {
  HttpOverrides.global = null;

  late ContentDatabase contentDb;
  late Directory tempDir;
  late UserDatabase userDb;
  late FakeSpeechService fakeSpeech;
  late ContentSourceRegistry registry;
  late ContentRepository repository;
  late PackageStagingManager stagingManager;
  late ContentSourceManager manager;

  ContentSourceRegistry createAnchoredRegistry() {
    final reg = ContentSourceRegistry();
    reg.registerMetadataSource(BundledMetadataSource(contentDb: contentDb), priority: 0);
    reg.registerStrokeSource(BundledStrokeSource(contentDb: contentDb), priority: 0);
    reg.registerAudioSource(
      DefaultTtsAudioSource(speechService: fakeSpeech, contentDb: contentDb),
      priority: 0,
    );
    return reg;
  }

  setUpAll(() {
    HttpOverrides.global = null;
    contentDb = ContentDatabase.openFromFile(File('assets/db/kanji_content.db'));
  });

  tearDownAll(() {
    contentDb.close();
  });

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('tsuzuri_source_mgr_test_');
    userDb = await UserDatabase.openFromDirectory(tempDir);
    fakeSpeech = FakeSpeechService();
    registry = createAnchoredRegistry();
    repository = ContentRepository(registry: registry);
    stagingManager = PackageStagingManager(
      baseDirectory: Directory(p.join(tempDir.path, 'content_sources')),
    );
    manager = ContentSourceManager(
      registry: registry,
      userDb: userDb,
      stagingManager: stagingManager,
    );
  });

  tearDown(() async {
    repository.dispose();
    registry.dispose();
    userDb.close();
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('Schema v4 Persistence & ContentSourceManager Lifecycle', () {
    test('Schema v4 installs installed_sources table and survives JSON backup & restore', () {
      expect(userDb.schemaVersion, equals(4));

      userDb.upsertInstalledSource(
        InstalledSourceRecord(
          sourceId: 'jlpt_n1_sample',
          name: 'JLPT N1 Expansion',
          version: '1.2.0',
          originType: SourceOriginType.onlineUrl,
          originUri: 'https://example.com/n1/manifest.json',
          packageDir: '/tmp/packages/jlpt_n1_sample',
          capabilities: const ['metadata', 'strokes', 'audio'],
          priority: 20,
          enabled: true,
          installedAt: DateTime.utc(2026, 11, 10, 8, 0),
        ),
      );

      final backupJson = userDb.exportBackupJson();
      expect(backupJson, contains('"installed_sources"'));
      expect(backupJson, contains('jlpt_n1_sample'));

      final restoredDb = UserDatabase.openInMemory();
      addTearDown(restoredDb.close);
      restoredDb.importBackupJson(backupJson);

      final restored = restoredDb.getInstalledSources();
      expect(restored.length, equals(1));
      expect(restored.first.sourceId, equals('jlpt_n1_sample'));
      expect(restored.first.originType, equals(SourceOriginType.onlineUrl));
      expect(restored.first.originUri, equals('https://example.com/n1/manifest.json'));
      expect(restored.first.priority, equals(20));
      expect(restored.first.enabled, isTrue);
    });

    test('importArchiveFile installs ZIP pack, hydrates cleanly across simulated restart, and preserves FSRS on removal', () async {
      // Custom kanji not in bundled Joyo DB: 鬝 (0x9B1D)
      const customCodepoint = 0x9B1D;
      final archive = TestPackageBuilder.buildValidPackageArchive(
        id: 'rare_kanji_pack',
        name: 'Rare Kanji Pack',
        version: '1.0.0',
        includeMetadata: true,
        includeStrokes: true,
        includeAudio: true,
        sampleCodepoint: customCodepoint,
        sampleLiteral: '鬝',
        meanings: const ['depression_custom', 'melancholy_custom'],
        onyomi: const ['ウツ'],
        kunyomi: const ['うっ.する'],
      );
      final zipFile = File(p.join(tempDir.path, 'rare.zip'))
        ..writeAsBytesSync(ZipEncoder().encode(archive)!);

      final result = await manager.importArchiveFile(zipFile);
      expect(result.isSuccess, isTrue, reason: '${result.errorCode}: ${result.errorMessage}');
      expect(manager.getInstalledSources().length, equals(1));

      // Resolvable through live ContentRepository immediately
      final loaded = await repository.getKanjiByCodepoint(customCodepoint);
      expect(loaded, isNotNull);
      expect(loaded!.literal, equals('鬝'));
      expect(loaded.meanings, contains('depression_custom'));

      final resolvedAudio = await repository.resolveAudio(customCodepoint, reading: 'ウツ');
      expect(resolvedAudio.type, equals(AudioPayloadType.localFile));
      expect(File(resolvedAudio.uriOrText).existsSync(), isTrue);

      // Record FSRS review on the custom character
      final scheduler = FsrsSchedulerService();
      final card = scheduler.recordPracticeCompletion(
        userDb: userDb,
        codepoint: customCodepoint,
        mistakes: 0,
        hintsUsed: 0,
      );
      expect(card.reps, equals(1));

      // Simulate app restart: close DB, recreate registry/repo/manager, hydrateOnStartup()
      userDb.close();
      repository.dispose();
      registry.dispose();

      userDb = await UserDatabase.openFromDirectory(tempDir);
      registry = createAnchoredRegistry();
      repository = ContentRepository(registry: registry);
      manager = ContentSourceManager(
        registry: registry,
        userDb: userDb,
        stagingManager: stagingManager,
      );

      await manager.hydrateOnStartup();

      final postRestartKanji = await repository.getKanjiByCodepoint(customCodepoint);
      expect(postRestartKanji, isNotNull);
      expect(postRestartKanji!.meanings, contains('depression_custom'));

      // Disable custom source -> absent from active repo, FSRS DB row preserved
      await manager.setSourceEnabled('rare_kanji_pack', false);
      expect(await repository.getKanjiByCodepoint(customCodepoint), isNull);
      expect(userDb.getCard(customCodepoint)?.reps, equals(1));

      // Re-enable -> reappears cleanly
      await manager.setSourceEnabled('rare_kanji_pack', true);
      expect(await repository.getKanjiByCodepoint(customCodepoint), isNotNull);

      // Remove source completely -> files deleted, DB row removed, FSRS card still intact
      await manager.removeSource('rare_kanji_pack');
      expect(manager.getInstalledSources(), isEmpty);
      expect(await repository.getKanjiByCodepoint(customCodepoint), isNull);
      expect(Directory(p.join(stagingManager.packagesRoot.path, 'rare_kanji_pack')).existsSync(), isFalse);
      expect(userDb.getCard(customCodepoint)?.reps, equals(1));
    });

    test('moveSourcePriority swaps resolution precedence between multiple custom sources', () async {
      // Source A overrides U+4E00 (一) with meaning "uno"
      final zipA = File(p.join(tempDir.path, 'pack_a.zip'))
        ..writeAsBytesSync(
          ZipEncoder().encode(
            TestPackageBuilder.buildValidPackageArchive(
              id: 'pack_a',
              name: 'Pack A',
              version: '1.0.0',
              includeStrokes: false,
              includeAudio: false,
              sampleCodepoint: 0x4E00,
              sampleLiteral: '一',
              meanings: const ['uno'],
            ),
          )!,
        );
      // Source B overrides U+4E00 (一) with meaning "ichiban"
      final zipB = File(p.join(tempDir.path, 'pack_b.zip'))
        ..writeAsBytesSync(
          ZipEncoder().encode(
            TestPackageBuilder.buildValidPackageArchive(
              id: 'pack_b',
              name: 'Pack B',
              version: '1.0.0',
              includeStrokes: false,
              includeAudio: false,
              sampleCodepoint: 0x4E00,
              sampleLiteral: '一',
              meanings: const ['ichiban'],
            ),
          )!,
        );

      await manager.importArchiveFile(zipA); // priority 10
      await manager.importArchiveFile(zipB); // priority 20 (top)

      var resolved = await repository.getKanjiByCodepoint(0x4E00);
      expect(resolved!.meanings.first, equals('ichiban'));

      // Move Pack A up above Pack B
      await manager.moveSourcePriority('pack_a', moveUp: true);
      resolved = await repository.getKanjiByCodepoint(0x4E00);
      expect(resolved!.meanings.first, equals('uno'));
    });

    test('connectOnlineUrl and refreshOnlineSource fetch remote packages and upgrade cleanly', () async {
      final server = MockContentHttpServer();
      await server.start();
      addTearDown(server.stop);

      final v1Archive = ZipEncoder().encode(
        TestPackageBuilder.buildValidPackageArchive(
          id: 'remote_deck',
          name: 'Remote Community Deck',
          version: '1.0.0',
          includeStrokes: false,
          includeAudio: false,
          sampleCodepoint: 0x9B1D,
          sampleLiteral: '鬝',
          meanings: const ['gloom v1'],
        ),
      )!;
      server.serveManifest('/manifest.json', {
        'id': 'remote_deck',
        'name': 'Remote Community Deck',
        'version': '1.0.0',
        'capabilities': ['metadata'],
        'metadataPath': 'metadata.json',
        'archiveUrl': '/remote_v1.zip',
      });
      server.serveBytes('/remote_v1.zip', v1Archive);

      final connectRes = await manager.connectOnlineUrl(
        Uri.parse('${server.baseUrl}/manifest.json'),
      );
      expect(connectRes.isSuccess, isTrue, reason: '${connectRes.errorCode}: ${connectRes.errorMessage}');

      var kanji = await repository.getKanjiByCodepoint(0x9B1D);
      expect(kanji?.meanings.first, equals('gloom v1'));

      // Upgrade remote manifest to v2.0.0
      final v2Archive = ZipEncoder().encode(
        TestPackageBuilder.buildValidPackageArchive(
          id: 'remote_deck',
          name: 'Remote Community Deck',
          version: '2.0.0',
          includeStrokes: false,
          includeAudio: false,
          sampleCodepoint: 0x9B1D,
          sampleLiteral: '鬝',
          meanings: const ['gloom v2'],
        ),
      )!;
      server.serveManifest('/manifest.json', {
        'id': 'remote_deck',
        'name': 'Remote Community Deck',
        'version': '2.0.0',
        'capabilities': ['metadata'],
        'metadataPath': 'metadata.json',
        'archiveUrl': '/remote_v2.zip',
      });
      server.serveBytes('/remote_v2.zip', v2Archive);

      final refreshRes = await manager.refreshOnlineSource('remote_deck');
      expect(refreshRes.isSuccess, isTrue, reason: '${refreshRes.errorCode}: ${refreshRes.errorMessage}');
      expect(refreshRes.manifest!.version, equals('2.0.0'));

      kanji = await repository.getKanjiByCodepoint(0x9B1D);
      expect(kanji?.meanings.first, equals('gloom v2'));
    });

    test('ExerciseEngine.createSessionQueueAsync filters metadata-only kanji in Writing mode and attaches custom audio', () async {
      final zipFile = File(p.join(tempDir.path, 'meta_audio.zip'))
        ..writeAsBytesSync(
          ZipEncoder().encode(
            TestPackageBuilder.buildValidPackageArchive(
              id: 'audio_meta_pack',
              name: 'Audio + Meta Pack',
              version: '1.0.0',
              includeMetadata: true,
              includeStrokes: false,
              includeAudio: true,
              sampleCodepoint: 0x4E00, // 一 (strokes exist in bundled fallback!)
              sampleLiteral: '一',
              meanings: const ['custom one'],
            ),
          )!,
        );
      await manager.importArchiveFile(zipFile);

      // Build metadata-only kanji with empty strokes
      const noStrokeKanji = KanjiCharacter(
        codepoint: 0x9F8D,
        literal: '龍',
        strokeCount: 16,
        onyomi: ['リュウ'],
        kunyomi: ['たつ'],
        meanings: ['dragon'],
        strokes: [],
      );
      final bundledOne = await repository.getKanjiByCodepoint(0x4E00);
      expect(bundledOne, isNotNull);

      // 1. Writing queue safely filters out empty-stroke Kanji without throwing ArgumentError
      final writingQueue = await ExerciseEngine.createSessionQueueAsync(
        characters: [noStrokeKanji, bundledOne!],
        config: PracticePreset.audio.configuration,
        repository: repository,
        contentDb: contentDb,
      );
      expect(writingQueue.length, equals(1));
      expect(writingQueue.first.character.codepoint, equals(0x4E00));
      final audioPrompt = writingQueue.first.prompt as AudioPrompt;
      expect(audioPrompt.audioPronunciation, isNotNull);
      expect(audioPrompt.audioPronunciation!.type, equals(AudioPayloadType.localFile));

      // 2. Recognition queue includes metadata-only Kanji cleanly
      final recognitionQueue = await ExerciseEngine.createSessionQueueAsync(
        characters: [noStrokeKanji, bundledOne],
        config: PracticePreset.recMeaning.configuration,
        repository: repository,
        contentDb: contentDb,
      );
      expect(recognitionQueue.length, equals(2));
    });
  });
}
