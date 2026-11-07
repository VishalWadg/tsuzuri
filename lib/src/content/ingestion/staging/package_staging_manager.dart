import 'dart:io';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import '../security/zip_slip_guard.dart';

/// Manages isolated two-phase staging, atomic promotion via 3-way swap,
/// rollback, and orphan cleanup for ingested packages.
class PackageStagingManager {
  /// Base directory hosting `.staging/`, `.backups/`, and `packages/`.
  final Directory baseDirectory;

  PackageStagingManager({required this.baseDirectory});

  Directory get stagingRoot => Directory(p.join(baseDirectory.path, '.staging'));
  Directory get backupsRoot => Directory(p.join(baseDirectory.path, '.backups'));
  Directory get packagesRoot => Directory(p.join(baseDirectory.path, 'packages'));

  /// Initializes directory structure if it does not already exist.
  Future<void> initialize() async {
    if (!await stagingRoot.exists()) await stagingRoot.create(recursive: true);
    if (!await backupsRoot.exists()) await backupsRoot.create(recursive: true);
    if (!await packagesRoot.exists()) await packagesRoot.create(recursive: true);
  }

  /// Allocates a clean, isolated staging sandbox for [packageId].
  Future<Directory> createStagingDirectory(String packageId) async {
    await initialize();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final dir = Directory(p.join(stagingRoot.path, '${packageId}_$timestamp'));
    await dir.create(recursive: true);
    return dir;
  }

  /// Extracts [archive] safely into [stagingDir] using [ZipSlipGuard].
  ///
  /// Enforces:
  /// - No symbolic links or null bytes.
  /// - Path traversal rejection (`../../` or absolute paths).
  /// - Boundary check against destination sandbox.
  /// - Archive size limits.
  Future<void> extractArchive(Archive archive, Directory stagingDir) async {
    var totalBytes = 0;
    final entryCount = archive.files.length;

    for (final file in archive.files) {
      if (file.isFile) {
        final content = file.content as List<int>;
        totalBytes += content.length;
        ZipSlipGuard.verifyResourceLimits(
          entryCount: entryCount,
          totalUncompressedBytes: totalBytes,
          singleFileBytes: content.length,
        );
      }
    }

    for (final file in archive.files) {
      final verifiedPath = ZipSlipGuard.resolveAndVerifyEntry(
        stagingDir.path,
        file.name,
        isSymbolicLink: file.isSymbolicLink,
      );

      if (file.isFile) {
        final parentDir = Directory(p.dirname(verifiedPath));
        if (!await parentDir.exists()) {
          await parentDir.create(recursive: true);
        }
        final targetFile = File(verifiedPath);
        await targetFile.writeAsBytes(file.content as List<int>, flush: true);
      } else {
        final dir = Directory(verifiedPath);
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
      }
    }
  }

  /// Recursively copies a source directory into [stagingDir], validating every path.
  Future<void> copyDirectoryToStaging(Directory sourceDir, Directory stagingDir) async {
    if (!await sourceDir.exists()) {
      throw FileSystemException('Source directory does not exist', sourceDir.path);
    }

    final entities = await sourceDir.list(recursive: true, followLinks: false).toList();
    for (final entity in entities) {
      final relPath = p.relative(entity.path, from: sourceDir.path);
      final verifiedPath = ZipSlipGuard.resolveAndVerifyEntry(
        stagingDir.path,
        relPath,
        isSymbolicLink: entity is Link,
      );

      if (entity is File) {
        final parentDir = Directory(p.dirname(verifiedPath));
        if (!await parentDir.exists()) {
          await parentDir.create(recursive: true);
        }
        await entity.copy(verifiedPath);
      } else if (entity is Directory) {
        final targetSubDir = Directory(verifiedPath);
        if (!await targetSubDir.exists()) {
          await targetSubDir.create(recursive: true);
        }
      }
    }
  }

  /// Promotes [stagingDir] to `packages/<packageId>` using an atomic 3-way swap.
  ///
  /// On failure, restores the previous active package from backup and removes [stagingDir].
  Future<Directory> promoteStagedPackage({
    required Directory stagingDir,
    required String packageId,
  }) async {
    await initialize();
    final targetDir = Directory(p.join(packagesRoot.path, packageId));
    Directory? backupDir;

    try {
      // 1. If target already exists, move to .backups/
      if (await targetDir.exists()) {
        final ts = DateTime.now().millisecondsSinceEpoch;
        backupDir = Directory(p.join(backupsRoot.path, '${packageId}_$ts'));
        await targetDir.rename(backupDir.path);
      }

      // 2. Move staging sandbox to target
      await stagingDir.rename(targetDir.path);

      // 3. Promotion succeeded: delete backup
      if (backupDir != null && await backupDir.exists()) {
        await backupDir.delete(recursive: true);
      }

      return targetDir;
    } catch (e) {
      // Rollback: restore backup if target was displaced
      if (backupDir != null && await backupDir.exists()) {
        try {
          if (await targetDir.exists()) {
            await targetDir.delete(recursive: true);
          }
          await backupDir.rename(targetDir.path);
        } catch (_) {
          // Log rollback failure
        }
      }

      // Ensure staging dir is cleaned
      await purgeStagingDirectory(stagingDir);
      rethrow;
    }
  }

  /// Purges an ephemeral staging directory cleanly.
  Future<void> purgeStagingDirectory(Directory stagingDir) async {
    try {
      if (await stagingDir.exists()) {
        await stagingDir.delete(recursive: true);
      }
    } catch (_) {
      // Tolerate failure if already removed or locked temporarily
    }
  }

  /// Cleans up stale staging or backup directories left behind by abnormal termination.
  Future<int> cleanupOrphans({
    Duration staleThreshold = const Duration(minutes: 10),
  }) async {
    var cleanedCount = 0;
    final now = DateTime.now();

    for (final root in [stagingRoot, backupsRoot]) {
      if (await root.exists()) {
        await for (final entity in root.list(followLinks: false)) {
          if (entity is Directory) {
            try {
              final stat = await entity.stat();
              if (now.difference(stat.modified) > staleThreshold) {
                await entity.delete(recursive: true);
                cleanedCount++;
              }
            } catch (_) {}
          }
        }
      }
    }

    return cleanedCount;
  }
}
