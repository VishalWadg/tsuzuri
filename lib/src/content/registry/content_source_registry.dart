import 'dart:developer' as developer;
import '../../matching/stroke_matcher.dart';
import '../contracts/kanji_audio_source.dart';
import '../contracts/kanji_metadata_source.dart';
import '../contracts/kanji_stroke_source.dart';

/// Error logging signature for registry exception containment.
typedef RegistryErrorLogger = void Function(
  String message, {
  required String sourceId,
  Object? error,
  StackTrace? stackTrace,
});

/// Internal registration metadata wrapper tracking source, priority, and sequence.
class _RegisteredSource<T> {
  final T source;
  final int priority;
  final int sequence;
  final String sourceId;
  final bool isBundledDefault;

  _RegisteredSource({
    required this.source,
    required this.priority,
    required this.sequence,
    required this.sourceId,
    required this.isBundledDefault,
  });
}

/// Central registry managing active prioritized content source fallback chains.
class ContentSourceRegistry {
  final List<_RegisteredSource<IKanjiMetadataSource>> _metadataSources = [];
  final List<_RegisteredSource<IKanjiStrokeSource>> _strokeSources = [];
  final List<_RegisteredSource<IKanjiAudioSource>> _audioSources = [];
  int _sequenceCounter = 0;

  final List<void Function()> _listeners = [];
  int _version = 0;
  bool _lastMutationWasRemoval = false;

  /// Monotonically increasing revision counter incremented on every source mutation.
  int get version => _version;

  /// Whether the most recent registry mutation was a source unregistration or removal.
  bool get lastMutationWasRemoval => _lastMutationWasRemoval;

  /// Registers a [listener] callback invoked whenever registered sources change.
  void addListener(void Function() listener) => _listeners.add(listener);

  /// Removes a previously registered [listener].
  void removeListener(void Function() listener) => _listeners.remove(listener);

  /// Disposes registry listeners.
  void dispose() => _listeners.clear();

  void _notifyListeners() {
    _version++;
    for (final listener in List.of(_listeners)) {
      try {
        listener();
      } catch (e, st) {
        _logException('notifyListeners', 'registry_listener', e, st);
      }
    }
  }

  /// Optional custom error logger. If null, logs to [developer.log].
  final RegistryErrorLogger? errorLogger;

  ContentSourceRegistry({this.errorLogger});

  // ==========================================================================
  // Registration Methods
  // ==========================================================================

  /// Registers a metadata provider with the specified priority.
  /// Higher priority numbers are queried first.
  /// Bundled sources (`isBundledDefault == true`) are permanently anchored at the tail.
  void registerMetadataSource(IKanjiMetadataSource source, {int priority = 0}) {
    _validateRegistration(source.sourceId, source.isBundledDefault, _metadataSources);
    _metadataSources.removeWhere((e) => e.sourceId == source.sourceId);
    _metadataSources.add(_RegisteredSource(
      source: source,
      priority: priority,
      sequence: _sequenceCounter++,
      sourceId: source.sourceId,
      isBundledDefault: source.isBundledDefault,
    ));
    _sortChain(_metadataSources);
    _lastMutationWasRemoval = false;
    _notifyListeners();
  }

  /// Registers a stroke provider with the specified priority.
  void registerStrokeSource(IKanjiStrokeSource source, {int priority = 0}) {
    _validateRegistration(source.sourceId, source.isBundledDefault, _strokeSources);
    _strokeSources.removeWhere((e) => e.sourceId == source.sourceId);
    _strokeSources.add(_RegisteredSource(
      source: source,
      priority: priority,
      sequence: _sequenceCounter++,
      sourceId: source.sourceId,
      isBundledDefault: source.isBundledDefault,
    ));
    _sortChain(_strokeSources);
    _lastMutationWasRemoval = false;
    _notifyListeners();
  }

  /// Registers an audio provider with the specified priority.
  void registerAudioSource(IKanjiAudioSource source, {int priority = 0}) {
    _validateRegistration(source.sourceId, source.isBundledDefault, _audioSources);
    _audioSources.removeWhere((e) => e.sourceId == source.sourceId);
    _audioSources.add(_RegisteredSource(
      source: source,
      priority: priority,
      sequence: _sequenceCounter++,
      sourceId: source.sourceId,
      isBundledDefault: source.isBundledDefault,
    ));
    _sortChain(_audioSources);
    _lastMutationWasRemoval = false;
    _notifyListeners();
  }

  /// Unregisters custom sources matching [sourceId] across all chains.
  /// Throws [UnsupportedError] if [sourceId] belongs to a bundled default source.
  void unregisterSource(String sourceId) {
    final isBundled = _metadataSources.any((e) => e.sourceId == sourceId && e.isBundledDefault) ||
        _strokeSources.any((e) => e.sourceId == sourceId && e.isBundledDefault) ||
        _audioSources.any((e) => e.sourceId == sourceId && e.isBundledDefault);

    if (isBundled) {
      throw UnsupportedError(
        'Cannot unregister bundled default source "$sourceId". '
        'Bundled sources are permanently anchored defaults.',
      );
    }

    _metadataSources.removeWhere((e) => e.sourceId == sourceId);
    _strokeSources.removeWhere((e) => e.sourceId == sourceId);
    _audioSources.removeWhere((e) => e.sourceId == sourceId);
    _lastMutationWasRemoval = true;
    _notifyListeners();
  }

  /// Unregisters all custom sources across all chains while keeping bundled defaults.
  void clearCustomSources() {
    _metadataSources.removeWhere((e) => !e.isBundledDefault);
    _strokeSources.removeWhere((e) => !e.isBundledDefault);
    _audioSources.removeWhere((e) => !e.isBundledDefault);
    _lastMutationWasRemoval = true;
    _notifyListeners();
  }

  // ==========================================================================
  // Active Source Inspection (Unmodifiable query-ordered views)
  // ==========================================================================

  List<IKanjiMetadataSource> get activeMetadataSources =>
      List.unmodifiable(_metadataSources.map((e) => e.source));

  List<IKanjiStrokeSource> get activeStrokeSources =>
      List.unmodifiable(_strokeSources.map((e) => e.source));

  List<IKanjiAudioSource> get activeAudioSources =>
      List.unmodifiable(_audioSources.map((e) => e.source));

  bool containsSource(String sourceId) =>
      _metadataSources.any((e) => e.sourceId == sourceId) ||
      _strokeSources.any((e) => e.sourceId == sourceId) ||
      _audioSources.any((e) => e.sourceId == sourceId);

  bool isBundledDefault(String sourceId) =>
      _metadataSources.any((e) => e.sourceId == sourceId && e.isBundledDefault) ||
      _strokeSources.any((e) => e.sourceId == sourceId && e.isBundledDefault) ||
      _audioSources.any((e) => e.sourceId == sourceId && e.isBundledDefault);

  // ==========================================================================
  // Multi-Tier Fallback Query Dispatch with Exception Containment
  // ==========================================================================

  /// Queries the metadata chain in priority order for [codepoint].
  /// Falls back to subsequent sources if a source returns null or throws.
  Future<KanjiMetadataEntry?> queryMetadata(int codepoint) async {
    if (codepoint <= 0 || codepoint > 0x10FFFF) return null;
    for (final entry in List.of(_metadataSources)) {
      try {
        final meta = await entry.source.getMetadata(codepoint);
        if (meta != null) return meta;
      } catch (e, st) {
        _logException('queryMetadata', entry.sourceId, e, st);
      }
    }
    return null;
  }

  /// Alias for [queryMetadata].
  Future<KanjiMetadataEntry?> getMetadata(int codepoint) => queryMetadata(codepoint);

  /// Queries the stroke vector chain in priority order for [codepoint].
  Future<List<ReferenceStroke>?> queryStrokes(int codepoint) async {
    if (codepoint <= 0 || codepoint > 0x10FFFF) return null;
    for (final entry in List.of(_strokeSources)) {
      try {
        final strokes = await entry.source.getStrokes(codepoint);
        if (strokes != null && strokes.isNotEmpty) return strokes;
      } catch (e, st) {
        _logException('queryStrokes', entry.sourceId, e, st);
      }
    }
    return null;
  }

  /// Alias for [queryStrokes].
  Future<List<ReferenceStroke>?> getStrokes(int codepoint) => queryStrokes(codepoint);

  /// Checks whether any active stroke provider has strokes for [codepoint].
  Future<bool> containsStrokes(int codepoint) async {
    if (codepoint <= 0 || codepoint > 0x10FFFF) return false;
    for (final entry in List.of(_strokeSources)) {
      try {
        if (await entry.source.containsStrokes(codepoint)) return true;
      } catch (e, st) {
        _logException('containsStrokes', entry.sourceId, e, st);
      }
    }
    return false;
  }

  /// Queries the audio pronunciation chain for [codepoint] and optional [reading].
  Future<AudioPronunciation?> queryAudio(int codepoint, {String? reading}) async {
    for (final entry in List.of(_audioSources)) {
      try {
        final audio = await entry.source.getAudio(codepoint, reading: reading);
        if (audio != null) return audio;
      } catch (e, st) {
        _logException('queryAudio', entry.sourceId, e, st);
      }
    }
    return null;
  }

  /// Alias for [queryAudio].
  Future<AudioPronunciation?> getAudio(int codepoint, {String? reading}) =>
      queryAudio(codepoint, reading: reading);

  /// Fast check for audio presence across providers.
  Future<bool> containsAudio(int codepoint, {String? reading}) async {
    for (final entry in List.of(_audioSources)) {
      try {
        if (await entry.source.containsAudio(codepoint, reading: reading)) return true;
      } catch (e, st) {
        _logException('containsAudio', entry.sourceId, e, st);
      }
    }
    return false;
  }

  /// Collects unique codepoints across all active metadata providers.
  /// Preserves priority order and eliminates duplicates.
  Future<List<int>> queryAllCodepoints() async {
    final seen = <int>{};
    for (final entry in List.of(_metadataSources)) {
      try {
        final cps = await entry.source.getAllCodepoints();
        seen.addAll(cps);
      } catch (e, st) {
        _logException('queryAllCodepoints', entry.sourceId, e, st);
      }
    }
    return seen.toList();
  }

  /// Total count of unique Kanji characters across all active metadata sources.
  Future<int> queryTotalCharacterCount() async {
    final codepoints = await queryAllCodepoints();
    return codepoints.length;
  }

  /// Resolves meaning distractors with fallback across metadata sources.
  Future<List<String>> queryMeaningDistractors(
    KanjiMetadataEntry target, {
    int count = 3,
  }) async {
    if (count <= 0) return const [];
    final targetMeaningsLower = target.meanings.map((m) => m.toLowerCase().trim()).toSet();
    final accumulated = <String>{};

    for (final entry in List.of(_metadataSources)) {
      try {
        final distractors = await entry.source.generateMeaningDistractors(
          target,
          count: count,
        );
        for (final d in distractors) {
          final trimmed = d.trim();
          if (trimmed.isNotEmpty &&
              !targetMeaningsLower.contains(trimmed.toLowerCase()) &&
              !accumulated.contains(trimmed)) {
            accumulated.add(trimmed);
            if (accumulated.length >= count) {
              return accumulated.take(count).toList();
            }
          }
        }
      } catch (e, st) {
        _logException('queryMeaningDistractors', entry.sourceId, e, st);
      }
    }
    return accumulated.toList();
  }

  /// Resolves reading distractors with fallback across metadata sources.
  Future<List<String>> queryReadingDistractors(
    KanjiMetadataEntry target, {
    int count = 3,
  }) async {
    if (count <= 0) return const [];
    final targetReadings = {...target.onyomi, ...target.kunyomi}.map((r) => r.trim()).toSet();
    final accumulated = <String>{};

    for (final entry in List.of(_metadataSources)) {
      try {
        final distractors = await entry.source.generateReadingDistractors(
          target,
          count: count,
        );
        for (final d in distractors) {
          final trimmed = d.trim();
          if (trimmed.isNotEmpty &&
              !targetReadings.contains(trimmed) &&
              !accumulated.contains(trimmed)) {
            accumulated.add(trimmed);
            if (accumulated.length >= count) {
              return accumulated.take(count).toList();
            }
          }
        }
      } catch (e, st) {
        _logException('queryReadingDistractors', entry.sourceId, e, st);
      }
    }
    return accumulated.toList();
  }

  // ==========================================================================
  // Internal Helpers & Invariant Enforcement
  // ==========================================================================

  void _validateRegistration<T>(
    String sourceId,
    bool isBundledDefault,
    List<_RegisteredSource<T>> list,
  ) {
    final existingBundled = list.any((e) => e.sourceId == sourceId && e.isBundledDefault);
    if (existingBundled && !isBundledDefault) {
      throw ArgumentError(
        'Cannot overwrite permanent bundled default source "$sourceId" with a custom source.',
      );
    }
  }

  void _sortChain<T>(List<_RegisteredSource<T>> list) {
    list.sort((a, b) {
      // Invariant: Bundled sources are permanently anchored at the tail.
      if (a.isBundledDefault && !b.isBundledDefault) return 1;
      if (!a.isBundledDefault && b.isBundledDefault) return -1;

      // Invariant: Higher priority numbers are queried first.
      final pComp = b.priority.compareTo(a.priority);
      if (pComp != 0) return pComp;

      // Deterministic tie-breaker: FIFO registration order.
      return a.sequence.compareTo(b.sequence);
    });
  }

  void _logException(String op, String sourceId, Object error, StackTrace st) {
    final msg = 'ContentSourceRegistry.$op error on source "$sourceId": $error';
    if (errorLogger != null) {
      errorLogger!(msg, sourceId: sourceId, error: error, stackTrace: st);
    } else {
      developer.log(msg, name: 'ContentSourceRegistry', error: error, stackTrace: st);
    }
  }
}
