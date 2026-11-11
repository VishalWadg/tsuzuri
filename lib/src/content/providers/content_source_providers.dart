import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../data/models.dart';
import '../../providers/app_providers.dart';
import '../ingestion/loaders/offline_package_loader.dart';
import '../ingestion/loaders/online_source_fetcher.dart';
import '../ingestion/staging/package_staging_manager.dart';
import '../ingestion/validation/source_validator.dart';
import '../registry/content_repository.dart';
import '../registry/content_source_registry.dart';
import '../services/content_source_manager.dart';
import '../sources/bundled/bundled_metadata_source.dart';
import '../sources/bundled/bundled_stroke_source.dart';
import '../sources/bundled/default_tts_audio_source.dart';

/// Overridable base application documents directory (populated by `main.dart` and widget tests).
final appDocumentsDirectoryProvider = Provider<Directory?>((ref) => null);

/// Riverpod provider exposing an initialized [ContentSourceRegistry]
/// pre-populated with zero-configuration bundled adapters at priority 0.
final contentSourceRegistryProvider = Provider<ContentSourceRegistry>((ref) {
  final contentDb = ref.watch(contentDatabaseProvider);
  final speechService = ref.watch(speechServiceProvider);

  final registry = ContentSourceRegistry();

  // Permanently anchor bundled default sources at base priority 0
  registry.registerMetadataSource(
    BundledMetadataSource(contentDb: contentDb),
    priority: 0,
  );
  registry.registerStrokeSource(
    BundledStrokeSource(contentDb: contentDb),
    priority: 0,
  );
  registry.registerAudioSource(
    DefaultTtsAudioSource(
      speechService: speechService,
      contentDb: contentDb,
    ),
    priority: 0,
  );

  void onRegistryChanged() {
    try {
      ref.read(progressRefreshTriggerProvider.notifier).state++;
    } catch (_) {}
  }

  registry.addListener(onRegistryChanged);

  ref.onDispose(() {
    registry.removeListener(onRegistryChanged);
    registry.dispose();
  });

  return registry;
});

/// Riverpod provider exposing the composite [ContentRepository] facade
/// backed by [contentSourceRegistryProvider].
final contentRepositoryProvider = Provider<ContentRepository>((ref) {
  final registry = ref.watch(contentSourceRegistryProvider);
  final repository = ContentRepository(registry: registry);

  ref.onDispose(repository.dispose);

  return repository;
});

/// Provider for isolated two-phase package staging & permanent storage under `<appDocDir>/content_sources`.
final packageStagingManagerProvider = Provider<PackageStagingManager>((ref) {
  final docDir = ref.watch(appDocumentsDirectoryProvider);
  final baseDir = docDir != null
      ? Directory(p.join(docDir.path, 'content_sources'))
      : Directory(p.join(Directory.systemTemp.path, 'tsuzuri_content_sources'));
  return PackageStagingManager(baseDirectory: baseDir);
});

/// Shared [SourceValidator] for verifying manifest schemas, checksums, and stroke structures.
final sourceValidatorProvider = Provider<SourceValidator>((ref) => SourceValidator());

/// Provider for ingesting offline `.zip`, directory, or `.json` custom packages.
final offlinePackageLoaderProvider = Provider<OfflinePackageLoader>((ref) {
  return OfflinePackageLoader(
    stagingManager: ref.watch(packageStagingManagerProvider),
    validator: ref.watch(sourceValidatorProvider),
  );
});

/// Overridable HTTP client used by [onlineSourceFetcherProvider].
final sourceHttpClientProvider = Provider<HttpClient>((ref) {
  final client = HttpClient();
  ref.onDispose(client.close);
  return client;
});

/// Provider for fetching, validating, and staging online HTTP/HTTPS sources.
final onlineSourceFetcherProvider = Provider<OnlineSourceFetcher>((ref) {
  return OnlineSourceFetcher(
    client: ref.watch(sourceHttpClientProvider),
    stagingManager: ref.watch(packageStagingManagerProvider),
    validator: ref.watch(sourceValidatorProvider),
  );
});

/// Central service orchestrating custom package persistence, hydration, priority, and removal.
final contentSourceManagerProvider = Provider<ContentSourceManager>((ref) {
  return ContentSourceManager(
    registry: ref.watch(contentSourceRegistryProvider),
    userDb: ref.watch(userDatabaseProvider),
    stagingManager: ref.watch(packageStagingManagerProvider),
    offlineLoader: ref.watch(offlinePackageLoaderProvider),
    onlineFetcher: ref.watch(onlineSourceFetcherProvider),
  );
});

/// Reactive list of installed custom content sources persisted in [UserDatabase].
final installedSourcesProvider = Provider<List<InstalledSourceRecord>>((ref) {
  ref.watch(contentSourceRegistryVersionProvider);
  ref.watch(progressRefreshTriggerProvider);
  final userDb = ref.watch(userDatabaseProvider);
  return userDb.getInstalledSources();
});

/// Reactive count of total unique Kanji across all active bundled & custom sources.
final totalKanjiCountProvider = FutureProvider<int>((ref) async {
  ref.watch(contentSourceRegistryVersionProvider);
  final repo = ref.watch(contentRepositoryProvider);
  return repo.getTotalCharacterCount();
});

/// Reactive ordered list of all Kanji across all active bundled & custom sources.
final allKanjiOrderedProvider = FutureProvider<List<KanjiCharacter>>((ref) async {
  ref.watch(contentSourceRegistryVersionProvider);
  final repo = ref.watch(contentRepositoryProvider);
  return repo.getAllKanjiOrdered();
});
