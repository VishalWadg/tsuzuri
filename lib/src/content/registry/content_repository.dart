import 'dart:developer' as developer;
import '../../data/content_db.dart';
import '../../data/models.dart';
import '../../matching/stroke_matcher.dart';
import '../contracts/kanji_audio_source.dart';
import '../contracts/kanji_metadata_source.dart';
import '../sources/bundled/bundled_metadata_source.dart';
import '../sources/bundled/bundled_stroke_source.dart';
import 'content_source_registry.dart';

/// Unified composite content repository facade coordinating metadata, strokes, and audio.
class ContentRepository {
  final ContentSourceRegistry registry;
  final Map<int, KanjiCharacter> _resolvedCache = {};
  void Function()? _registryListener;

  ContentRepository({
    required this.registry,
    bool autoInvalidateCache = true,
  }) {
    if (autoInvalidateCache) {
      _registryListener = () {
        if (registry.lastMutationWasRemoval) {
          clearCache();
        }
      };
      registry.addListener(_registryListener!);
    }
  }

  /// Disposes registry listeners.
  void dispose() {
    if (_registryListener != null) {
      registry.removeListener(_registryListener!);
      _registryListener = null;
    }
  }

  /// Clears internal character resolution cache.
  void clearCache() => _resolvedCache.clear();

  /// Total count of cached resolved characters.
  int get cachedCharacterCount => _resolvedCache.length;

  /// Exposes the underlying bundled [ContentDatabase] if a [BundledMetadataSource] is active.
  ContentDatabase? get bundledContentDatabase {
    for (final source in registry.activeMetadataSources) {
      if (source is BundledMetadataSource) {
        return source.contentDb;
      }
    }
    return null;
  }

  /// Retrieves a unified [KanjiCharacter] by [codepoint] via independent component fallback.
  /// Queries metadata chain, then stroke chain.
  /// Returns null if codepoint is invalid or absent from all active metadata sources.
  Future<KanjiCharacter?> getKanjiByCodepoint(int codepoint) async {
    if (codepoint <= 0 || codepoint > 0x10FFFF) return null;

    final cached = _resolvedCache[codepoint];
    if (cached != null) return cached;

    final startVersion = registry.version;

    // 1. Resolve Metadata through registry chain
    final metadata = await registry.queryMetadata(codepoint);
    if (metadata == null) return null;

    // 2. Resolve Strokes through registry chain (independent fallback)
    final strokes = await registry.queryStrokes(codepoint);

    // 3. Assemble unified character
    final character = metadata.toKanjiCharacter(strokes: strokes ?? const []);
    if (startVersion == registry.version) {
      _resolvedCache[codepoint] = character;
    }
    return character;
  }

  /// Synchronous fast-path for UI queue generation and synchronous widgets.
  /// Checks memory cache, then fast-queries active bundled metadata database or
  /// synchronous custom providers if available.
  KanjiCharacter? getKanjiByCodepointSync(int codepoint) {
    if (codepoint <= 0 || codepoint > 0x10FFFF) return null;

    final cached = _resolvedCache[codepoint];
    if (cached != null) return cached;

    // Fast-path: query active metadata sources synchronously
    for (final source in registry.activeMetadataSources) {
      if (source is BundledMetadataSource) {
        final kanji = source.contentDb.getKanjiByCodepoint(codepoint);
        if (kanji != null) {
          _resolvedCache[codepoint] = kanji;
          return kanji;
        }
      } else {
        // Check if custom source supports synchronous lookup (e.g. in-memory map or preloaded)
        KanjiMetadataEntry? meta;
        try {
          final dynamic dynSource = source;
          meta = dynSource.getMetadataSync(codepoint) as KanjiMetadataEntry?;
        } catch (_) {}
        if (meta == null) {
          try {
            final dynamic dynSource = source;
            final dynamic entries = dynSource.entries;
            if (entries is Map) {
              meta = entries[codepoint] as KanjiMetadataEntry?;
            }
          } catch (_) {}
        }

        if (meta != null) {
          // Also resolve strokes synchronously if available
          List<ReferenceStroke>? strokes;
          for (final strokeSource in registry.activeStrokeSources) {
            if (strokeSource is BundledStrokeSource) {
              strokes = strokeSource.contentDb.getKanjiByCodepoint(codepoint)?.strokes;
              if (strokes != null && strokes.isNotEmpty) break;
            } else {
              final dynamic dynStroke = strokeSource;
              try {
                final s = dynStroke.getStrokesSync(codepoint);
                if (s is List<ReferenceStroke> && s.isNotEmpty) {
                  strokes = s;
                  break;
                }
              } catch (_) {}
              if (strokes == null) {
                try {
                  final dynamic strokesMap = dynStroke.strokesMap;
                  if (strokesMap is Map) {
                    final s = strokesMap[codepoint];
                    if (s is List<ReferenceStroke> && s.isNotEmpty) {
                      strokes = s;
                      break;
                    }
                  }
                } catch (_) {}
              }
            }
          }
          final kanji = meta.toKanjiCharacter(strokes: strokes ?? const []);
          _resolvedCache[codepoint] = kanji;
          return kanji;
        }
      }
    }
    return null;
  }

  /// Merges all unique codepoints from active metadata sources, ordered by:
  /// Grade ASC -> JLPT DESC -> Frequency ASC -> Codepoint ASC.
  Future<List<KanjiCharacter>> getAllKanjiOrdered() async {
    final codepoints = await getOrderedCodepoints();
    final list = <KanjiCharacter>[];

    for (final cp in codepoints) {
      final character = await getKanjiByCodepoint(cp);
      if (character != null) {
        list.add(character);
      }
    }
    return List.unmodifiable(list);
  }

  /// Returns unique codepoints ordered by dictionary presentation rules.
  Future<List<int>> getOrderedCodepoints() async {
    final seen = <int>{};
    final entries = <KanjiMetadataEntry>[];

    for (final source in registry.activeMetadataSources) {
      try {
        final cps = await source.getAllCodepoints();
        for (final cp in cps) {
          if (seen.add(cp)) {
            final entry = await registry.queryMetadata(cp);
            if (entry != null) {
              entries.add(entry);
            }
          }
        }
      } catch (e, st) {
        developer.log(
          'Error fetching codepoints from ${source.sourceId}: $e',
          name: 'ContentRepository',
          error: e,
          stackTrace: st,
        );
      }
    }

    entries.sort(_compareMetadataEntries);
    return List.unmodifiable(entries.map((e) => e.codepoint));
  }

  /// Synchronous fast-path for ordered codepoints across active sources.
  List<int> getOrderedCodepointsSync() {
    final seen = <int>{};
    final entries = <KanjiMetadataEntry>[];

    for (final source in registry.activeMetadataSources) {
      if (source is BundledMetadataSource) {
        for (final cp in source.contentDb.getOrderedCodepoints()) {
          if (seen.add(cp)) {
            final k = source.contentDb.getKanjiByCodepoint(cp);
            if (k != null) {
              entries.add(KanjiMetadataEntry.fromKanjiCharacter(k));
            }
          }
        }
      } else {
        Iterable<int>? cps;
        try {
          final dynamic dynSource = source;
          final dynamic syncCps = dynSource.getAllCodepointsSync();
          if (syncCps is Iterable<int>) {
            cps = syncCps;
          } else if (syncCps is Iterable) {
            cps = syncCps.cast<int>();
          }
        } catch (_) {}
        if (cps == null) {
          try {
            final dynamic dynSource = source;
            final dynamic entriesMap = dynSource.entries;
            if (entriesMap is Map) {
              cps = entriesMap.keys.cast<int>();
            }
          } catch (_) {}
        }
        if (cps != null) {
          for (final cp in cps) {
            if (seen.add(cp)) {
              KanjiMetadataEntry? meta;
              try {
                meta = (source as dynamic).getMetadataSync(cp) as KanjiMetadataEntry?;
              } catch (_) {}
              if (meta == null) {
                try {
                  final dynamic entriesMap = (source as dynamic).entries;
                  if (entriesMap is Map) {
                    meta = entriesMap[cp] as KanjiMetadataEntry?;
                  }
                } catch (_) {}
              }
              if (meta != null) {
                entries.add(meta);
              }
            }
          }
        }
      }
    }

    entries.sort(_compareMetadataEntries);
    return List.unmodifiable(entries.map((e) => e.codepoint));
  }

  /// Resolves an audio pronunciation payload, traversing custom audio sources down to Japanese TTS.
  Future<AudioPronunciation> resolveAudio(int codepoint, {String? reading}) async {
    final audio = await registry.queryAudio(codepoint, reading: reading);
    if (audio != null) return audio;

    // Safety fallback TTS payload if no audio source supplied one
    final text = (reading != null && reading.trim().isNotEmpty)
        ? reading.trim()
        : (codepoint > 0 && codepoint <= 0x10FFFF ? String.fromCharCode(codepoint) : '');
    return AudioPronunciation(
      type: AudioPayloadType.ttsFallback,
      uriOrText: text,
      reading: text,
    );
  }

  /// Returns total count of unique characters across active metadata sources.
  Future<int> getTotalCharacterCount() async {
    final seen = <int>{};
    for (final source in registry.activeMetadataSources) {
      try {
        final cps = await source.getAllCodepoints();
        seen.addAll(cps);
      } catch (e, st) {
        developer.log(
          'Error fetching count from ${source.sourceId}: $e',
          name: 'ContentRepository',
          error: e,
          stackTrace: st,
        );
      }
    }
    return seen.length;
  }

  /// Synchronous fast-path for total character count.
  int getTotalCharacterCountSync() => getOrderedCodepointsSync().length;

  /// Generates meaning distractors delegating to registry fallback orchestration.
  Future<List<String>> generateMeaningDistractors(
    KanjiMetadataEntry target, {
    int count = 3,
  }) =>
      registry.queryMeaningDistractors(target, count: count);

  /// Generates reading distractors delegating to registry fallback orchestration.
  Future<List<String>> generateReadingDistractors(
    KanjiMetadataEntry target, {
    int count = 3,
  }) =>
      registry.queryReadingDistractors(target, count: count);

  // ---------------------------------------------------------------------------
  // Comparator
  // ---------------------------------------------------------------------------

  static int _compareMetadataEntries(KanjiMetadataEntry a, KanjiMetadataEntry b) {
    final gradeA = a.grade ?? 99;
    final gradeB = b.grade ?? 99;
    if (gradeA != gradeB) return gradeA.compareTo(gradeB);

    final jlptA = a.jlptLevel ?? 0;
    final jlptB = b.jlptLevel ?? 0;
    if (jlptA != jlptB) return jlptB.compareTo(jlptA); // DESC

    final freqA = a.frequency ?? 99999;
    final freqB = b.frequency ?? 99999;
    if (freqA != freqB) return freqA.compareTo(freqB);

    return a.codepoint.compareTo(b.codepoint);
  }
}
