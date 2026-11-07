import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/app_providers.dart';
import '../registry/content_repository.dart';
import '../registry/content_source_registry.dart';
import '../sources/bundled/bundled_metadata_source.dart';
import '../sources/bundled/bundled_stroke_source.dart';
import '../sources/bundled/default_tts_audio_source.dart';

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
