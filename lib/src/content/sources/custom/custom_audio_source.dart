import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

import '../../contracts/kanji_audio_source.dart';
import '../../ingestion/models/source_manifest.dart';

/// Concrete audio source adapter instantiated from an ingested custom package.
class CustomAudioSource implements IKanjiAudioSource {
  final String _sourceId;
  final String _displayName;
  final String _version;
  final Directory _audioDir;
  final Map<int, Map<String, String>> _audioFileIndex; // codepoint -> (reading -> filePath)

  CustomAudioSource({
    required String sourceId,
    required String displayName,
    required String version,
    required Directory audioDir,
    required Map<int, Map<String, String>> audioFileIndex,
  })  : _sourceId = sourceId,
        _displayName = displayName,
        _version = version,
        _audioDir = audioDir,
        _audioFileIndex = audioFileIndex;

  /// Constructs a [CustomAudioSource] by discovering and indexing audio assets in [packageDir].
  static Future<CustomAudioSource> fromDirectory(
    Directory packageDir,
    SourceManifest manifest,
  ) async {
    final audioRel = manifest.audioPath ?? 'audio';
    final audioDir = Directory(p.join(packageDir.path, audioRel));
    final index = <int, Map<String, String>>{};

    if (await audioDir.exists()) {
      // 1. Check for audio_index.json
      final indexFile = File(p.join(audioDir.path, 'audio_index.json'));
      if (await indexFile.exists()) {
        try {
          final content = await indexFile.readAsString();
          final decoded = jsonDecode(content) as Map<String, dynamic>;
          decoded.forEach((cpKey, entries) {
            final cp = int.tryParse(cpKey);
            if (cp != null && entries is List) {
              for (final item in entries) {
                if (item is Map) {
                  final reading = (item['reading'] as String?)?.trim() ?? '';
                  final relFile = item['file'] as String?;
                  if (relFile != null) {
                    final absPath = p.normalize(p.join(packageDir.path, relFile));
                    index.putIfAbsent(cp, () => {})[reading] = absPath;
                  }
                }
              }
            }
          });
        } catch (_) {}
      }

      // 2. Scan audio files by filename convention: e.g. "4E00.mp3", "04e00_ichi.wav"
      await for (final entity in audioDir.list(followLinks: false)) {
        if (entity is File) {
          final filename = p.basename(entity.path);
          if (filename.startsWith('.') || filename.endsWith('.json')) continue;

          final withoutExt = p.basenameWithoutExtension(filename);
          final parts = withoutExt.split('_');
          final hexOrDec = parts[0];

          int? cp = int.tryParse(hexOrDec, radix: 16);
          cp ??= int.tryParse(hexOrDec);

          if (cp != null) {
            final reading = parts.length > 1 ? parts.sublist(1).join('_') : '';
            index.putIfAbsent(cp, () => {})[reading] = entity.path;
          }
        }
      }
    }

    return CustomAudioSource(
      sourceId: manifest.id,
      displayName: manifest.name,
      version: manifest.version,
      audioDir: audioDir,
      audioFileIndex: index,
    );
  }

  /// The directory containing package audio assets.
  Directory get audioDirectory => _audioDir;

  @override
  String get sourceId => _sourceId;

  @override
  String get displayName => _displayName;

  @override
  String get version => _version;

  @override
  bool get isBundledDefault => false;

  @override
  Future<AudioPronunciation?> getAudio(int codepoint, {String? reading}) async {
    final entry = _audioFileIndex[codepoint];
    if (entry == null || entry.isEmpty) return null;

    String? filePath;
    String matchedReading = reading ?? '';

    if (reading != null && entry.containsKey(reading)) {
      filePath = entry[reading];
    } else if (entry.containsKey('')) {
      filePath = entry[''];
    } else {
      filePath = entry.values.first;
      matchedReading = entry.keys.first;
    }

    if (filePath == null) return null;

    return AudioPronunciation(
      type: AudioPayloadType.localFile,
      uriOrText: filePath,
      mimeType: _mimeTypeFor(filePath),
      reading: matchedReading,
    );
  }

  @override
  Future<bool> containsAudio(int codepoint, {String? reading}) async {
    final entry = _audioFileIndex[codepoint];
    if (entry == null || entry.isEmpty) return false;
    if (reading != null && reading.isNotEmpty) {
      return entry.containsKey(reading) || entry.containsKey('');
    }
    return true;
  }

  static String _mimeTypeFor(String filePath) {
    final ext = p.extension(filePath).toLowerCase();
    switch (ext) {
      case '.mp3':
        return 'audio/mpeg';
      case '.wav':
        return 'audio/wav';
      case '.ogg':
      case '.oga':
        return 'audio/ogg';
      case '.m4a':
      case '.aac':
        return 'audio/mp4';
      default:
        return 'application/octet-stream';
    }
  }
}
