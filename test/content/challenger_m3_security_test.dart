import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:offline_kanji_practice/src/content/ingestion/loaders/offline_package_loader.dart';
import 'package:offline_kanji_practice/src/content/ingestion/models/ingestion_result.dart';
import 'package:offline_kanji_practice/src/content/ingestion/models/source_manifest.dart';
import 'package:offline_kanji_practice/src/content/ingestion/security/zip_slip_guard.dart';
import 'package:offline_kanji_practice/src/content/ingestion/staging/package_staging_manager.dart';
import 'package:offline_kanji_practice/src/content/ingestion/validation/source_validator.dart';

void main() {
  late Directory tempRootDir;
  late Directory sandboxDestDir;
  late PackageStagingManager stagingManager;
  late SourceValidator validator;
  late OfflinePackageLoader offlineLoader;

  setUp(() async {
    tempRootDir = Directory.systemTemp.createTempSync('challenger_m3_sec_');
    sandboxDestDir = Directory(p.join(tempRootDir.path, 'sandbox'));
    await sandboxDestDir.create(recursive: true);

    stagingManager = PackageStagingManager(baseDirectory: tempRootDir);
    await stagingManager.initialize();

    validator = SourceValidator();
    offlineLoader = OfflinePackageLoader(
      stagingManager: stagingManager,
      validator: validator,
    );
  });

  tearDown(() async {
    try {
      if (tempRootDir.existsSync()) {
        tempRootDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  // Helper to create a valid minimal manifest map
  Map<String, dynamic> createValidManifestMap({String id = 'valid_pkg'}) => {
        'id': id,
        'name': 'Valid Security Test Package',
        'version': '1.0.0',
        'capabilities': ['metadata'],
        'metadataPath': 'metadata.json',
      };

  // Helper to create a valid metadata JSON string
  String createValidMetadataJson() => jsonEncode([
        {
          'codepoint': 0x4E00,
          'literal': '一',
          'meanings': ['one'],
          'stroke_count': 1,
        }
      ]);

  // Helper to craft a ZIP archive containing a real Unix symbolic link entry
  Uint8List makeUnixSymlinkZip(Archive archive, String symlinkFilename) {
    final zipBytes = Uint8List.fromList(ZipEncoder().encode(archive)!);
    final byteData = ByteData.sublistView(zipBytes);
    final filenameBytes = utf8.encode(symlinkFilename);

    for (var i = 0; i < zipBytes.length - 46; i++) {
      if (byteData.getUint32(i, Endian.little) == 0x02014B50) {
        final fnLen = byteData.getUint16(i + 28, Endian.little);
        if (fnLen == filenameBytes.length) {
          final fnInZip = zipBytes.sublist(i + 46, i + 46 + fnLen);
          var match = true;
          for (var j = 0; j < fnLen; j++) {
            if (fnInZip[j] != filenameBytes[j]) {
              match = false;
              break;
            }
          }
          if (match) {
            // Offset 5: set versionMadeBy host OS to 3 (UNIX)
            zipBytes[i + 5] = 3;
            // Offset 40..41: high 16 bits of externalFileAttributes = Unix mode (0xA1ED: symlink 0755)
            byteData.setUint16(i + 40, 0xA1ED, Endian.little);
            break;
          }
        }
      }
    }
    return zipBytes;
  }

  // ==========================================================================
  // Section 1: Aggressive Path Traversal Exploits
  // ==========================================================================
  group('1. Aggressive Path Traversal Exploits (ZipSlipGuard & OfflineLoader)', () {
    test('1.1 ZipSlipGuard rejects all relative traversal vectors', () {
      final relativeVectors = [
        '../../etc/passwd',
        '..\\..\\Windows\\System32\\cmd.exe',
        'dir/../../evil.txt',
        'sub/dir/../../../payload',
        './../../evil.sh',
        '.\\..\\evil.bat',
        'foo/bar/../../../../etc/shadow',
        'a/b/c/../../../../escape.txt',
        '..',
        '.',
        'folder/..',
        'folder/sub/../..',
        './',
        '',
      ];

      for (final vector in relativeVectors) {
        expect(
          () => ZipSlipGuard.resolveAndVerifyEntry(sandboxDestDir.path, vector),
          throwsA(isA<SecurityException>()),
          reason: 'Failed to reject relative traversal vector: "$vector"',
        );
        expect(
          ZipSlipGuard.isPathSafe(sandboxDestDir.path, vector),
          isFalse,
          reason: 'isPathSafe unexpectedly returned true for: "$vector"',
        );
      }
    });

    test('1.2 ZipSlipGuard rejects absolute paths, Windows drives, and UNC shares', () {
      final absoluteVectors = [
        '/etc/passwd',
        '/root/.ssh/id_rsa',
        '/var/log/syslog',
        '//server/share/payload.dll',
        '\\\\server\\share\\payload.dll',
        'C:\\Windows\\System32\\payload.txt',
        'c:/Windows/System32/cmd.exe',
        'D:\\evil.exe',
        'z:\\payload',
        '\\\\?\\C:\\evil.txt',
      ];

      for (final vector in absoluteVectors) {
        expect(
          () => ZipSlipGuard.resolveAndVerifyEntry(sandboxDestDir.path, vector),
          throwsA(isA<SecurityException>()),
          reason: 'Failed to reject absolute or drive vector: "$vector"',
        );
        expect(
          ZipSlipGuard.isPathSafe(sandboxDestDir.path, vector),
          isFalse,
          reason: 'isPathSafe unexpectedly returned true for: "$vector"',
        );
      }
    });

    test('1.3 ZipSlipGuard rejects null bytes and suspicious separators', () {
      final suspiciousVectors = [
        'payload.txt\x00.png',
        'foo\x00bar.txt',
        '\x00',
        'test/nested\x00/file.txt',
        'foo/./bar.txt',
        './../foo',
        '.\\..\\bar',
      ];

      for (final vector in suspiciousVectors) {
        expect(
          () => ZipSlipGuard.resolveAndVerifyEntry(sandboxDestDir.path, vector),
          throwsA(isA<SecurityException>()),
          reason: 'Failed to reject suspicious vector: "$vector"',
        );
      }

      // Safe leading './' is normalized without escaping sandbox
      final safePrefixed = ZipSlipGuard.resolveAndVerifyEntry(sandboxDestDir.path, './valid.json');
      expect(p.isWithin(sandboxDestDir.path, safePrefixed), isTrue);
    });

    test('1.4 ZipSlipGuard strictly rejects symbolic links', () {
      expect(
        () => ZipSlipGuard.resolveAndVerifyEntry(
          sandboxDestDir.path,
          'normal_name.txt',
          isSymbolicLink: true,
        ),
        throwsA(isA<SecurityException>()),
      );
      expect(
        ZipSlipGuard.isPathSafe(sandboxDestDir.path, 'normal_name.txt', isSymbolicLink: true),
        isFalse,
      );
    });

    test('1.5 OfflinePackageLoader rejects archives containing traversal files and purges staging', () async {
      final traversalPayloads = [
        '../../traversal_rel_unix.txt',
        '..\\..\\traversal_rel_win.txt',
        '/etc/shadow_exploit',
        'C:\\Windows\\System32\\exploit.dll',
        '\\\\server\\share\\net_exploit.exe',
        'data\x00nullbyte.txt',
      ];

      for (var i = 0; i < traversalPayloads.length; i++) {
        final payloadName = traversalPayloads[i];
        final pkgId = 'exploit_pkg_$i';

        final archive = Archive();
        archive.addFile(ArchiveFile.string('manifest.json', jsonEncode(createValidManifestMap(id: pkgId))));
        archive.addFile(ArchiveFile.string('metadata.json', createValidMetadataJson()));
        archive.addFile(ArchiveFile.string(payloadName, 'MALICIOUS_PAYLOAD_DATA'));

        final zipBytes = ZipEncoder().encode(archive)!;
        final zipFile = File(p.join(tempRootDir.path, 'attack_$i.zip'));
        await zipFile.writeAsBytes(zipBytes);

        // Canary file path outside the sandbox that must NOT be written
        final canaryFile = File(p.join(tempRootDir.path, 'traversal_rel_unix.txt'));
        expect(await canaryFile.exists(), isFalse);

        final result = await offlineLoader.loadFromArchive(zipFile);
        expect(result.isSuccess, isFalse, reason: 'Archive with payload "$payloadName" should fail');
        expect(result.errorCode, IngestionErrorCode.zipSlipDetected);

        // Verification: No files escaped or were written outside
        expect(await canaryFile.exists(), isFalse);

        // Verification: No packages promoted to packagesRoot
        final promotedDir = Directory(p.join(stagingManager.packagesRoot.path, pkgId));
        expect(await promotedDir.exists(), isFalse);

        // Verification: Staging directory completely purged
        final stagingEntities = await stagingManager.stagingRoot.list().toList();
        expect(stagingEntities.isEmpty, isTrue, reason: 'Staging directory was not purged on failure');
      }
    });

    test('1.6 OfflinePackageLoader and StagingManager strictly reject symbolic links in archives', () async {
      const pkgId = 'symlink_attack_pkg';
      final archive = Archive();
      archive.addFile(ArchiveFile.string('manifest.json', jsonEncode(createValidManifestMap(id: pkgId))));
      archive.addFile(ArchiveFile.string('metadata.json', createValidMetadataJson()));

      final symlinkFile = ArchiveFile.string('symlink_entry', '/etc/passwd');
      symlinkFile.isSymbolicLink = true;
      archive.addFile(symlinkFile);

      // A: Verify PackageStagingManager.extractArchive rejects symlink ArchiveFile directly
      final testStaging = await stagingManager.createStagingDirectory('test_direct_symlink');
      await expectLater(
        stagingManager.extractArchive(archive, testStaging),
        throwsA(isA<SecurityException>()),
      );
      await stagingManager.purgeStagingDirectory(testStaging);

      // B: Craft real Unix symlink ZIP archive bytes and verify OfflinePackageLoader rejects it
      final zipBytes = makeUnixSymlinkZip(archive, 'symlink_entry');
      final decoded = ZipDecoder().decodeBytes(zipBytes);
      final decodedSymlink = decoded.files.firstWhere((f) => f.name == 'symlink_entry');
      expect(decodedSymlink.isSymbolicLink, isTrue, reason: 'Crafted zip must decode with isSymbolicLink = true');

      final zipFile = File(p.join(tempRootDir.path, 'symlink_attack.zip'));
      await zipFile.writeAsBytes(zipBytes);

      final result = await offlineLoader.loadFromArchive(zipFile);
      expect(result.isSuccess, isFalse);
      expect(result.errorCode, IngestionErrorCode.zipSlipDetected);

      // Staging purged and not promoted
      final promotedDir = Directory(p.join(stagingManager.packagesRoot.path, pkgId));
      expect(await promotedDir.exists(), isFalse);
      final stagingEntities = await stagingManager.stagingRoot.list().toList();
      expect(stagingEntities.isEmpty, isTrue);
    });

    test('1.7 SourceValidator rejects manifests declaring malicious traversal paths', () {
      final maliciousManifests = [
        {'id': 'pkg_trav_1', 'name': 'P', 'version': '1.0.0', 'capabilities': ['metadata'], 'metadataPath': '../../evil.json'},
        {'id': 'pkg_trav_2', 'name': 'P', 'version': '1.0.0', 'capabilities': ['metadata'], 'metadataPath': 'C:\\Windows\\system.ini'},
        {'id': 'pkg_trav_3', 'name': 'P', 'version': '1.0.0', 'capabilities': ['strokes'], 'strokesPath': '/etc/shadow'},
        {'id': 'pkg_trav_4', 'name': 'P', 'version': '1.0.0', 'capabilities': ['audio'], 'audioPath': '\\\\server\\share\\audio'},
        {'id': 'pkg_trav_5', 'name': 'P', 'version': '1.0.0', 'capabilities': ['metadata'], 'paths': {'metadata': '../escape.json'}},
      ];

      for (final m in maliciousManifests) {
        final res = validator.validateManifest(m);
        expect(res.isValid, isFalse);
        expect(res.errorCode, IngestionErrorCode.zipSlipDetected);
      }
    });
  });

  // ==========================================================================
  // Section 2: Archive Decompression Bombs & Resource Exhaustion
  // ==========================================================================
  group('2. Decompression Bomb & Resource Limits Stress-Testing', () {
    test('2.1 Rejects archive containing > 5000 entries (File Count Bomb)', () async {
      // Direct guard verification
      expect(
        () => ZipSlipGuard.verifyResourceLimits(
          entryCount: 5001,
          totalUncompressedBytes: 5000,
        ),
        throwsA(isA<SecurityException>()),
      );
      // Valid boundary 5000 entries does not throw
      expect(
        () => ZipSlipGuard.verifyResourceLimits(
          entryCount: 5000,
          totalUncompressedBytes: 5000,
        ),
        returnsNormally,
      );

      // End-to-end OfflinePackageLoader verification with 5001 files
      const pkgId = 'entry_bomb_pkg';
      final archive = Archive();
      archive.addFile(ArchiveFile.string('manifest.json', jsonEncode(createValidManifestMap(id: pkgId))));
      archive.addFile(ArchiveFile.string('metadata.json', createValidMetadataJson()));

      // Add 5001 tiny entries
      for (var i = 0; i < 5001; i++) {
        archive.addFile(ArchiveFile.string('f_$i.txt', 'x'));
      }

      final zipBytes = ZipEncoder().encode(archive)!;
      final zipFile = File(p.join(tempRootDir.path, 'file_count_bomb.zip'));
      await zipFile.writeAsBytes(zipBytes);

      final result = await offlineLoader.loadFromArchive(zipFile);
      expect(result.isSuccess, isFalse);
      expect(result.errorCode, IngestionErrorCode.zipSlipDetected);

      // Verify zero leakage to packages/ and staging is purged
      final promotedDir = Directory(p.join(stagingManager.packagesRoot.path, pkgId));
      expect(await promotedDir.exists(), isFalse);
      final stagingEntities = await stagingManager.stagingRoot.list().toList();
      expect(stagingEntities.isEmpty, isTrue);
    });

    test('2.2 Rejects single file size > 50MB (Single File Bomb)', () {
      const maxSingle = 50 * 1024 * 1024; // 52,428,800 bytes

      // Exactly 50MB: allowed
      expect(
        () => ZipSlipGuard.verifyResourceLimits(
          entryCount: 1,
          totalUncompressedBytes: maxSingle,
          singleFileBytes: maxSingle,
        ),
        returnsNormally,
      );

      // 50MB + 1 byte: rejected
      expect(
        () => ZipSlipGuard.verifyResourceLimits(
          entryCount: 1,
          totalUncompressedBytes: maxSingle + 1,
          singleFileBytes: maxSingle + 1,
        ),
        throwsA(isA<SecurityException>()),
      );
    });

    test('2.3 Rejects total archive uncompressed size > 250MB (Total Size Bomb)', () {
      const maxTotal = 250 * 1024 * 1024; // 262,144,000 bytes

      // Exactly 250MB: allowed
      expect(
        () => ZipSlipGuard.verifyResourceLimits(
          entryCount: 10,
          totalUncompressedBytes: maxTotal,
          singleFileBytes: 25 * 1024 * 1024,
        ),
        returnsNormally,
      );

      // 250MB + 1 byte: rejected
      expect(
        () => ZipSlipGuard.verifyResourceLimits(
          entryCount: 10,
          totalUncompressedBytes: maxTotal + 1,
          singleFileBytes: 25 * 1024 * 1024,
        ),
        throwsA(isA<SecurityException>()),
      );
    });

    test('2.4 Rejects compression ratio > 100x when uncompressed > 1MB', () {
      // 10MB uncompressed, 50KB compressed -> ratio = 200x (> 100x)
      expect(
        () => ZipSlipGuard.verifyResourceLimits(
          entryCount: 1,
          totalUncompressedBytes: 10 * 1024 * 1024,
          compressedBytes: 50 * 1024,
        ),
        throwsA(isA<SecurityException>()),
      );

      // Ratio 99x (10MB uncompressed, ~103KB compressed) -> allowed
      expect(
        () => ZipSlipGuard.verifyResourceLimits(
          entryCount: 1,
          totalUncompressedBytes: 10 * 1024 * 1024,
          compressedBytes: (10 * 1024 * 1024 / 99).round(),
        ),
        returnsNormally,
      );

      // Total <= 1MB ignores high ratio (prevents false alarms on tiny files)
      expect(
        () => ZipSlipGuard.verifyResourceLimits(
          entryCount: 1,
          totalUncompressedBytes: 500 * 1024, // 500KB
          compressedBytes: 1024, // 1KB -> ratio 500x
        ),
        returnsNormally,
      );
    });
  });

  // ==========================================================================
  // Section 3: Malformed & Corrupted Archives
  // ==========================================================================
  group('3. Malformed and Corrupted Archive Handling', () {
    test('3.1 Truncated ZIP archives fail gracefully with invalidArchive', () async {
      // Build valid zip bytes
      final archive = Archive();
      archive.addFile(ArchiveFile.string('manifest.json', jsonEncode(createValidManifestMap(id: 'trunc_pkg'))));
      archive.addFile(ArchiveFile.string('metadata.json', createValidMetadataJson()));
      final validBytes = ZipEncoder().encode(archive)!;

      // Test truncation at 5%, 25%, 50%, 80%, 95%
      final truncatePercentages = [0.05, 0.25, 0.50, 0.80, 0.95];

      for (var i = 0; i < truncatePercentages.length; i++) {
        final pct = truncatePercentages[i];
        final cutLen = (validBytes.length * pct).round().clamp(1, validBytes.length - 1);
        final truncatedBytes = validBytes.sublist(0, cutLen);

        final truncFile = File(p.join(tempRootDir.path, 'trunc_$i.zip'));
        await truncFile.writeAsBytes(truncatedBytes);

        final result = await offlineLoader.loadFromArchive(truncFile);
        expect(result.isSuccess, isFalse, reason: 'Truncated zip at $pct should fail');
        expect(result.errorCode, IngestionErrorCode.invalidArchive);

        // Staging check
        final stagingEntities = await stagingManager.stagingRoot.list().toList();
        expect(stagingEntities.isEmpty, isTrue);
      }
    });

    test('3.2 Zero-byte archive file fails gracefully', () async {
      final zeroFile = File(p.join(tempRootDir.path, 'zero_byte.zip'));
      await zeroFile.writeAsBytes(Uint8List(0));

      final result = await offlineLoader.loadFromArchive(zeroFile);
      expect(result.isSuccess, isFalse);
      expect(
        result.errorCode == IngestionErrorCode.invalidArchive ||
            result.errorCode == IngestionErrorCode.missingManifest,
        isTrue,
        reason: 'Zero-byte zip must return invalidArchive or missingManifest',
      );

      final stagingEntities = await stagingManager.stagingRoot.list().toList();
      expect(stagingEntities.isEmpty, isTrue);
    });

    test('3.3 Corrupted header bytes fail gracefully with invalidArchive', () async {
      // Garbage binary bytes
      final garbageFile = File(p.join(tempRootDir.path, 'garbage.zip'));
      await garbageFile.writeAsBytes(Uint8List.fromList(List.generate(512, (i) => (i * 37) % 256)));

      final res1 = await offlineLoader.loadFromArchive(garbageFile);
      expect(res1.isSuccess, isFalse);
      expect(res1.errorCode, IngestionErrorCode.invalidArchive);

      // Corrupted PK header: starts with 'PK' but damaged magic
      final corruptPkFile = File(p.join(tempRootDir.path, 'corrupt_pk.zip'));
      final corruptPkBytes = Uint8List(256);
      corruptPkBytes[0] = 0x50; // 'P'
      corruptPkBytes[1] = 0x4B; // 'K'
      corruptPkBytes[2] = 0xFF; // corrupt
      corruptPkBytes[3] = 0xFF;
      await corruptPkFile.writeAsBytes(corruptPkBytes);

      final res2 = await offlineLoader.loadFromArchive(corruptPkFile);
      expect(res2.isSuccess, isFalse);
      expect(res2.errorCode, IngestionErrorCode.invalidArchive);

      final stagingEntities = await stagingManager.stagingRoot.list().toList();
      expect(stagingEntities.isEmpty, isTrue);
    });

    test('3.4 Valid archive missing manifest.json fails with missingManifest', () async {
      final archive = Archive();
      archive.addFile(ArchiveFile.string('notes.txt', 'This archive has no manifest.json'));
      archive.addFile(ArchiveFile.string('metadata.json', createValidMetadataJson()));

      final zipBytes = ZipEncoder().encode(archive)!;
      final noManifestFile = File(p.join(tempRootDir.path, 'no_manifest.zip'));
      await noManifestFile.writeAsBytes(zipBytes);

      final result = await offlineLoader.loadFromArchive(noManifestFile);
      expect(result.isSuccess, isFalse);
      expect(result.errorCode, IngestionErrorCode.missingManifest);

      final stagingEntities = await stagingManager.stagingRoot.list().toList();
      expect(stagingEntities.isEmpty, isTrue);
    });
  });

  // ==========================================================================
  // Section 4: Manifest Schema, SemVer 2.0.0, and Identifier Stress-Testing
  // ==========================================================================
  group('4. Manifest Schema, SemVer, and Identifier Stress-Testing', () {
    test('4.1 SemVer 2.0.0 strict regex conformance and adversarial strings', () {
      final validSemVers = [
        '0.0.1',
        '1.0.0',
        '1.2.3',
        '10.20.30',
        '1.0.0-alpha',
        '1.0.0-alpha.1',
        '1.0.0-0.3.7',
        '1.0.0-x.7.z.92',
        '1.0.0-x-y-z.-',
        '1.0.0+20130313144700',
        '1.0.0-beta+exp.sha.5114f85',
        '2.0.0-rc.1+build.123',
      ];

      for (final v in validSemVers) {
        expect(SourceManifest.isValidSemVer(v), isTrue, reason: 'Valid SemVer rejected: "$v"');
      }

      final invalidSemVers = [
        'v1.0.0', // 'v' prefix
        '1.0', // missing patch
        '1', // missing minor and patch
        '01.0.0', // leading zero in major
        '1.01.0', // leading zero in minor
        '1.0.01', // leading zero in patch
        'beta', // pure string
        '1.0.0-', // empty prerelease
        '1.0.0+', // empty build
        '1.0.0.0', // four-part version
        '1.0.0-alpha..1', // double dot in prerelease
        '1.0.0-01', // leading zero in numeric prerelease segment
        '1.0.0+invalid~char', // invalid character '~'
        '1.0.0 beta', // whitespace
        ' 1.0.0', // leading whitespace
        '1.0.0 ', // trailing whitespace
      ];

      for (final v in invalidSemVers) {
        expect(SourceManifest.isValidSemVer(v), isFalse, reason: 'Invalid SemVer accepted by isValidSemVer: "$v"');
      }

      // validateManifest rejection for malformed versions
      final malformedVersions = [
        'v1.0.0',
        '1.0',
        '1',
        '01.0.0',
        '1.01.0',
        '1.0.01',
        'beta',
        '1.0.0-',
        '1.0.0+',
        '1.0.0.0',
        '1.0.0-alpha..1',
        '1.0.0-01',
        '1.0.0+invalid~char',
        '1.0.0 beta',
      ];

      for (final v in malformedVersions) {
        final manifestJson = createValidManifestMap();
        manifestJson['version'] = v;
        final valRes = validator.validateManifest(manifestJson);
        expect(
          valRes.isValid,
          isFalse,
          reason: 'validateManifest accepted invalid SemVer "$v"',
        );
        expect(valRes.errorCode, IngestionErrorCode.unsupportedVersion);
      }

      // Empty or whitespace-only version returns missingRequiredField
      for (final emptyVer in ['', '   ']) {
        final manifestJson = createValidManifestMap();
        manifestJson['version'] = emptyVer;
        final valRes = validator.validateManifest(manifestJson);
        expect(valRes.isValid, isFalse);
        expect(valRes.errorCode, IngestionErrorCode.missingRequiredField);
      }
    });

    test('4.2 Package identifier regex stress-testing', () {
      final validIds = [
        'custom_n5',
        'n5.strokes',
        'package-1',
        'a',
        '0',
        'test_pkg.v1-extra',
        'jlpt_n5_expansion',
        'kanji-grade-1',
        'source.dict.2026',
      ];

      for (final id in validIds) {
        expect(SourceManifest.isValidId(id), isTrue, reason: 'Valid ID rejected: "$id"');
      }

      final invalidIds = [
        'Custom_Pkg', // uppercase letters
        'UPPER',
        'pkg id', // whitespace
        'pkg\tid',
        r'pkg$evil', // special char $
        'pkg@home', // special char @
        'pkg#1', // special char #
        'pkg/sub', // slash
        'pkg\\sub', // backslash
        '_pkg', // leading underscore
        '-pkg', // leading dash
        '.pkg', // leading dot
        'pkg_', // trailing underscore
        'pkg-', // trailing dash
        'pkg.', // trailing dot
        'pkg..id', // consecutive dots
        'pkg__id', // consecutive underscores
        'pkg--id', // consecutive hyphens
        '', // empty
        'a' * 129, // length > 128 chars
      ];

      for (final id in invalidIds) {
        expect(SourceManifest.isValidId(id), isFalse, reason: 'Invalid ID accepted: "$id"');

        final manifestJson = createValidManifestMap();
        manifestJson['id'] = id;
        final valRes = validator.validateManifest(manifestJson);
        expect(valRes.isValid, isFalse, reason: 'validateManifest accepted invalid ID "$id"');
      }
    });

    test('4.3 Rejects manifests missing required fields or having unsupported formatVersion', () {
      // Missing id
      final noId = createValidManifestMap()..remove('id');
      expect(validator.validateManifest(noId).errorCode, IngestionErrorCode.missingRequiredField);

      // Missing name
      final noName = createValidManifestMap()..remove('name');
      expect(validator.validateManifest(noName).errorCode, IngestionErrorCode.missingRequiredField);

      // Missing version
      final noVer = createValidManifestMap()..remove('version');
      expect(validator.validateManifest(noVer).errorCode, IngestionErrorCode.missingRequiredField);

      // Empty capabilities
      final emptyCaps = createValidManifestMap()..['capabilities'] = <String>[];
      expect(validator.validateManifest(emptyCaps).errorCode, IngestionErrorCode.invalidManifest);

      // Unrecognized capability
      final badCaps = createValidManifestMap()..['capabilities'] = ['video'];
      expect(validator.validateManifest(badCaps).errorCode, IngestionErrorCode.invalidManifest);

      // Unsupported formatVersion
      final badFmt = createValidManifestMap()..['formatVersion'] = 99;
      expect(validator.validateManifest(badFmt).errorCode, IngestionErrorCode.unsupportedVersion);
    });
  });

  // ==========================================================================
  // Section 5: Staging Purge & Zero-Leakage Invariance Gate
  // ==========================================================================
  group('5. Staging Purge and Zero-Leakage Invariance Gate', () {
    test('5.1 Verified: 0 leftover files in staging and 0 leaked packages across multiple failures', () async {
      // 1. Initial invariant: stagingRoot and packagesRoot are empty
      expect((await stagingManager.stagingRoot.list().toList()).isEmpty, isTrue);
      expect((await stagingManager.packagesRoot.list().toList()).isEmpty, isTrue);

      // 2. Fire 10 diverse failure payloads against OfflinePackageLoader
      for (var i = 0; i < 10; i++) {
        final archive = Archive();
        final pkgId = 'failure_test_pkg_$i';

        if (i % 3 == 0) {
          // Zip-Slip attempt
          archive.addFile(ArchiveFile.string('manifest.json', jsonEncode(createValidManifestMap(id: pkgId))));
          archive.addFile(ArchiveFile.string('metadata.json', createValidMetadataJson()));
          archive.addFile(ArchiveFile.string('../../leak_$i.txt', 'leak'));
        } else if (i % 3 == 1) {
          // Corrupted metadata schema
          archive.addFile(ArchiveFile.string('manifest.json', jsonEncode(createValidManifestMap(id: pkgId))));
          archive.addFile(ArchiveFile.string('metadata.json', '{"malformed": true}')); // not an array
        } else {
          // Malformed manifest SemVer
          final badManifest = createValidManifestMap(id: pkgId)..['version'] = 'v1.0';
          archive.addFile(ArchiveFile.string('manifest.json', jsonEncode(badManifest)));
          archive.addFile(ArchiveFile.string('metadata.json', createValidMetadataJson()));
        }

        final zipBytes = ZipEncoder().encode(archive)!;
        final zipFile = File(p.join(tempRootDir.path, 'fail_pkg_$i.zip'));
        await zipFile.writeAsBytes(zipBytes);

        final res = await offlineLoader.loadFromArchive(zipFile);
        expect(res.isSuccess, isFalse, reason: 'Payload $i should fail');
      }

      // 3. Invariance check after all failures:
      // A: No directories or files lingering in .staging
      final remainingStaging = await stagingManager.stagingRoot.list().toList();
      expect(
        remainingStaging.isEmpty,
        isTrue,
        reason: 'Staging directory contains ${remainingStaging.length} orphaned directories after failures!',
      );

      // B: No packages promoted in packagesRoot
      final remainingPackages = await stagingManager.packagesRoot.list().toList();
      expect(
        remainingPackages.isEmpty,
        isTrue,
        reason: 'packagesRoot contains ${remainingPackages.length} leaked packages!',
      );
    });
  });
}
