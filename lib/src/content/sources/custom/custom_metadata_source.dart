import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

import '../../contracts/kanji_metadata_source.dart';
import '../../ingestion/models/source_manifest.dart';

/// Concrete metadata source adapter instantiated from an ingested custom package.
class CustomMetadataSource implements IKanjiMetadataSource {
  final String _sourceId;
  final String _displayName;
  final String _version;
  final Map<int, KanjiMetadataEntry> _entries;

  CustomMetadataSource({
    required String sourceId,
    required String displayName,
    required String version,
    required Map<int, KanjiMetadataEntry> entries,
  })  : _sourceId = sourceId,
        _displayName = displayName,
        _version = version,
        _entries = Map.unmodifiable(entries);

  /// Constructs a [CustomMetadataSource] by loading and parsing metadata from [packageDir].
  static Future<CustomMetadataSource> fromDirectory(
    Directory packageDir,
    SourceManifest manifest,
  ) async {
    final metaRel = manifest.metadataPath ?? 'metadata.json';
    final file = File(p.join(packageDir.path, metaRel));
    if (!await file.exists()) {
      throw FileSystemException('Metadata file missing in package', file.path);
    }

    final content = await file.readAsString();
    final decoded = jsonDecode(content);
    final entriesMap = <int, KanjiMetadataEntry>{};

    List<dynamic> list;
    if (decoded is List) {
      list = decoded;
    } else if (decoded is Map) {
      list = decoded.values.toList();
    } else {
      throw const FormatException('Metadata JSON root must be a list or map.');
    }

    for (final item in list) {
      if (item is Map) {
        final entry = KanjiMetadataEntry.fromMap(item.cast<String, Object?>());
        entriesMap[entry.codepoint] = entry;
      }
    }

    return CustomMetadataSource(
      sourceId: manifest.id,
      displayName: manifest.name,
      version: manifest.version,
      entries: entriesMap,
    );
  }

  @override
  String get sourceId => _sourceId;

  @override
  String get displayName => _displayName;

  @override
  String get version => _version;

  @override
  bool get isBundledDefault => false;

  @override
  Future<KanjiMetadataEntry?> getMetadata(int codepoint) async => _entries[codepoint];

  @override
  Future<List<int>> getAllCodepoints() async => _entries.keys.toList();

  @override
  Future<int> getCharacterCount() async => _entries.length;

  @override
  Future<List<String>> generateMeaningDistractors(
    KanjiMetadataEntry target, {
    int count = 3,
  }) async {
    if (count <= 0) return const [];
    final targetMeanings = target.meanings.map((m) => m.toLowerCase().trim()).toSet();
    final distractors = <String>[];

    // Priority 1: same JLPT level / grade
    for (final entry in _entries.values) {
      if (entry.codepoint == target.codepoint) continue;
      if (target.jlptLevel != null && entry.jlptLevel == target.jlptLevel) {
        for (final m in entry.meanings) {
          final trimmed = m.trim();
          if (trimmed.isNotEmpty && !targetMeanings.contains(trimmed.toLowerCase())) {
            distractors.add(trimmed);
            targetMeanings.add(trimmed.toLowerCase());
            if (distractors.length >= count) return distractors;
          }
        }
      }
    }

    // Priority 2: any other available meaning
    for (final entry in _entries.values) {
      if (entry.codepoint == target.codepoint) continue;
      for (final m in entry.meanings) {
        final trimmed = m.trim();
        if (trimmed.isNotEmpty && !targetMeanings.contains(trimmed.toLowerCase())) {
          distractors.add(trimmed);
          targetMeanings.add(trimmed.toLowerCase());
          if (distractors.length >= count) return distractors;
        }
      }
    }

    return distractors;
  }

  @override
  Future<List<String>> generateReadingDistractors(
    KanjiMetadataEntry target, {
    int count = 3,
  }) async {
    if (count <= 0) return const [];
    final targetReadings = {...target.onyomi, ...target.kunyomi}.map((r) => r.trim()).toSet();
    final distractors = <String>[];

    for (final entry in _entries.values) {
      if (entry.codepoint == target.codepoint) continue;
      for (final r in [...entry.onyomi, ...entry.kunyomi]) {
        final trimmed = r.trim();
        if (trimmed.isNotEmpty && !targetReadings.contains(trimmed)) {
          distractors.add(trimmed);
          targetReadings.add(trimmed);
          if (distractors.length >= count) return distractors;
        }
      }
    }

    return distractors;
  }
}
