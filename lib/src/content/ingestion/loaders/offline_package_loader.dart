import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../models/source_manifest.dart';
import '../models/ingestion_result.dart';
import '../security/zip_slip_guard.dart';
import '../staging/package_staging_manager.dart';
import '../validation/source_validator.dart';

/// Contract for loading and ingesting offline packages.
abstract interface class IOfflinePackageLoader {
  Future<IngestionResult> loadFromArchive(File zipFile);
  Future<IngestionResult> loadFromDirectory(Directory directory);
  Future<IngestionResult> loadFromJsonFile(File jsonFile);
}

/// Offline package loader supporting ZIP archives, directory trees,
/// and standalone JSON packages with atomic staging and rollback.
class OfflinePackageLoader implements IOfflinePackageLoader {
  final PackageStagingManager _stagingManager;
  final SourceValidator _validator;

  OfflinePackageLoader({
    required PackageStagingManager stagingManager,
    required SourceValidator validator,
  })  : _stagingManager = stagingManager,
        _validator = validator;

  @override
  Future<IngestionResult> loadFromArchive(File zipFile) async {
    if (!await zipFile.exists()) {
      return IngestionResult.failure(
        errorCode: IngestionErrorCode.missingAssetFile,
        errorMessage: 'Archive file not found: ${zipFile.path}',
      );
    }

    List<int> bytes;
    try {
      bytes = await zipFile.readAsBytes();
    } catch (e) {
      return IngestionResult.failure(
        errorCode: IngestionErrorCode.corruptArchive,
        errorMessage: 'Failed to read archive bytes: $e',
      );
    }

    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes, verify: true);
    } catch (e) {
      return IngestionResult.failure(
        errorCode: IngestionErrorCode.invalidArchive,
        errorMessage: 'Malformed or unreadable ZIP archive: $e',
      );
    }

    // 1. Locate manifest.json in archive
    ArchiveFile? manifestFile;
    for (final file in archive.files) {
      final normName = file.name.replaceAll('\\', '/');
      if (normName == 'manifest.json' || normName.endsWith('/manifest.json')) {
        manifestFile = file;
        break;
      }
    }

    if (manifestFile == null) {
      return const IngestionResult.failure(
        errorCode: IngestionErrorCode.missingManifest,
        errorMessage: 'Archive does not contain required "manifest.json".',
      );
    }

    // Pre-parse manifest to obtain package ID
    SourceManifest tempManifest;
    try {
      final manifestJsonStr = utf8.decode(manifestFile.content as List<int>);
      final decoded = jsonDecode(manifestJsonStr) as Map<String, dynamic>;
      final valRes = _validator.validateManifest(decoded);
      if (!valRes.isValid) {
        return IngestionResult.failure(
          errorCode: valRes.errorCode!,
          errorMessage: valRes.errorMessage!,
        );
      }
      tempManifest = SourceManifest.fromJson(decoded);
    } catch (e) {
      return IngestionResult.failure(
        errorCode: IngestionErrorCode.invalidManifest,
        errorMessage: 'Invalid manifest inside archive: $e',
      );
    }

    // 2. Allocate isolated staging sandbox
    final stagingDir = await _stagingManager.createStagingDirectory(tempManifest.id);

    try {
      // 3. Extract with 6-layer Zip-Slip defense
      await _stagingManager.extractArchive(archive, stagingDir);
    } on SecurityException catch (e) {
      await _stagingManager.purgeStagingDirectory(stagingDir);
      return IngestionResult.failure(
        errorCode: IngestionErrorCode.zipSlipDetected,
        errorMessage: e.message,
      );
    } catch (e) {
      await _stagingManager.purgeStagingDirectory(stagingDir);
      return IngestionResult.failure(
        errorCode: IngestionErrorCode.corruptArchive,
        errorMessage: 'Archive extraction failed: $e',
      );
    }

    // 4. Deep validation of staged contents
    final validationResult = await _validator.validatePackageDirectory(stagingDir);
    if (!validationResult.isSuccess) {
      await _stagingManager.purgeStagingDirectory(stagingDir);
      return validationResult;
    }

    // 5. Atomic promotion via 3-way swap
    try {
      final promotedDir = await _stagingManager.promoteStagedPackage(
        stagingDir: stagingDir,
        packageId: validationResult.manifest!.id,
      );

      return IngestionResult.success(
        manifest: validationResult.manifest!,
        packageDirectory: promotedDir.path,
      );
    } catch (e) {
      await _stagingManager.purgeStagingDirectory(stagingDir);
      return IngestionResult.failure(
        errorCode: IngestionErrorCode.storageError,
        errorMessage: 'Failed promoting package to destination directory: $e',
      );
    }
  }

  @override
  Future<IngestionResult> loadFromDirectory(Directory directory) async {
    if (!await directory.exists()) {
      return IngestionResult.failure(
        errorCode: IngestionErrorCode.missingAssetFile,
        errorMessage: 'Source directory does not exist: ${directory.path}',
      );
    }

    final manifestFile = File(p.join(directory.path, 'manifest.json'));
    if (!await manifestFile.exists()) {
      return const IngestionResult.failure(
        errorCode: IngestionErrorCode.missingManifest,
        errorMessage: 'Directory does not contain "manifest.json".',
      );
    }

    SourceManifest tempManifest;
    try {
      final content = await manifestFile.readAsString();
      final decoded = jsonDecode(content) as Map<String, dynamic>;
      final valRes = _validator.validateManifest(decoded);
      if (!valRes.isValid) {
        return IngestionResult.failure(
          errorCode: valRes.errorCode!,
          errorMessage: valRes.errorMessage!,
        );
      }
      tempManifest = SourceManifest.fromJson(decoded);
    } catch (e) {
      return IngestionResult.failure(
        errorCode: IngestionErrorCode.invalidManifest,
        errorMessage: 'Invalid manifest: $e',
      );
    }

    final stagingDir = await _stagingManager.createStagingDirectory(tempManifest.id);

    try {
      await _stagingManager.copyDirectoryToStaging(directory, stagingDir);
    } on SecurityException catch (e) {
      await _stagingManager.purgeStagingDirectory(stagingDir);
      return IngestionResult.failure(
        errorCode: IngestionErrorCode.zipSlipDetected,
        errorMessage: e.message,
      );
    } catch (e) {
      await _stagingManager.purgeStagingDirectory(stagingDir);
      return IngestionResult.failure(
        errorCode: IngestionErrorCode.storageError,
        errorMessage: 'Failed copying directory to staging: $e',
      );
    }

    final valRes = await _validator.validatePackageDirectory(stagingDir);
    if (!valRes.isSuccess) {
      await _stagingManager.purgeStagingDirectory(stagingDir);
      return valRes;
    }

    try {
      final promotedDir = await _stagingManager.promoteStagedPackage(
        stagingDir: stagingDir,
        packageId: valRes.manifest!.id,
      );

      return IngestionResult.success(
        manifest: valRes.manifest!,
        packageDirectory: promotedDir.path,
      );
    } catch (e) {
      await _stagingManager.purgeStagingDirectory(stagingDir);
      return IngestionResult.failure(
        errorCode: IngestionErrorCode.storageError,
        errorMessage: 'Failed promoting directory package: $e',
      );
    }
  }

  @override
  Future<IngestionResult> loadFromJsonFile(File jsonFile) async {
    if (!await jsonFile.exists()) {
      return IngestionResult.failure(
        errorCode: IngestionErrorCode.missingAssetFile,
        errorMessage: 'JSON package file not found: ${jsonFile.path}',
      );
    }

    String content;
    try {
      content = await jsonFile.readAsString();
    } catch (e) {
      return IngestionResult.failure(
        errorCode: IngestionErrorCode.corruptedData,
        errorMessage: 'Failed reading JSON package file: $e',
      );
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(content);
    } catch (e) {
      return IngestionResult.failure(
        errorCode: IngestionErrorCode.schemaMismatch,
        errorMessage: 'Malformed JSON package: $e',
      );
    }

    if (decoded is! Map<String, dynamic>) {
      return const IngestionResult.failure(
        errorCode: IngestionErrorCode.schemaMismatch,
        errorMessage: 'JSON package root must be a JSON object.',
      );
    }

    // Extract manifest
    Map<String, dynamic> manifestMap;
    if (decoded['manifest'] is Map<String, dynamic>) {
      manifestMap = decoded['manifest'] as Map<String, dynamic>;
    } else {
      // Inline manifest format
      manifestMap = Map<String, dynamic>.from(decoded);
    }

    final schemaRes = _validator.validateManifest(manifestMap);
    if (!schemaRes.isValid) {
      return IngestionResult.failure(
        errorCode: schemaRes.errorCode!,
        errorMessage: schemaRes.errorMessage!,
      );
    }

    SourceManifest manifest;
    try {
      manifest = SourceManifest.fromJson(manifestMap);
    } catch (e) {
      return IngestionResult.failure(
        errorCode: IngestionErrorCode.invalidManifest,
        errorMessage: 'Manifest construction error: $e',
      );
    }

    final stagingDir = await _stagingManager.createStagingDirectory(manifest.id);

    try {
      // Write manifest.json
      final targetManifestFile = File(p.join(stagingDir.path, 'manifest.json'));
      await targetManifestFile.writeAsString(jsonEncode(manifest.toJson()));

      // Write metadata if provided
      final rawMeta = decoded['metadata'] ?? decoded['entries'];
      if (rawMeta != null) {
        final metaRel = manifest.metadataPath ?? 'metadata.json';
        final metaFile = File(p.join(stagingDir.path, metaRel));
        await metaFile.parent.create(recursive: true);
        await metaFile.writeAsString(jsonEncode(rawMeta));
      }

      // Write strokes if provided
      final rawStrokes = decoded['strokes'];
      if (rawStrokes != null) {
        final strokesRel = manifest.strokesPath ?? 'strokes.json';
        final strokesFile = File(p.join(stagingDir.path, strokesRel));
        await strokesFile.parent.create(recursive: true);
        await strokesFile.writeAsString(jsonEncode(rawStrokes));
      }

      // Validate
      final valRes = await _validator.validatePackageDirectory(stagingDir);
      if (!valRes.isSuccess) {
        await _stagingManager.purgeStagingDirectory(stagingDir);
        return valRes;
      }

      // Promote
      final promotedDir = await _stagingManager.promoteStagedPackage(
        stagingDir: stagingDir,
        packageId: valRes.manifest!.id,
      );

      return IngestionResult.success(
        manifest: valRes.manifest!,
        packageDirectory: promotedDir.path,
      );
    } catch (e) {
      await _stagingManager.purgeStagingDirectory(stagingDir);
      return IngestionResult.failure(
        errorCode: IngestionErrorCode.storageError,
        errorMessage: 'Failed ingesting JSON package: $e',
      );
    }
  }
}
