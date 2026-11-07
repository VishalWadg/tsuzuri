import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sql;

import 'package:offline_kanji_practice/src/content/contracts/kanji_metadata_source.dart';
import 'package:offline_kanji_practice/src/content/ingestion/loaders/offline_package_loader.dart';
import 'package:offline_kanji_practice/src/content/ingestion/loaders/online_source_fetcher.dart';
import 'package:offline_kanji_practice/src/content/ingestion/models/ingestion_result.dart';
import 'package:offline_kanji_practice/src/content/ingestion/staging/package_staging_manager.dart';
import 'package:offline_kanji_practice/src/content/ingestion/validation/source_validator.dart';
import 'package:offline_kanji_practice/src/content/registry/content_repository.dart';
import 'package:offline_kanji_practice/src/content/registry/content_source_registry.dart';
import 'package:offline_kanji_practice/src/content/sources/bundled/bundled_metadata_source.dart';
import 'package:offline_kanji_practice/src/content/sources/bundled/bundled_stroke_source.dart';
import 'package:offline_kanji_practice/src/content/sources/bundled/default_tts_audio_source.dart';
import 'package:offline_kanji_practice/src/content/sources/custom/custom_metadata_source.dart';

import 'package:offline_kanji_practice/src/data/content_db.dart';
import 'package:offline_kanji_practice/src/data/models.dart';
import 'package:offline_kanji_practice/src/data/user_db.dart';
import 'package:offline_kanji_practice/src/scheduling/fsrs_scheduler.dart';
import 'package:offline_kanji_practice/src/services/speech_service.dart';

import 'fixtures/mock_content_http_server.dart';

class FakeSpeechService implements ISpeechService {
  @override
  Future<bool> isJapaneseVoiceAvailable() async => true;
  @override
  Future<void> speakJapanese(String text, {double rate = 1.0}) async {}
  @override
  Future<void> stop() async {}
}

List<int> createWavBytes(int length) {
  final bytes = Uint8List(length);
  // 'RIFF'
  bytes[0] = 0x52; bytes[1] = 0x49; bytes[2] = 0x46; bytes[3] = 0x46;
  final byteData = ByteData.sublistView(bytes);
  byteData.setUint32(4, length - 8, Endian.little);
  // 'WAVE'
  bytes[8] = 0x57; bytes[9] = 0x41; bytes[10] = 0x56; bytes[11] = 0x45;
  return bytes;
}

Uint8List createValidZipBytes({
  required String id,
  required String name,
  required String version,
  required int codepoint,
  required String literal,
  required String meaning,
}) {
  final archive = Archive();
  final manifestJson = jsonEncode({
    'id': id,
    'name': name,
    'version': version,
    'capabilities': ['metadata', 'strokes', 'audio'],
    'metadataPath': 'metadata.json',
    'strokesPath': 'strokes.json',
    'audioPath': 'audio',
  });
  archive.addFile(ArchiveFile.string('manifest.json', manifestJson));

  final metadataJson = jsonEncode([
    {
      'codepoint': codepoint,
      'literal': literal,
      'meanings': [meaning],
      'stroke_count': 1,
    }
  ]);
  archive.addFile(ArchiveFile.string('metadata.json', metadataJson));

  final strokesJson = jsonEncode({
    codepoint.toString(): [
      {
        'stroke_order': 1,
        'svg_path': 'M 10 50 L 90 50',
        'points': [
          {'x': 10.0, 'y': 50.0},
          {'x': 90.0, 'y': 50.0},
        ],
      }
    ]
  });
  archive.addFile(ArchiveFile.string('strokes.json', strokesJson));

  final audioBytes = createWavBytes(64);
  archive.addFile(ArchiveFile('audio/${codepoint.toRadixString(16).toUpperCase()}.wav', audioBytes.length, audioBytes));

  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

void main() {
  // Ensure HttpOverrides does not intercept real loopback sockets
  HttpOverrides.global = null;

  late Directory tempRootDir;
  late PackageStagingManager stagingManager;
  late SourceValidator validator;
  late OnlineSourceFetcher onlineFetcher;
  late OfflinePackageLoader offlineLoader;
  late MockContentHttpServer mockHttpServer;
  late ContentDatabase bundledDb;
  late FsrsSchedulerService scheduler;

  setUpAll(() {
    final dbFile = File('assets/db/kanji_content.db');
    expect(dbFile.existsSync(), isTrue);
    bundledDb = ContentDatabase.openFromFile(dbFile);
    scheduler = FsrsSchedulerService();
  });

  tearDownAll(() {
    bundledDb.close();
  });

  setUp(() async {
    tempRootDir = Directory.systemTemp.createTempSync('tsuzuri_m3_2_stress_');
    stagingManager = PackageStagingManager(baseDirectory: tempRootDir);
    await stagingManager.initialize();

    validator = SourceValidator();
    onlineFetcher = OnlineSourceFetcher(
      stagingManager: stagingManager,
      validator: validator,
    );
    offlineLoader = OfflinePackageLoader(
      stagingManager: stagingManager,
      validator: validator,
    );

    mockHttpServer = MockContentHttpServer();
    await mockHttpServer.start();
  });

  tearDown(() async {
    await mockHttpServer.stop();
    try {
      if (tempRootDir.existsSync()) {
        tempRootDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  // ==========================================================================
  // Group 1: Remote HTTP Fetching & Fault Injection Scenarios
  // ==========================================================================
  group('1. Remote HTTP Fetching & Fault Injection Stress Tests', () {
    test('1.1 HTTP 404 on Manifest: immediate failure without retries and cleans staging', () async {
      final notFoundUri = Uri.parse('${mockHttpServer.baseUrl}/non_existent_manifest.json');
      final result = await onlineFetcher.fetchAndInstall(notFoundUri);

      expect(result.isSuccess, isFalse);
      expect(result.errorCode, IngestionErrorCode.networkError);
      expect(result.errorMessage, contains('404'));
      expect(mockHttpServer.requestCount('/non_existent_manifest.json'), 1);

      // Verify staging directory is clean
      final stagingSubdirs = Directory(p.join(tempRootDir.path, '.staging')).listSync();
      expect(stagingSubdirs, isEmpty);
    });

    test('1.2 HTTP 404 on Archive Download: purges staging and returns networkError cleanly', () async {
      final manifestJson = {
        'id': 'missing_archive_pkg',
        'name': 'Missing Archive Pkg',
        'version': '1.0.0',
        'capabilities': ['metadata'],
        'archiveUrl': '/missing_archive.zip',
      };
      mockHttpServer.serveManifest('/manifest.json', manifestJson);

      final result = await onlineFetcher.fetchAndInstall(
        Uri.parse('${mockHttpServer.baseUrl}/manifest.json'),
      );

      expect(result.isSuccess, isFalse);
      expect(result.errorCode, IngestionErrorCode.networkError);
      expect(result.errorMessage, contains('404'));

      // Staging purged, target package not promoted
      final stagingSubdirs = Directory(p.join(tempRootDir.path, '.staging')).listSync();
      expect(stagingSubdirs, isEmpty);
      final promoted = Directory(p.join(tempRootDir.path, 'packages', 'missing_archive_pkg'));
      expect(promoted.existsSync(), isFalse);
    });

    test('1.3 HTTP 404 on Relative Asset (metadata): purges staging and returns networkError', () async {
      final manifestJson = {
        'id': 'missing_meta_pkg',
        'name': 'Missing Meta Pkg',
        'version': '1.0.0',
        'capabilities': ['metadata'],
        'metadataPath': 'metadata_404.json',
      };
      mockHttpServer.serveManifest('/manifest.json', manifestJson);

      final result = await onlineFetcher.fetchAndInstall(
        Uri.parse('${mockHttpServer.baseUrl}/manifest.json'),
      );

      expect(result.isSuccess, isFalse);
      expect(result.errorCode, IngestionErrorCode.networkError);
      expect(result.errorMessage, contains('404'));

      final stagingSubdirs = Directory(p.join(tempRootDir.path, '.staging')).listSync();
      expect(stagingSubdirs, isEmpty);
    });

    test('1.4 HTTP 500 on Manifest with Exponential Backoff Retries: verifies timing and retry count', () async {
      final requestTimestamps = <DateTime>[];
      mockHttpServer.onGet('/server_error.json', (req, res) {
        requestTimestamps.add(DateTime.now());
        res.statusCode = HttpStatus.internalServerError;
        res.write('Internal Server Error 500');
      });

      const initialDelay = Duration(milliseconds: 100);
      final result = await onlineFetcher.fetchAndInstall(
        Uri.parse('${mockHttpServer.baseUrl}/server_error.json'),
        options: const FetchOptions(
          maxRetries: 2,
          retryDelay: initialDelay,
        ),
      );

      expect(result.isSuccess, isFalse);
      expect(result.errorCode, IngestionErrorCode.networkError);
      expect(requestTimestamps.length, 3); // initial + 2 retries = 3

      // Verify exponential backoff intervals:
      // Retry 1 delay: >= 80ms
      // Retry 2 delay: >= 160ms
      final delay1 = requestTimestamps[1].difference(requestTimestamps[0]).inMilliseconds;
      final delay2 = requestTimestamps[2].difference(requestTimestamps[1]).inMilliseconds;
      expect(delay1, greaterThanOrEqualTo(80), reason: 'Delay 1 should be ~100ms');
      expect(delay2, greaterThanOrEqualTo(160), reason: 'Delay 2 should be ~200ms');
    });

    test('1.5 HTTP 500 Transient Error Recovery: succeeds when 500 clears on retry', () async {
      var callCount = 0;
      final validZip = createValidZipBytes(
        id: 'transient_recovery_pkg',
        name: 'Transient Recovery Pkg',
        version: '1.0.0',
        codepoint: 0x4E00,
        literal: '一',
        meaning: 'one',
      );

      mockHttpServer.onGet('/manifest.json', (req, res) {
        callCount++;
        if (callCount <= 2) {
          // Fail attempts 1 and 2 with 503 Service Unavailable
          res.statusCode = HttpStatus.serviceUnavailable;
          res.write('Service Unavailable');
        } else {
          // Succeed on attempt 3
          res.headers.contentType = ContentType.json;
          res.statusCode = HttpStatus.ok;
          res.write(jsonEncode({
            'id': 'transient_recovery_pkg',
            'name': 'Transient Recovery Pkg',
            'version': '1.0.0',
            'capabilities': ['metadata', 'strokes', 'audio'],
            'archiveUrl': '/archive.zip',
          }));
        }
      });
      mockHttpServer.serveBytes('/archive.zip', validZip);

      final result = await onlineFetcher.fetchAndInstall(
        Uri.parse('${mockHttpServer.baseUrl}/manifest.json'),
        options: const FetchOptions(
          maxRetries: 3,
          retryDelay: Duration(milliseconds: 50),
        ),
      );

      expect(result.isSuccess, isTrue);
      expect(result.sourceId, 'transient_recovery_pkg');
      expect(callCount, 3);
      expect(Directory(result.packageDirectory!).existsSync(), isTrue);
    });

    test('1.6 HTTP 500 on Archive Download with Retry Exhaustion: retries archive and fails cleanly', () async {
      mockHttpServer.serveManifest('/manifest.json', {
        'id': 'archive_500_pkg',
        'name': 'Archive 500 Pkg',
        'version': '1.0.0',
        'capabilities': ['metadata'],
        'archiveUrl': '/flaky_archive.zip',
      });
      mockHttpServer.serveError('/flaky_archive.zip', HttpStatus.internalServerError);

      final result = await onlineFetcher.fetchAndInstall(
        Uri.parse('${mockHttpServer.baseUrl}/manifest.json'),
        options: const FetchOptions(
          maxRetries: 2,
          retryDelay: Duration(milliseconds: 50),
        ),
      );

      expect(result.isSuccess, isFalse);
      expect(result.errorCode, IngestionErrorCode.networkError);
      expect(mockHttpServer.requestCount('/manifest.json'), 1);
      expect(mockHttpServer.requestCount('/flaky_archive.zip'), 3); // 1 initial + 2 retries

      // Staging purged
      final stagingSubdirs = Directory(p.join(tempRootDir.path, '.staging')).listSync();
      expect(stagingSubdirs, isEmpty);
    });

    test('1.7 Connection Refused / Socket Errors: cleanly returns networkError without crash', () async {
      // Connect to a closed port on loopback where nothing is listening
      final unusedServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final closedPort = unusedServer.port;
      await unusedServer.close(force: true);

      final unreachableUri = Uri.parse('http://127.0.0.1:$closedPort/manifest.json');
      final result = await onlineFetcher.fetchAndInstall(
        unreachableUri,
        options: const FetchOptions(
          maxRetries: 1,
          retryDelay: Duration(milliseconds: 50),
        ),
      );

      expect(result.isSuccess, isFalse);
      expect(result.errorCode, IngestionErrorCode.networkError);
      expect(result.errorMessage?.toLowerCase().contains('refused') ?? false, isTrue);
    });

    test('1.8 Network Receive Timeout on Slow Manifest: returns timeout and purges staging', () async {
      mockHttpServer.serveDelayed(
        '/slow_manifest.json',
        const Duration(seconds: 1),
      );

      final result = await onlineFetcher.fetchAndInstall(
        Uri.parse('${mockHttpServer.baseUrl}/slow_manifest.json'),
        options: const FetchOptions(
          connectTimeout: Duration(milliseconds: 200),
          receiveTimeout: Duration(milliseconds: 200),
          maxRetries: 0,
        ),
      );

      expect(result.isSuccess, isFalse);
      expect(result.errorCode, IngestionErrorCode.timeout);

      final stagingSubdirs = Directory(p.join(tempRootDir.path, '.staging')).listSync();
      expect(stagingSubdirs, isEmpty);
    });

    test('1.9 Network Receive Timeout on Slow Archive Download: returns timeout and purges staging', () async {
      mockHttpServer.serveManifest('/manifest.json', {
        'id': 'slow_archive_pkg',
        'name': 'Slow Archive Pkg',
        'version': '1.0.0',
        'capabilities': ['metadata'],
        'archiveUrl': '/slow_archive.zip',
      });
      mockHttpServer.serveDelayed(
        '/slow_archive.zip',
        const Duration(seconds: 1),
      );

      final result = await onlineFetcher.fetchAndInstall(
        Uri.parse('${mockHttpServer.baseUrl}/manifest.json'),
        options: const FetchOptions(
          connectTimeout: Duration(milliseconds: 300),
          receiveTimeout: Duration(milliseconds: 300),
          maxRetries: 0,
        ),
      );

      expect(result.isSuccess, isFalse);
      expect(result.errorCode, IngestionErrorCode.timeout);

      final stagingSubdirs = Directory(p.join(tempRootDir.path, '.staging')).listSync();
      expect(stagingSubdirs, isEmpty);
    });

    test('1.10 Premature Socket Close Mid-Download / Truncated Payload: handles premature EOF', () async {
      mockHttpServer.serveManifest('/manifest.json', {
        'id': 'truncated_pkg',
        'name': 'Truncated Pkg',
        'version': '1.0.0',
        'capabilities': ['metadata'],
        'archiveUrl': '/truncated_archive.zip',
      });

      // Premature close: declared 100000 bytes but closed after 500 bytes
      mockHttpServer.onGet('/truncated_archive.zip', (req, res) async {
        res.statusCode = HttpStatus.ok;
        res.headers.set(HttpHeaders.contentLengthHeader, '100000');
        res.add(Uint8List(500));
        await res.flush();
        try {
          await res.close();
        } catch (_) {}
      });

      final result = await onlineFetcher.fetchAndInstall(
        Uri.parse('${mockHttpServer.baseUrl}/manifest.json'),
        options: const FetchOptions(
          maxRetries: 0,
          retryDelay: Duration(milliseconds: 10),
        ),
      );

      expect(result.isSuccess, isFalse);
      expect(result.errorCode, IngestionErrorCode.networkError);

      final stagingSubdirs = Directory(p.join(tempRootDir.path, '.staging')).listSync();
      expect(stagingSubdirs, isEmpty);
    });

    test('1.11 Corrupted ZIP Payload over HTTP: returns corruptArchive and cleans staging', () async {
      mockHttpServer.serveManifest('/manifest.json', {
        'id': 'corrupted_zip_pkg',
        'name': 'Corrupted ZIP Pkg',
        'version': '1.0.0',
        'capabilities': ['metadata'],
        'archiveUrl': '/corrupted.zip',
      });
      mockHttpServer.serveBytes('/corrupted.zip', [0xFF, 0xFE, 0xFD, 0xFC, 0x00, 0x11, 0x22]);

      final result = await onlineFetcher.fetchAndInstall(
        Uri.parse('${mockHttpServer.baseUrl}/manifest.json'),
      );

      expect(result.isSuccess, isFalse);
      expect(result.errorCode, IngestionErrorCode.corruptArchive);

      final stagingSubdirs = Directory(p.join(tempRootDir.path, '.staging')).listSync();
      expect(stagingSubdirs, isEmpty);
    });

    test('1.12 Non-JSON / Corrupted Manifest over HTTP: returns invalidManifest', () async {
      mockHttpServer.onGet('/html_manifest.json', (req, res) {
        res.statusCode = HttpStatus.ok;
        res.headers.contentType = ContentType.html;
        res.write('<!DOCTYPE html><html><body>502 Bad Gateway</body></html>');
      });

      final result = await onlineFetcher.fetchAndInstall(
        Uri.parse('${mockHttpServer.baseUrl}/html_manifest.json'),
      );

      expect(result.isSuccess, isFalse);
      expect(result.errorCode, IngestionErrorCode.invalidManifest);
    });

    test('1.13 Oversized Payload exceeding maxPackageSizeBytes: halts download and rejects', () async {
      mockHttpServer.serveManifest('/manifest.json', {
        'id': 'huge_pkg',
        'name': 'Huge Pkg',
        'version': '1.0.0',
        'capabilities': ['metadata'],
        'archiveUrl': '/huge.zip',
      });
      // Serve 20 KB bytes
      mockHttpServer.serveBytes('/huge.zip', Uint8List(20 * 1024));

      final result = await onlineFetcher.fetchAndInstall(
        Uri.parse('${mockHttpServer.baseUrl}/manifest.json'),
        options: const FetchOptions(
          maxPackageSizeBytes: 4 * 1024, // 4 KB limit
          maxRetries: 0,
        ),
      );

      expect(result.isSuccess, isFalse);
      expect(result.errorCode, IngestionErrorCode.networkError);
      expect(result.errorMessage, contains('exceeded maximum allowed limit'));

      final stagingSubdirs = Directory(p.join(tempRootDir.path, '.staging')).listSync();
      expect(stagingSubdirs, isEmpty);
    });
  });

  // ==========================================================================
  // Group 2: User Progress & FSRS Invariance Under Package Operations
  // ==========================================================================
  group('2. User Progress Invariance & Practice Queue Compatibility', () {
    late UserDatabase userDb;
    late sql.Database rawDb;
    late ContentSourceRegistry registry;
    late ContentRepository repository;

    setUp(() async {
      userDb = await UserDatabase.openFromDirectory(tempRootDir);
      rawDb = sql.sqlite3.open(userDb.filePath!);

      registry = ContentSourceRegistry();
      registry.registerMetadataSource(BundledMetadataSource(contentDb: bundledDb), priority: 0);
      registry.registerStrokeSource(BundledStrokeSource(contentDb: bundledDb), priority: 0);
      registry.registerAudioSource(
        DefaultTtsAudioSource(speechService: FakeSpeechService(), contentDb: bundledDb),
        priority: 0,
      );
      repository = ContentRepository(registry: registry);
    });

    tearDown(() {
      rawDb.dispose();
      userDb.close();
    });

    test('2.1 Byte-for-byte invariance of user_progress.db across successful & failed ingestions', () async {
      final baseDate = DateTime.utc(2026, 11, 1, 10, 0);

      // Seed user progress with 5 cards, 10 review logs, and 5 writing metrics
      final testCodepoints = [0x4E00, 0x4E8C, 0x4E09, 0x9FA0, 0x9FA1];
      for (var i = 0; i < testCodepoints.length; i++) {
        final cp = testCodepoints[i];
        userDb.upsertCard(UserCardProgress(
          codepoint: cp,
          mode: PracticeMode.writing,
          dueDate: baseDate.add(Duration(days: i)),
          stability: 3.0 + i,
          difficulty: 4.0 + (i * 0.2),
          elapsedDays: i + 1,
          scheduledDays: i + 2,
          reps: i + 1,
          lapses: 0,
          state: 2,
          lastReview: baseDate.subtract(Duration(days: i)),
        ));

        userDb.insertReviewLog(
          codepoint: cp,
          mode: PracticeMode.writing,
          rating: 3,
          mistakes: 0,
          hintsUsed: 0,
          reviewedAt: baseDate.subtract(Duration(days: i)),
        );
        userDb.insertReviewLog(
          codepoint: cp,
          mode: PracticeMode.writing,
          rating: 4,
          mistakes: 0,
          hintsUsed: 0,
          reviewedAt: baseDate.subtract(Duration(days: i + 1)),
        );

        userDb.insertWritingMetric(
          codepoint: cp,
          exerciseType: 'writing',
          shapeScore: 0.9,
          orderErrors: 0,
          retries: 0,
          durationMs: 3000 + i * 50,
          recordedAt: baseDate.subtract(Duration(days: i)),
        );
      }

      // Snapshot all tables
      List<Map<String, dynamic>> snapshotTable(String table) {
        final rows = rawDb.select('SELECT * FROM $table ORDER BY 1, 2;');
        return rows.map((r) => Map<String, dynamic>.from(r)).toList();
      }

      final initialCards = snapshotTable('srs_cards');
      final initialLogs = snapshotTable('review_logs');
      final initialMetrics = snapshotTable('writing_metrics');

      expect(initialCards.length, 5);
      expect(initialLogs.length, 10);
      expect(initialMetrics.length, 5);

      void assertDbUntouched(String actionName) {
        final currentCards = snapshotTable('srs_cards');
        final currentLogs = snapshotTable('review_logs');
        final currentMetrics = snapshotTable('writing_metrics');

        expect(currentCards, equals(initialCards), reason: '$actionName mutated srs_cards');
        expect(currentLogs, equals(initialLogs), reason: '$actionName mutated review_logs');
        expect(currentMetrics, equals(initialMetrics), reason: '$actionName mutated writing_metrics');
      }

      // Action 1: Ingest valid offline ZIP
      final validZipBytes = createValidZipBytes(
        id: 'valid_pkg_1',
        name: 'Valid Pkg 1',
        version: '1.0.0',
        codepoint: 0x4E00,
        literal: '一',
        meaning: 'one custom',
      );
      final validZipFile = File(p.join(tempRootDir.path, 'valid1.zip'));
      await validZipFile.writeAsBytes(validZipBytes);
      final res1 = await offlineLoader.loadFromArchive(validZipFile);
      expect(res1.isSuccess, isTrue);
      assertDbUntouched('Valid ZIP ingestion');

      // Action 2: Ingest failing Zip-Slip exploit archive
      final exploitArchive = Archive();
      exploitArchive.addFile(ArchiveFile.string('manifest.json', jsonEncode({
        'id': 'exploit_pkg',
        'name': 'Exploit',
        'version': '1.0.0',
        'capabilities': ['metadata'],
      })));
      exploitArchive.addFile(ArchiveFile.string('../../system.txt', 'pwned'));
      final exploitBytes = ZipEncoder().encode(exploitArchive)!;
      final exploitFile = File(p.join(tempRootDir.path, 'exploit.zip'));
      await exploitFile.writeAsBytes(exploitBytes);
      final res2 = await offlineLoader.loadFromArchive(exploitFile);
      expect(res2.isSuccess, isFalse);
      assertDbUntouched('Zip-Slip ingestion');

      // Action 3: Ingest failing online package (HTTP 500)
      mockHttpServer.serveError('/failing_manifest.json', 500);
      final res3 = await onlineFetcher.fetchAndInstall(
        Uri.parse('${mockHttpServer.baseUrl}/failing_manifest.json'),
        options: const FetchOptions(maxRetries: 0),
      );
      expect(res3.isSuccess, isFalse);
      assertDbUntouched('HTTP 500 fetch');

      // Action 4: Ingest failing online package (HTTP 404)
      final res4 = await onlineFetcher.fetchAndInstall(
        Uri.parse('${mockHttpServer.baseUrl}/does_not_exist.json'),
      );
      expect(res4.isSuccess, isFalse);
      assertDbUntouched('HTTP 404 fetch');

      // Action 5: Ingest package upgrade v1 -> v2
      final v2ZipBytes = createValidZipBytes(
        id: 'valid_pkg_1',
        name: 'Valid Pkg 1',
        version: '2.0.0',
        codepoint: 0x4E00,
        literal: '一',
        meaning: 'one custom v2',
      );
      final v2ZipFile = File(p.join(tempRootDir.path, 'valid1_v2.zip'));
      await v2ZipFile.writeAsBytes(v2ZipBytes);
      final res5 = await offlineLoader.loadFromArchive(v2ZipFile);
      expect(res5.isSuccess, isTrue);
      assertDbUntouched('Package upgrade v1 -> v2');
    });

    test('2.2 Missing/unsupported custom Kanji in practice queue safely skipped without crash or DB corruption', () async {
      final now = DateTime.utc(2026, 11, 5, 12, 0);

      // Seed 2 bundled cards and 2 custom cards (all due before `now`)
      const bundledCp1 = 0x4E00; // '一'
      const bundledCp2 = 0x4E8C; // '二'
      const missingCustomCp1 = 0x9FA0;
      const missingCustomCp2 = 0x9FA1;

      for (final cp in [bundledCp1, bundledCp2, missingCustomCp1, missingCustomCp2]) {
        userDb.upsertCard(UserCardProgress(
          codepoint: cp,
          mode: PracticeMode.writing,
          dueDate: now.subtract(const Duration(days: 1)), // Due!
          stability: 5.0,
          difficulty: 3.5,
          elapsedDays: 5,
          scheduledDays: 5,
          reps: 3,
          lapses: 0,
          state: 2,
          lastReview: now.subtract(const Duration(days: 5)),
        ));
      }

      // Snapshot userDb state
      final snapCard1 = userDb.getCard(missingCustomCp1)!;
      final snapCard2 = userDb.getCard(missingCustomCp2)!;

      // Ensure NO custom sources are registered in repository
      expect(registry.activeMetadataSources.length, 1);
      expect(registry.activeMetadataSources.first.isBundledDefault, isTrue);

      // 1. Build asynchronous daily queue
      final asyncQueue = await scheduler.buildDailyQueueAsync(
        repository: repository,
        userDb: userDb,
        dailyNewLimit: 5,
        now: now,
      );
      final asyncCodepoints = asyncQueue.map((q) => q.kanji.codepoint).toSet();
      expect(asyncCodepoints.contains(missingCustomCp1), isFalse, reason: 'Missing 0x9FA0 must be skipped in async queue');
      expect(asyncCodepoints.contains(missingCustomCp2), isFalse, reason: 'Missing 0x9FA1 must be skipped in async queue');
      expect(asyncCodepoints.contains(bundledCp1), isTrue, reason: 'Bundled card 1 must appear');
      expect(asyncCodepoints.contains(bundledCp2), isTrue, reason: 'Bundled card 2 must appear');

      // 2. Build synchronous daily queue
      final syncQueue = scheduler.buildDailyQueue(
        repository: repository,
        userDb: userDb,
        dailyNewLimit: 5,
        now: now,
      );
      final syncCodepoints = syncQueue.map((q) => q.kanji.codepoint).toSet();
      expect(syncCodepoints.contains(missingCustomCp1), isFalse, reason: 'Missing 0x9FA0 must be skipped in sync queue');
      expect(syncCodepoints.contains(missingCustomCp2), isFalse, reason: 'Missing 0x9FA1 must be skipped in sync queue');
      expect(syncCodepoints.contains(bundledCp1), isTrue);
      expect(syncCodepoints.contains(bundledCp2), isTrue);

      // 3. Complete review for bundled card and verify FSRS progresses
      scheduler.recordPracticeCompletion(
        userDb: userDb,
        codepoint: bundledCp1,
        mistakes: 0,
        hintsUsed: 0,
        now: now,
      );

      final bundledAfter = userDb.getCard(bundledCp1)!;
      expect(bundledAfter.reps, 4);
      expect(bundledAfter.stability, greaterThan(5.0));

      // 4. Verify missing cards in userDb are 100% untouched
      final missing1After = userDb.getCard(missingCustomCp1)!;
      final missing2After = userDb.getCard(missingCustomCp2)!;

      expect(missing1After.stability, equals(snapCard1.stability));
      expect(missing1After.difficulty, equals(snapCard1.difficulty));
      expect(missing1After.reps, equals(snapCard1.reps));
      expect(missing1After.dueDate.toIso8601String(), equals(snapCard1.dueDate.toIso8601String()));

      expect(missing2After.stability, equals(snapCard2.stability));
      expect(missing2After.difficulty, equals(snapCard2.difficulty));
      expect(missing2After.reps, equals(snapCard2.reps));
      expect(missing2After.dueDate.toIso8601String(), equals(snapCard2.dueDate.toIso8601String()));

      // 5. Now register a custom source for missingCustomCp1
      final customMeta = CustomMetadataSource(
        sourceId: 'custom_restored_pkg',
        displayName: 'Restored Package',
        version: '1.0.0',
        entries: {
          missingCustomCp1: const KanjiMetadataEntry(
            codepoint: missingCustomCp1,
            literal: '龠',
            strokeCount: 17,
            meanings: ['flute / measurement'],
          ),
        },
      );
      registry.registerMetadataSource(customMeta, priority: 10);
      repository.clearCache();

      // Next async queue build immediately restores missingCustomCp1 at its scheduled due date!
      final restoredQueue = await scheduler.buildDailyQueueAsync(
        repository: repository,
        userDb: userDb,
        dailyNewLimit: 0,
        now: now,
      );
      final restoredCodepoints = restoredQueue.map((q) => q.kanji.codepoint).toSet();
      expect(restoredCodepoints.contains(missingCustomCp1), isTrue);
      expect(restoredCodepoints.contains(missingCustomCp2), isFalse); // cp2 still missing

      final restoredItem = restoredQueue.firstWhere((q) => q.kanji.codepoint == missingCustomCp1);
      expect(restoredItem.isNew, isFalse);
      expect(restoredItem.existingProgress?.stability, equals(snapCard1.stability));
      expect(restoredItem.existingProgress?.reps, equals(snapCard1.reps));
    });

    test('2.3 Adversarial Exposure: CustomMetadataSource lacks public synchronous entries/getMetadataSync', () async {
      final customMeta = CustomMetadataSource(
        sourceId: 'sync_test_pkg',
        displayName: 'Sync Test Package',
        version: '1.0.0',
        entries: {
          0x9FA0: const KanjiMetadataEntry(
            codepoint: 0x9FA0,
            literal: '龠',
            strokeCount: 17,
            meanings: ['flute'],
          ),
        },
      );

      // Asynchronous getMetadata works as expected
      final asyncEntry = await customMeta.getMetadata(0x9FA0);
      expect(asyncEntry, isNotNull);
      expect(asyncEntry?.literal, '龠');

      // BUT duck-typing query for synchronous getMetadataSync or entries fails
      final dynamic dynSource = customMeta;
      KanjiMetadataEntry? syncEntry;
      try {
        syncEntry = dynSource.getMetadataSync(0x9FA0) as KanjiMetadataEntry?;
      } catch (_) {}

      Map<dynamic, dynamic>? exposedEntries;
      try {
        exposedEntries = dynSource.entries as Map<dynamic, dynamic>?;
      } catch (_) {}

      // Document whether synchronous duck typing succeeds or fails:
      // In current worker implementation, entries is private (_entries) and getMetadataSync is unexposed.
      // This documents the finding empirically.
      final hasSyncSupport = syncEntry != null || exposedEntries != null;
      expect(hasSyncSupport, isFalse,
          reason: 'CustomMetadataSource encapsulates _entries privately without exposing entries getter or getMetadataSync');
    });

    test('2.4 Synchronous vs Asynchronous Queue Discrepancy on CustomMetadataSource', () async {
      final now = DateTime.utc(2026, 11, 5, 12, 0);
      const customCp = 0x9FA0;

      // Seed a due card for customCp
      userDb.upsertCard(UserCardProgress(
        codepoint: customCp,
        mode: PracticeMode.writing,
        dueDate: now.subtract(const Duration(days: 1)),
        stability: 5.0,
        difficulty: 3.5,
        elapsedDays: 5,
        scheduledDays: 5,
        reps: 3,
        lapses: 0,
        state: 2,
        lastReview: now.subtract(const Duration(days: 5)),
      ));

      // Register custom metadata source
      final customMeta = CustomMetadataSource(
        sourceId: 'custom_pkg',
        displayName: 'Custom Package',
        version: '1.0.0',
        entries: {
          customCp: const KanjiMetadataEntry(
            codepoint: customCp,
            literal: '龠',
            strokeCount: 17,
            meanings: ['flute'],
          ),
        },
      );
      registry.registerMetadataSource(customMeta, priority: 10);
      repository.clearCache();

      // 1. Asynchronous queue: successfully resolves customCp!
      final asyncQueue = await scheduler.buildDailyQueueAsync(
        repository: repository,
        userDb: userDb,
        dailyNewLimit: 0,
        now: now,
      );
      expect(asyncQueue.any((q) => q.kanji.codepoint == customCp), isTrue,
          reason: 'buildDailyQueueAsync succeeds via async registry.queryMetadata');

      // Clear cache to simulate cold-start synchronous resolution (e.g. on fresh app launch)
      repository.clearCache();

      // 2. Synchronous queue: demonstrates failure to resolve customCp on cold cache due to unexposed _entries!
      final syncQueue = scheduler.buildDailyQueue(
        repository: repository,
        userDb: userDb,
        dailyNewLimit: 0,
        now: now,
      );
      final syncHasCard = syncQueue.any((q) => q.kanji.codepoint == customCp);
      expect(syncHasCard, isFalse,
          reason: 'Cold-cache synchronous queue omits custom cards because CustomMetadataSource encapsulates _entries privately');
    });
  });
}
