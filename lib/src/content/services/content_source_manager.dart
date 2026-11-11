import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

import '../../data/models.dart';
import '../../data/user_db.dart';
import '../ingestion/loaders/offline_package_loader.dart';
import '../ingestion/loaders/online_source_fetcher.dart';
import '../ingestion/models/ingestion_result.dart';
import '../ingestion/models/source_manifest.dart';
import '../ingestion/staging/package_staging_manager.dart';
import '../ingestion/validation/source_validator.dart';
import '../registry/content_source_registry.dart';
import '../sources/custom/custom_audio_source.dart';
import '../sources/custom/custom_metadata_source.dart';
import '../sources/custom/custom_stroke_source.dart';

/// Orchestrates lifecycle, persistence (`installed_sources`), startup hydration,
/// enabling/disabling, priority reordering, and removal of custom content sources.
class ContentSourceManager {
  final ContentSourceRegistry _registry;
  final UserDatabase _userDb;
  final PackageStagingManager _stagingManager;
  final OfflinePackageLoader _offlineLoader;
  final OnlineSourceFetcher _onlineFetcher;

  ContentSourceManager({
    required ContentSourceRegistry registry,
    required UserDatabase userDb,
    required PackageStagingManager stagingManager,
    OfflinePackageLoader? offlineLoader,
    OnlineSourceFetcher? onlineFetcher,
  })  : _registry = registry,
        _userDb = userDb,
        _stagingManager = stagingManager,
        _offlineLoader = offlineLoader ??
            OfflinePackageLoader(
              stagingManager: stagingManager,
              validator: SourceValidator(),
            ),
        _onlineFetcher = onlineFetcher ??
            OnlineSourceFetcher(
              stagingManager: stagingManager,
              validator: SourceValidator(),
            );

  /// All installed custom source records ordered by priority DESC.
  List<InstalledSourceRecord> getInstalledSources() => _userDb.getInstalledSources();

  /// Loads persisted custom sources from `user_progress.db` and mounts enabled
  /// packages into [ContentSourceRegistry] on app launch.
  Future<void> hydrateOnStartup() async {
    await _stagingManager.cleanupOrphans();
    final records = _userDb.getInstalledSources();
    for (final record in records) {
      if (!record.enabled) continue;
      final dir = Directory(record.packageDir);
      if (!await dir.exists()) continue;
      try {
        await _registerPackageFromDisk(record);
      } catch (_) {
        // Skip broken disk package safely without crashing startup; bundled defaults remain intact.
      }
    }
  }

  /// Imports a custom `.zip` archive package, validates it, persists it, and activates it.
  Future<IngestionResult> importArchiveFile(File zipFile) async {
    final result = await _offlineLoader.loadFromArchive(zipFile);
    return _finalizeIngestion(
      result,
      originType: SourceOriginType.offlineArchive,
      originUri: null,
    );
  }

  /// Imports a standalone `.json` package file, validates it, persists it, and activates it.
  Future<IngestionResult> importJsonFile(File jsonFile) async {
    final result = await _offlineLoader.loadFromJsonFile(jsonFile);
    return _finalizeIngestion(
      result,
      originType: SourceOriginType.offlineJson,
      originUri: null,
    );
  }

  /// Imports a custom package directory, validates it, persists it, and activates it.
  Future<IngestionResult> importDirectory(Directory directory) async {
    final result = await _offlineLoader.loadFromDirectory(directory);
    return _finalizeIngestion(
      result,
      originType: SourceOriginType.offlineDir,
      originUri: null,
    );
  }

  /// Fetches, validates, persists, and activates a remote source manifest over HTTP/HTTPS.
  Future<IngestionResult> connectOnlineUrl(
    Uri manifestUri, {
    FetchOptions options = const FetchOptions(),
  }) async {
    final result = await _onlineFetcher.fetchAndInstall(manifestUri, options: options);
    return _finalizeIngestion(
      result,
      originType: SourceOriginType.onlineUrl,
      originUri: manifestUri.toString(),
    );
  }

  /// Re-fetches and updates an already-connected online source by [sourceId].
  Future<IngestionResult> refreshOnlineSource(
    String sourceId, {
    FetchOptions options = const FetchOptions(),
  }) async {
    final record = _userDb.getInstalledSource(sourceId);
    if (record == null || record.originUri == null || record.originUri!.isEmpty) {
      return const IngestionResult.failure(
        errorCode: IngestionErrorCode.missingAssetFile,
        errorMessage: 'Source does not have a remote URL configured.',
      );
    }
    return connectOnlineUrl(Uri.parse(record.originUri!), options: options);
  }

  /// Enables or disables a persisted custom source without deleting its files or FSRS history.
  Future<void> setSourceEnabled(String sourceId, bool enabled) async {
    final existing = _userDb.getInstalledSource(sourceId);
    if (existing == null) return;

    _userDb.setInstalledSourceEnabled(sourceId, enabled);
    if (!enabled) {
      _registry.unregisterSource(sourceId);
      return;
    }

    final dir = Directory(existing.packageDir);
    if (await dir.exists()) {
      await _registerPackageFromDisk(existing.copyWith(enabled: true));
    }
  }

  /// Reorders installed custom sources from highest priority (index 0) to lowest (last).
  Future<void> applyPriorityOrder(List<String> orderedSourceIds) async {
    if (orderedSourceIds.isEmpty) return;

    final updates = <String, int>{};
    final count = orderedSourceIds.length;
    for (var i = 0; i < count; i++) {
      // Custom priorities stay strictly >= 10 above bundled default priority 0.
      updates[orderedSourceIds[i]] = (count - i) * 10;
    }
    _userDb.updateInstalledSourcePriorities(updates);

    // Re-register enabled sources with updated priorities
    for (final record in _userDb.getInstalledSources()) {
      if (!record.enabled) continue;
      if (await Directory(record.packageDir).exists()) {
        await _registerPackageFromDisk(record);
      }
    }
  }

  /// Moves a source one step higher or lower in the custom priority stack.
  Future<void> moveSourcePriority(String sourceId, {required bool moveUp}) async {
    final records = _userDb.getInstalledSources();
    final idx = records.indexWhere((r) => r.sourceId == sourceId);
    if (idx < 0) return;

    final targetIdx = moveUp ? idx - 1 : idx + 1;
    if (targetIdx < 0 || targetIdx >= records.length) return;

    final reordered = records.map((r) => r.sourceId).toList();
    final item = reordered.removeAt(idx);
    reordered.insert(targetIdx, item);

    await applyPriorityOrder(reordered);
  }

  /// Uninstalls a custom source and removes its staged files while preserving all FSRS progress.
  Future<void> removeSource(String sourceId) async {
    try {
      _registry.unregisterSource(sourceId);
    } catch (_) {
      // Ignore if bundled check or not registered
    }

    _userDb.deleteInstalledSource(sourceId);

    final managedPackageDir = Directory(p.join(_stagingManager.packagesRoot.path, sourceId));
    if (await managedPackageDir.exists()) {
      await managedPackageDir.delete(recursive: true);
    }
  }

  Future<IngestionResult> _finalizeIngestion(
    IngestionResult result, {
    required SourceOriginType originType,
    required String? originUri,
  }) async {
    if (!result.isSuccess || result.manifest == null || result.packageDirectory == null) {
      return result;
    }

    final manifest = result.manifest!;
    final existing = _userDb.getInstalledSource(manifest.id);
    final existingSources = _userDb.getInstalledSources();
    final maxPriority = existingSources.isEmpty
        ? 0
        : existingSources.map((s) => s.priority).reduce((a, b) => a > b ? a : b);

    final assignedPriority = existing?.priority ?? (maxPriority + 10);
    final enabled = existing?.enabled ?? true;

    final record = InstalledSourceRecord(
      sourceId: manifest.id,
      name: manifest.name,
      version: manifest.version,
      originType: originType,
      originUri: originUri ?? existing?.originUri,
      packageDir: result.packageDirectory!,
      capabilities: manifest.capabilities.map((c) => c.name).toList(growable: false),
      priority: assignedPriority < 10 ? 10 : assignedPriority,
      enabled: enabled,
      installedAt: DateTime.now().toUtc(),
    );

    _userDb.upsertInstalledSource(record);

    if (record.enabled) {
      await _registerPackageFromDisk(record);
    }

    return result;
  }

  Future<void> _registerPackageFromDisk(InstalledSourceRecord record) async {
    final packageDir = Directory(record.packageDir);
    final manifestFile = File(p.join(packageDir.path, 'manifest.json'));
    if (!await manifestFile.exists()) {
      throw FileSystemException('Package manifest.json missing', manifestFile.path);
    }

    final rawManifest = jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
    final manifest = SourceManifest.fromJson(rawManifest);

    // Clear any stale capability entries for this sourceId before registering updated components
    _registry.unregisterSource(manifest.id);

    if (manifest.capabilities.contains(SourceCapability.metadata)) {
      final metaSource = await CustomMetadataSource.fromDirectory(packageDir, manifest);
      _registry.registerMetadataSource(metaSource, priority: record.priority);
    }

    if (manifest.capabilities.contains(SourceCapability.strokes)) {
      final strokeSource = await CustomStrokeSource.fromDirectory(packageDir, manifest);
      _registry.registerStrokeSource(strokeSource, priority: record.priority);
    }

    if (manifest.capabilities.contains(SourceCapability.audio)) {
      final audioSource = await CustomAudioSource.fromDirectory(packageDir, manifest);
      _registry.registerAudioSource(audioSource, priority: record.priority);
    }
  }
}
