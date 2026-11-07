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

void main() {
  late Directory tempRootDir;
  late PackageStagingManager stagingManager;
  late SourceValidator validator;
  late OfflinePackageLoader offlineLoader;
  late OnlineSourceFetcher onlineFetcher;
  late MockContentHttpServer mockHttpServer;

  // Fake audio headers
  List<int> createWavBytes(int length) {
    final bytes = Uint8List(length);
    // 'RIFF'
    bytes[0] = 0x52; bytes[1] = 0x49; bytes[2] = 0x46; bytes[3] = 0x46;
    // Length in header
    final byteData = ByteData.sublistView(bytes);
    byteData.setUint32(4, length - 8, Endian.little);
    // 'WAVE'
    bytes[8] = 0x57; bytes[9] = 0x41; bytes[10] = 0x56; bytes[11] = 0x45;
    return bytes;
  }

  List<int> createMp3Bytes(int length) {
    final bytes = Uint8List(length);
    // 'ID3'
    bytes[0] = 0x49; bytes[1] = 0x44; bytes[2] = 0x33;
    bytes[3] = 0x03; // version
    return bytes;
  }

  setUp(() async {
    tempRootDir = Directory.systemTemp.createTempSync('tsuzuri_m3_test_');
    stagingManager = PackageStagingManager(baseDirectory: tempRootDir);
    await stagingManager.initialize();

    validator = SourceValidator();
    offlineLoader = OfflinePackageLoader(
      stagingManager: stagingManager,
      validator: validator,
    );
    onlineFetcher = OnlineSourceFetcher(
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
  // Group 1: SourceManifest and SemVer Validation
  // ==========================================================================
  group('1. SourceManifest and SemVer Validation', () {
    test('1.1 Valid manifest parses from JSON and serializes to JSON', () {
      final json = {
        'formatVersion': 1,
        'id': 'custom_n5',
        'name': 'Custom N5 Expansion',
        'version': '1.2.3',
        'author': 'Tsuzuri Team',
        'description': 'Test expansion package',
        'capabilities': ['metadata', 'strokes', 'audio'],
        'metadataPath': 'metadata.json',
        'strokesPath': 'strokes.json',
        'audioPath': 'audio',
      };

      final manifest = SourceManifest.fromJson(json);
      expect(manifest.id, 'custom_n5');
      expect(manifest.name, 'Custom N5 Expansion');
      expect(manifest.version, '1.2.3');
      expect(manifest.capabilities, {
        SourceCapability.metadata,
        SourceCapability.strokes,
        SourceCapability.audio,
      });

      final serialized = manifest.toJson();
      expect(serialized['id'], 'custom_n5');
      expect(serialized['version'], '1.2.3');
    });

    test('1.2 SemVer 2.0.0 enforces strict version format', () {
      expect(SourceManifest.isValidSemVer('1.0.0'), isTrue);
      expect(SourceManifest.isValidSemVer('2.1.0-alpha.1'), isTrue);
      expect(SourceManifest.isValidSemVer('1.0.0+build2026'), isTrue);

      // Invalid semver
      expect(SourceManifest.isValidSemVer('v1.0.0'), isFalse); // 'v' prefix
      expect(SourceManifest.isValidSemVer('01.0.0'), isFalse); // leading zero
      expect(SourceManifest.isValidSemVer('1.0'), isFalse); // missing patch
      expect(SourceManifest.isValidSemVer('beta'), isFalse);
    });

    test('1.3 Manifest rejects invalid IDs, missing required fields, or unsupported versions', () {
      // Invalid ID
      expect(SourceManifest.isValidId('Custom N5'), isFalse); // spaces / uppercase
      expect(SourceManifest.isValidId('../../evil'), isFalse); // traversal

      // Missing required field 'name'
      expect(
        () => SourceManifest.fromJson({
          'id': 'test_pkg',
          'version': '1.0.0',
          'capabilities': ['metadata'],
        }),
        throwsA(isA<FormatException>()),
      );

      // Unsupported formatVersion
      expect(
        () => SourceManifest.fromJson({
          'formatVersion': 2,
          'id': 'test_pkg',
          'name': 'Test',
          'version': '1.0.0',
          'capabilities': ['metadata'],
        }),
        throwsA(isA<FormatException>()),
      );

      // Empty capabilities
      expect(
        () => SourceManifest.fromJson({
          'id': 'test_pkg',
          'name': 'Test',
          'version': '1.0.0',
          'capabilities': <String>[],
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });

  // ==========================================================================
  // Group 2: ZipSlipGuard 6-Layer Path Traversal Defense
  // ==========================================================================
  group('2. ZipSlipGuard Path Traversal Defense', () {
    test('2.1 Resolves safe relative path strictly within sandbox destination', () {
      final safe = ZipSlipGuard.resolveAndVerifyEntry(tempRootDir.path, 'data/metadata.json');
      expect(p.isWithin(tempRootDir.path, safe), isTrue);
      expect(ZipSlipGuard.isPathSafe(tempRootDir.path, 'data/metadata.json'), isTrue);
    });

    test('2.2 Rejects relative traversal attempts (../../ and ..\\..\\)', () {
      expect(
        () => ZipSlipGuard.resolveAndVerifyEntry(tempRootDir.path, '../../evil.dart'),
        throwsA(isA<SecurityException>()),
      );
      expect(ZipSlipGuard.isPathSafe(tempRootDir.path, '../../evil.dart'), isFalse);

      expect(
        () => ZipSlipGuard.resolveAndVerifyEntry(tempRootDir.path, '..\\..\\evil.bat'),
        throwsA(isA<SecurityException>()),
      );
      expect(ZipSlipGuard.isPathSafe(tempRootDir.path, '..\\..\\evil.bat'), isFalse);
    });

    test('2.3 Rejects directory boundary escape via prefix matching flaws', () {
      // e.g. destDir is /staging/pkg, entry attempts /staging/pkg_evil/payload.sh
      expect(
        () => ZipSlipGuard.resolveAndVerifyEntry(tempRootDir.path, '../staging_evil/payload.sh'),
        throwsA(isA<SecurityException>()),
      );
    });

    test('2.4 Rejects absolute paths and drive letters', () {
      expect(
        () => ZipSlipGuard.resolveAndVerifyEntry(tempRootDir.path, '/etc/passwd'),
        throwsA(isA<SecurityException>()),
      );
      expect(
        () => ZipSlipGuard.resolveAndVerifyEntry(tempRootDir.path, 'C:\\Windows\\evil.dll'),
        throwsA(isA<SecurityException>()),
      );
    });

    test('2.5 Rejects symbolic links and null bytes', () {
      expect(
        () => ZipSlipGuard.resolveAndVerifyEntry(tempRootDir.path, 'symlink_target', isSymbolicLink: true),
        throwsA(isA<SecurityException>()),
      );
      expect(
        () => ZipSlipGuard.resolveAndVerifyEntry(tempRootDir.path, 'file\x00.txt'),
        throwsA(isA<SecurityException>()),
      );
    });

    test('2.6 Resource limits reject excessive entry counts or uncompressed sizes', () {
      expect(
        () => ZipSlipGuard.verifyResourceLimits(
          entryCount: 5001,
          totalUncompressedBytes: 1000,
        ),
        throwsA(isA<SecurityException>()),
      );

      expect(
        () => ZipSlipGuard.verifyResourceLimits(
          entryCount: 10,
          totalUncompressedBytes: 300 * 1024 * 1024, // > 250 MB
        ),
        throwsA(isA<SecurityException>()),
      );
    });
  });

  // ==========================================================================
  // Group 3: SourceValidator Integrity and Bounds Checks
  // ==========================================================================
  group('3. SourceValidator Integrity and Bounds Checks', () {
    test('3.1 Codepoint validation accepts valid scalars and rejects surrogates / out of bounds', () {
      // Valid boundary codepoint
      expect(
        validator.validateMetadataEntry({
          'codepoint': 0x4E00,
          'literal': '一',
          'meanings': ['one'],
          'stroke_count': 1,
        }).isValid,
        isTrue,
      );

      // Max Unicode scalar (0x10FFFF)
      expect(
        validator.validateMetadataEntry({
          'codepoint': 0x10FFFF,
          'literal': String.fromCharCode(0x10FFFF),
          'meanings': ['max scalar'],
          'stroke_count': 1,
        }).isValid,
        isTrue,
      );

      // Astral plane ideograph U+2000B (𠀋)
      expect(
        validator.validateMetadataEntry({
          'codepoint': 0x2000B,
          'literal': String.fromCharCode(0x2000B),
          'meanings': ['ancient ideograph'],
          'stroke_count': 4,
        }).isValid,
        isTrue,
      );

      // Codepoint 0 (NUL) rejected
      final zeroRes = validator.validateMetadataEntry({
        'codepoint': 0,
        'literal': '\x00',
        'meanings': ['zero'],
        'stroke_count': 1,
      });
      expect(zeroRes.isValid, isFalse);
      expect(zeroRes.errorCode, IngestionErrorCode.invalidCodepoint);

      // Negative codepoint rejected
      final negRes = validator.validateMetadataEntry({
        'codepoint': -1,
        'literal': '',
        'meanings': ['neg'],
        'stroke_count': 1,
      });
      expect(negRes.isValid, isFalse);
      expect(negRes.errorCode, IngestionErrorCode.invalidCodepoint);

      // Out of bounds codepoint 0x110000 rejected
      final oobRes = validator.validateMetadataEntry({
        'codepoint': 0x110000,
        'literal': '',
        'meanings': ['oob'],
        'stroke_count': 1,
      });
      expect(oobRes.isValid, isFalse);
      expect(oobRes.errorCode, IngestionErrorCode.invalidCodepoint);

      // Surrogate codepoints (0xD800 and 0xDFFF) rejected
      final highSurrogateRes = validator.validateMetadataEntry({
        'codepoint': 0xD800,
        'literal': '',
        'meanings': ['surrogate'],
        'stroke_count': 1,
      });
      expect(highSurrogateRes.isValid, isFalse);
      expect(highSurrogateRes.errorCode, IngestionErrorCode.invalidCodepoint);

      final lowSurrogateRes = validator.validateMetadataEntry({
        'codepoint': 0xDFFF,
        'literal': '',
        'meanings': ['surrogate'],
        'stroke_count': 1,
      });
      expect(lowSurrogateRes.isValid, isFalse);
      expect(lowSurrogateRes.errorCode, IngestionErrorCode.invalidCodepoint);
    });

    test('3.2 Literal glyph and meanings consistency checks', () {
      // Literal mismatch (literal does not match codepoint)
      final mismatchRes = validator.validateMetadataEntry({
        'codepoint': 0x4E00,
        'literal': '二', // 0x4E8C != 0x4E00
        'meanings': ['one'],
        'stroke_count': 1,
      });
      expect(mismatchRes.isValid, isFalse);
      expect(mismatchRes.errorCode, IngestionErrorCode.schemaMismatch);

      // Empty meanings list rejected
      final emptyMeaningsRes = validator.validateMetadataEntry({
        'codepoint': 0x4E00,
        'literal': '一',
        'meanings': <String>[],
        'stroke_count': 1,
      });
      expect(emptyMeaningsRes.isValid, isFalse);
      expect(emptyMeaningsRes.errorCode, IngestionErrorCode.schemaMismatch);

      // Blank meanings rejected
      final blankMeaningsRes = validator.validateMetadataEntry({
        'codepoint': 0x4E00,
        'literal': '一',
        'meanings': ['   ', ''],
        'stroke_count': 1,
      });
      expect(blankMeaningsRes.isValid, isFalse);
      expect(blankMeaningsRes.errorCode, IngestionErrorCode.schemaMismatch);
    });

    test('3.3 Stroke validation rejects count 0, count > 64, corrupted 400-byte blobs, and empty SVG', () {
      // Stroke count 0
      final zeroStrokeRes = validator.validateStrokeData(
        codepoint: 0x4E00,
        rawStrokes: [],
      );
      expect(zeroStrokeRes.isValid, isFalse);
      expect(zeroStrokeRes.errorCode, IngestionErrorCode.invalidStrokeData);

      // Stroke count > 64
      final excessiveStrokes = List.generate(
        65,
        (i) => {'svg_path': 'M 10 10 L 20 20'},
      );
      final excessiveRes = validator.validateStrokeData(
        codepoint: 0x4E00,
        rawStrokes: excessiveStrokes,
      );
      expect(excessiveRes.isValid, isFalse);
      expect(excessiveRes.errorCode, IngestionErrorCode.invalidStrokeData);

      // Truncated blob (392 bytes instead of 400)
      final truncatedBlob = Uint8List(392);
      final blobRes = validator.validatePointsBlob(truncatedBlob);
      expect(blobRes.isValid, isFalse);
      expect(blobRes.errorCode, IngestionErrorCode.invalidStrokeData);

      // Corrupted blob with NaN
      final nanBlob = Uint8List(400);
      final byteData = ByteData.sublistView(nanBlob);
      byteData.setFloat32(0, double.nan, Endian.little);
      final nanRes = validator.validatePointsBlob(nanBlob);
      expect(nanRes.isValid, isFalse);
      expect(nanRes.errorCode, IngestionErrorCode.invalidStrokeData);

      // Valid 400-byte blob with finite numbers
      final validBlob = Uint8List(400);
      expect(validator.validatePointsBlob(validBlob).isValid, isTrue);

      // Degenerate SVG path
      final degenSvgRes = validator.validateSvgPath('M 10 10');
      expect(degenSvgRes.isValid, isFalse);
      expect(degenSvgRes.errorCode, IngestionErrorCode.invalidStrokeData);

      // Valid SVG path
      final validSvgRes = validator.validateSvgPath('M 10 10 L 90 90');
      expect(validSvgRes.isValid, isTrue);
    });

    test('3.4 Audio validation checks bounds and container magic bytes', () {
      // Too small (< 32 bytes)
      final tinyRes = validator.validateAudioBytes([0x52, 0x49, 0x46, 0x46]);
      expect(tinyRes.isValid, isFalse);
      expect(tinyRes.errorCode, IngestionErrorCode.invalidAudioData);

      // Valid WAV
      final validWav = createWavBytes(64);
      expect(validator.validateAudioBytes(validWav).isValid, isTrue);

      // Valid MP3
      final validMp3 = createMp3Bytes(64);
      expect(validator.validateAudioBytes(validMp3).isValid, isTrue);

      // Corrupted audio with plain text
      final fakeAudio = utf8.encode('This is not an audio file, it is plain text padding string.');
      final fakeRes = validator.validateAudioBytes(fakeAudio);
      expect(fakeRes.isValid, isFalse);
      expect(fakeRes.errorCode, IngestionErrorCode.invalidAudioData);
    });
  });

  // ==========================================================================
  // Group 4: PackageStagingManager Atomic Promotion and Rollback
  // ==========================================================================
  group('4. PackageStagingManager Atomic Staging & Promotion', () {
    test('4.1 Creates sandbox, promotes via 3-way swap, and cleans staging', () async {
      final stagingDir = await stagingManager.createStagingDirectory('test_pkg');
      expect(await stagingDir.exists(), isTrue);

      // Put a test file in staging
      final file = File(p.join(stagingDir.path, 'manifest.json'));
      await file.writeAsString('{"id": "test_pkg"}');

      // Promote
      final promoted = await stagingManager.promoteStagedPackage(
        stagingDir: stagingDir,
        packageId: 'test_pkg',
      );
      expect(await promoted.exists(), isTrue);
      expect(p.basename(promoted.path), 'test_pkg');

      // Old staging sandbox should no longer exist
      expect(await stagingDir.exists(), isFalse);
    });

    test('4.2 Promotion preserves old package if promotion fails during upgrade', () async {
      // Step 1: Promote original version
      final s1 = await stagingManager.createStagingDirectory('test_upgrade');
      final f1 = File(p.join(s1.path, 'version.txt'));
      await f1.writeAsString('v1');
      final p1 = await stagingManager.promoteStagedPackage(
        stagingDir: s1,
        packageId: 'test_upgrade',
      );
      expect(await File(p.join(p1.path, 'version.txt')).readAsString(), 'v1');

      // Step 2: Prepare v2 in staging
      final s2 = await stagingManager.createStagingDirectory('test_upgrade');
      final f2 = File(p.join(s2.path, 'version.txt'));
      await f2.writeAsString('v2');

      // Step 3: Promote v2 successfully
      final p2 = await stagingManager.promoteStagedPackage(
        stagingDir: s2,
        packageId: 'test_upgrade',
      );
      expect(await File(p.join(p2.path, 'version.txt')).readAsString(), 'v2');
    });
  });

  // ==========================================================================
  // Group 5: OfflinePackageLoader (ZIP, Directory, JSON) & Security
  // ==========================================================================
  group('5. OfflinePackageLoader (ZIP, Directory, JSON) & Security', () {
    test('5.1 Successfully ingests synthetic offline ZIP archive', () async {
      // Build an in-memory zip archive
      final archive = Archive();

      final manifestJson = jsonEncode({
        'id': 'offline_zip_pkg',
        'name': 'Offline Zip Package',
        'version': '1.0.0',
        'capabilities': ['metadata', 'strokes', 'audio'],
        'metadataPath': 'metadata.json',
        'strokesPath': 'strokes.json',
        'audioPath': 'audio',
      });
      archive.addFile(ArchiveFile.string('manifest.json', manifestJson));

      final metadataJson = jsonEncode([
        {
          'codepoint': 0x4E00,
          'literal': '一',
          'meanings': ['one'],
          'stroke_count': 1,
          'onyomi': ['イチ'],
          'kunyomi': ['ひと'],
        }
      ]);
      archive.addFile(ArchiveFile.string('metadata.json', metadataJson));

      final strokesJson = jsonEncode({
        '19968': [
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
      archive.addFile(ArchiveFile('audio/4E00.wav', audioBytes.length, audioBytes));

      final zipData = ZipEncoder().encode(archive)!;
      final zipFile = File(p.join(tempRootDir.path, 'valid_package.zip'));
      await zipFile.writeAsBytes(zipData);

      final result = await offlineLoader.loadFromArchive(zipFile);
      expect(result.isSuccess, isTrue);
      expect(result.sourceId, 'offline_zip_pkg');
      expect(result.packageDirectory, isNotNull);
      expect(await Directory(result.packageDirectory!).exists(), isTrue);
    });

    test('5.2 Rejects ZIP archive containing Zip-Slip attack and purges staging', () async {
      final archive = Archive();
      final manifestJson = jsonEncode({
        'id': 'exploit_pkg',
        'name': 'Exploit Package',
        'version': '1.0.0',
        'capabilities': ['metadata'],
      });
      archive.addFile(ArchiveFile.string('manifest.json', manifestJson));
      archive.addFile(ArchiveFile.string('../../system_exploit.txt', 'evil'));

      final zipData = ZipEncoder().encode(archive)!;
      final zipFile = File(p.join(tempRootDir.path, 'exploit.zip'));
      await zipFile.writeAsBytes(zipData);

      final result = await offlineLoader.loadFromArchive(zipFile);
      expect(result.isSuccess, isFalse);
      expect(result.errorCode, IngestionErrorCode.zipSlipDetected);

      // Verify no packages promoted
      final promoted = Directory(p.join(tempRootDir.path, 'packages', 'exploit_pkg'));
      expect(await promoted.exists(), isFalse);
    });

    test('5.3 Successfully ingests directory package', () async {
      final dir = Directory(p.join(tempRootDir.path, 'source_dir'));
      await dir.create();

      final manifestJson = jsonEncode({
        'id': 'dir_pkg',
        'name': 'Directory Package',
        'version': '1.0.0',
        'capabilities': ['metadata'],
      });
      await File(p.join(dir.path, 'manifest.json')).writeAsString(manifestJson);

      final metaJson = jsonEncode([
        {
          'codepoint': 0x4E8C,
          'literal': '二',
          'meanings': ['two'],
          'stroke_count': 2,
        }
      ]);
      await File(p.join(dir.path, 'metadata.json')).writeAsString(metaJson);

      final result = await offlineLoader.loadFromDirectory(dir);
      expect(result.isSuccess, isTrue);
      expect(result.sourceId, 'dir_pkg');
    });

    test('5.4 Successfully ingests single-file JSON package', () async {
      final jsonFile = File(p.join(tempRootDir.path, 'standalone.json'));
      final jsonContent = jsonEncode({
        'manifest': {
          'id': 'json_pkg',
          'name': 'JSON Package',
          'version': '1.0.0',
          'capabilities': ['metadata'],
        },
        'metadata': [
          {
            'codepoint': 0x4E09,
            'literal': '三',
            'meanings': ['three'],
            'stroke_count': 3,
          }
        ],
      });
      await jsonFile.writeAsString(jsonContent);

      final result = await offlineLoader.loadFromJsonFile(jsonFile);
      expect(result.isSuccess, isTrue);
      expect(result.sourceId, 'json_pkg');
    });

    test('5.5 Rejects corrupted ZIP or missing manifest', () async {
      final corruptFile = File(p.join(tempRootDir.path, 'corrupt.zip'));
      await corruptFile.writeAsBytes([0x00, 0x01, 0x02, 0x03]); // not a ZIP

      final result = await offlineLoader.loadFromArchive(corruptFile);
      expect(result.isSuccess, isFalse);
      expect(result.errorCode, IngestionErrorCode.invalidArchive);
    });
  });

  // ==========================================================================
  // Group 6: OnlineSourceFetcher and MockContentHttpServer
  // ==========================================================================
  group('6. OnlineSourceFetcher and MockContentHttpServer', () {
    test('6.1 Successfully fetches remote package over HTTP and promotes', () async {
      final manifest = {
        'id': 'remote_pkg',
        'name': 'Remote Package',
        'version': '1.0.0',
        'capabilities': ['metadata'],
        'metadataPath': 'metadata.json',
      };
      mockHttpServer.serveManifest('/manifest.json', manifest);

      final metaData = jsonEncode([
        {
          'codepoint': 0x4E00,
          'literal': '一',
          'meanings': ['one'],
          'stroke_count': 1,
        }
      ]);
      mockHttpServer.serveBytes('/metadata.json', utf8.encode(metaData));

      final result = await onlineFetcher.fetchAndInstall(
        Uri.parse('${mockHttpServer.baseUrl}/manifest.json'),
      );

      expect(result.isSuccess, isTrue);
      expect(result.sourceId, 'remote_pkg');
      expect(mockHttpServer.requestCount('/manifest.json'), 1);
      expect(mockHttpServer.requestCount('/metadata.json'), 1);
    });

    test('6.2 HTTP 404 returns networkError without endless retry', () async {
      final result = await onlineFetcher.fetchAndInstall(
        Uri.parse('${mockHttpServer.baseUrl}/not_found_manifest.json'),
      );
      expect(result.isSuccess, isFalse);
      expect(result.errorCode, IngestionErrorCode.networkError);
      expect(result.errorMessage, contains('404'));
      expect(mockHttpServer.requestCount('/not_found_manifest.json'), 1);
    });

    test('6.3 HTTP 500 triggers retry and returns failure on exhaustion', () async {
      mockHttpServer.serveError('/server_error.json', HttpStatus.internalServerError);

      final result = await onlineFetcher.fetchAndInstall(
        Uri.parse('${mockHttpServer.baseUrl}/server_error.json'),
        options: const FetchOptions(
          maxRetries: 2,
          retryDelay: Duration(milliseconds: 50),
        ),
      );

      expect(result.isSuccess, isFalse);
      expect(result.errorCode, IngestionErrorCode.networkError);
      // initial request + 2 retries = 3 requests
      expect(mockHttpServer.requestCount('/server_error.json'), 3);
    });

    test('6.4 Request timeout returns timeout error code and cleans staging', () async {
      mockHttpServer.serveDelayed(
        '/timeout_manifest.json',
        const Duration(seconds: 2),
      );

      final result = await onlineFetcher.fetchAndInstall(
        Uri.parse('${mockHttpServer.baseUrl}/timeout_manifest.json'),
        options: const FetchOptions(
          connectTimeout: Duration(milliseconds: 300),
          receiveTimeout: Duration(milliseconds: 300),
          maxRetries: 0,
        ),
      );

      expect(result.isSuccess, isFalse);
      expect(result.errorCode, IngestionErrorCode.timeout);
    });
  });

  // ==========================================================================
  // Group 7: Custom Source Adapters & Fallback to Bundled Defaults
  // ==========================================================================
  group('7. Custom Source Adapters & Fallback to Bundled Defaults', () {
    late ContentSourceRegistry registry;
    late ContentRepository repository;
    late ContentDatabase bundledDb;
    late UserDatabase userDb;

    setUp(() {
      final dbFile = File('assets/db/kanji_content.db');
      expect(dbFile.existsSync(), isTrue);
      bundledDb = ContentDatabase.openFromFile(dbFile);

      registry = ContentSourceRegistry();
      registry.registerMetadataSource(BundledMetadataSource(contentDb: bundledDb));
      registry.registerStrokeSource(BundledStrokeSource(contentDb: bundledDb));
      registry.registerAudioSource(DefaultTtsAudioSource(
        speechService: FakeSpeechService(),
        contentDb: bundledDb,
      ));

      repository = ContentRepository(registry: registry);
      userDb = UserDatabase.openInMemory();
    });

    tearDown(() {
      bundledDb.close();
    });

    test('7.1 Custom sources prioritize custom entries and fall back to bundled defaults', () async {
      // 1. Initially bundled gives 'one' for 0x4E00
      final initialKanji = await repository.getKanjiByCodepoint(0x4E00);
      expect(initialKanji?.meanings, contains('one'));

      // 2. Register custom metadata source overriding 0x4E00 with custom meanings
      final customMeta = CustomMetadataSource(
        sourceId: 'custom_meta',
        displayName: 'Custom Meta',
        version: '1.0.0',
        entries: {
          0x4E00: const KanjiMetadataEntry(
            codepoint: 0x4E00,
            literal: '一',
            strokeCount: 1,
            meanings: ['one (custom)', 'unity'],
          ),
        },
      );
      registry.registerMetadataSource(customMeta, priority: 10);
      repository.clearCache();

      // Now 0x4E00 resolves to custom meanings
      final customKanji = await repository.getKanjiByCodepoint(0x4E00);
      expect(customKanji?.meanings, ['one (custom)', 'unity']);

      // But strokes for 0x4E00 automatically fall back to bundled strokes!
      expect(customKanji?.strokes.length, 1);
      expect(customKanji?.strokes.first.svgPath, isNotEmpty);

      // And 0x4E8C (not in custom source) falls back completely to bundled metadata!
      final fallbackKanji = await repository.getKanjiByCodepoint(0x4E8C);
      expect(fallbackKanji?.literal, '二');
      expect(fallbackKanji?.meanings, contains('two'));
    });

    test('7.2 Unregistering custom source cleanly restores bundled defaults', () async {
      final customMeta = CustomMetadataSource(
        sourceId: 'custom_to_remove',
        displayName: 'Custom',
        version: '1.0.0',
        entries: {
          0x4E00: const KanjiMetadataEntry(
            codepoint: 0x4E00,
            literal: '一',
            strokeCount: 1,
            meanings: ['overridden'],
          ),
        },
      );
      registry.registerMetadataSource(customMeta, priority: 10);

      var resolved = await repository.getKanjiByCodepoint(0x4E00);
      expect(resolved?.meanings, ['overridden']);

      // Unregister
      registry.unregisterSource('custom_to_remove');

      resolved = await repository.getKanjiByCodepoint(0x4E00);
      expect(resolved?.meanings, contains('one')); // Back to bundled default
    });

    test('7.3 User learning state (user_progress.db) remains 100% untouched across ingestion and swaps', () async {
      final baseDate = DateTime.utc(2026, 11, 1, 12, 0);

      // Seed user progress with an FSRS card and review log
      final card = UserCardProgress(
        codepoint: 0x4E00,
        mode: PracticeMode.writing,
        dueDate: baseDate.add(const Duration(days: 3)),
        stability: 4.5,
        difficulty: 3.2,
        elapsedDays: 1,
        scheduledDays: 3,
        reps: 2,
        lapses: 0,
        state: 2,
        lastReview: baseDate,
      );
      userDb.upsertCard(card);
      userDb.insertReviewLog(
        codepoint: 0x4E00,
        mode: PracticeMode.writing,
        rating: 3,
        mistakes: 0,
        hintsUsed: 0,
        reviewedAt: baseDate,
      );

      final initialBackup = userDb.exportBackupJson();
      final initialCard = userDb.getCard(0x4E00, mode: PracticeMode.writing);
      expect(initialCard?.stability, 4.5);

      // Ingest a custom package via OfflinePackageLoader
      final jsonFile = File(p.join(tempRootDir.path, 'safe_update.json'));
      await jsonFile.writeAsString(jsonEncode({
        'manifest': {
          'id': 'safe_pkg',
          'name': 'Safe Package',
          'version': '1.0.0',
          'capabilities': ['metadata'],
        },
        'metadata': [
          {
            'codepoint': 0x4E00,
            'literal': '一',
            'meanings': ['one (updated)'],
            'stroke_count': 1,
          }
        ],
      }));
      final ingestionRes = await offlineLoader.loadFromJsonFile(jsonFile);
      expect(ingestionRes.isSuccess, isTrue);

      // Verify userDb is 100% untouched
      final afterCard = userDb.getCard(0x4E00, mode: PracticeMode.writing);
      expect(afterCard?.codepoint, initialCard?.codepoint);
      expect(afterCard?.stability, initialCard?.stability);
      expect(afterCard?.difficulty, initialCard?.difficulty);
      expect(afterCard?.reps, initialCard?.reps);
      final initialMap = jsonDecode(initialBackup) as Map<String, dynamic>..remove('exported_at');
      final afterMap = jsonDecode(userDb.exportBackupJson()) as Map<String, dynamic>..remove('exported_at');
      expect(afterMap, equals(initialMap));
    });

    test('7.4 CustomStrokeSource and CustomAudioSource load from directory and query correctly', () async {
      final pkgDir = Directory(p.join(tempRootDir.path, 'full_custom_pkg'));
      await pkgDir.create(recursive: true);

      const manifest = SourceManifest(
        id: 'full_custom',
        name: 'Full Custom Package',
        version: '1.0.0',
        capabilities: {
          SourceCapability.metadata,
          SourceCapability.strokes,
          SourceCapability.audio,
        },
        metadataPath: 'metadata.json',
        strokesPath: 'strokes.json',
        audioPath: 'audio',
      );

      // Write strokes.json with 2 points that resample to 50
      final strokesFile = File(p.join(pkgDir.path, 'strokes.json'));
      await strokesFile.writeAsString(jsonEncode({
        '19968': [
          {
            'stroke_order': 1,
            'stroke_type': 'h',
            'svg_path': 'M 10 50 L 90 50',
            'points': [
              {'x': 10.0, 'y': 50.0},
              {'x': 90.0, 'y': 50.0},
            ],
          }
        ]
      }));

      // Write audio directory with WAV file
      final audioDir = Directory(p.join(pkgDir.path, 'audio'));
      await audioDir.create(recursive: true);
      final wavFile = File(p.join(audioDir.path, '4E00_ichi.wav'));
      await wavFile.writeAsBytes(createWavBytes(64));

      final strokeSource = await CustomStrokeSource.fromDirectory(pkgDir, manifest);
      expect(strokeSource.sourceId, 'full_custom');
      expect(await strokeSource.containsStrokes(0x4E00), isTrue);
      final strokes = await strokeSource.getStrokes(0x4E00);
      expect(strokes, isNotNull);
      expect(strokes!.length, 1);
      expect(strokes.first.sampledPoints.length, 50);

      final audioSource = await CustomAudioSource.fromDirectory(pkgDir, manifest);
      expect(audioSource.sourceId, 'full_custom');
      expect(await audioSource.containsAudio(0x4E00), isTrue);
      final audio = await audioSource.getAudio(0x4E00, reading: 'ichi');
      expect(audio, isNotNull);
      expect(audio!.type, AudioPayloadType.localFile);
      expect(audio.reading, 'ichi');
      expect(audio.mimeType, 'audio/wav');
    });
  });
}
