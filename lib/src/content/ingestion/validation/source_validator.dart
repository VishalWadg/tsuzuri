import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../models/source_manifest.dart';
import '../models/ingestion_result.dart';

/// Result of a single validation step.
class ValidationResult {
  final bool isValid;
  final IngestionErrorCode? errorCode;
  final String? errorMessage;
  final dynamic details;

  const ValidationResult.valid()
      : isValid = true,
        errorCode = null,
        errorMessage = null,
        details = null;

  const ValidationResult.invalid(
    this.errorCode,
    this.errorMessage, {
    this.details,
  }) : isValid = false;

  @override
  String toString() => isValid
      ? 'ValidationResult.valid'
      : 'ValidationResult.invalid($errorCode: $errorMessage)';
}

/// Comprehensive validator for content source manifests, Unicode metadata scalars,
/// stroke geometries, binary blobs, and audio container formats.
class SourceValidator {
  static const int minAudioSizeBytes = 32;
  static const int maxAudioFileSizeBytes = 10 * 1024 * 1024; // 10 MB
  static const int strokePointsBlobBytes = 400; // 50 points * 2 coords * 4 bytes float32
  static const int minStrokeCount = 1;
  static const int maxStrokeCount = 64;

  static final RegExp _svgTokenRegExp = RegExp(
    r'([MmLlHhVvCcSsZz])|([-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)',
  );

  /// Validates a raw manifest JSON map against schema requirements.
  ValidationResult validateManifest(Map<String, dynamic> json) {
    // 1. Format Version
    final formatVersion = json['formatVersion'] ?? json['format_version'] ?? 1;
    if (formatVersion != 1) {
      return ValidationResult.invalid(
        IngestionErrorCode.unsupportedVersion,
        'Unsupported manifest format version: $formatVersion. Supported version is 1.',
      );
    }

    // 2. ID
    final rawId = json['id'];
    if (rawId == null || rawId is! String || rawId.trim().isEmpty) {
      return const ValidationResult.invalid(
        IngestionErrorCode.missingRequiredField,
        'Manifest is missing required field: "id".',
      );
    }
    final id = rawId.trim();
    if (!SourceManifest.isValidId(id)) {
      return ValidationResult.invalid(
        IngestionErrorCode.invalidManifest,
        'Invalid source id: "$id". ID must contain only lowercase alphanumeric characters, dots, dashes, or underscores.',
      );
    }

    // 3. Name
    final rawName = json['name'];
    if (rawName == null || rawName is! String || rawName.trim().isEmpty) {
      return const ValidationResult.invalid(
        IngestionErrorCode.missingRequiredField,
        'Manifest is missing required field: "name".',
      );
    }

    // 4. Version
    final rawVersion = json['version'];
    if (rawVersion == null || rawVersion is! String || rawVersion.trim().isEmpty) {
      return const ValidationResult.invalid(
        IngestionErrorCode.missingRequiredField,
        'Manifest is missing required field: "version".',
      );
    }
    final version = rawVersion.trim();
    if (!SourceManifest.isValidSemVer(version)) {
      return ValidationResult.invalid(
        IngestionErrorCode.unsupportedVersion,
        'Version "$version" is not a valid SemVer 2.0.0 string.',
      );
    }

    // 5. Capabilities
    final rawCaps = json['capabilities'];
    final caps = <SourceCapability>{};
    if (rawCaps is List) {
      for (final item in rawCaps) {
        final parsed = SourceCapability.fromString(item.toString());
        if (parsed != null) {
          caps.add(parsed);
        } else {
          return ValidationResult.invalid(
            IngestionErrorCode.invalidManifest,
            'Unrecognized capability: "$item". Allowed: metadata, strokes, audio.',
          );
        }
      }
    } else if (rawCaps is Map) {
      final map = rawCaps.cast<String, dynamic>();
      for (final entry in map.entries) {
        if (entry.value == true) {
          final parsed = SourceCapability.fromString(entry.key);
          if (parsed != null) caps.add(parsed);
        }
      }
    } else if (json['providesMetadata'] == true ||
        json['providesStrokes'] == true ||
        json['providesAudio'] == true) {
      if (json['providesMetadata'] == true) caps.add(SourceCapability.metadata);
      if (json['providesStrokes'] == true) caps.add(SourceCapability.strokes);
      if (json['providesAudio'] == true) caps.add(SourceCapability.audio);
    }

    if (caps.isEmpty) {
      return const ValidationResult.invalid(
        IngestionErrorCode.invalidManifest,
        'Manifest must declare at least one capability.',
      );
    }

    // 6. Path Safety Check (Zip-Slip prevention in declared relative paths)
    final pathsMap = json['paths'] is Map ? (json['paths'] as Map).cast<String, dynamic>() : null;
    final pathsToCheck = [
      (json['metadataPath'] ?? json['metadata_path'] ?? pathsMap?['metadata']) as String?,
      (json['strokesPath'] ?? json['strokes_path'] ?? pathsMap?['strokes']) as String?,
      (json['audioPath'] ?? json['audio_path'] ?? pathsMap?['audio']) as String?,
    ];

    for (final relPath in pathsToCheck) {
      if (relPath != null && relPath.isNotEmpty) {
        final sanitized = relPath.replaceAll('\\', '/');
        if (sanitized.startsWith('/') ||
            sanitized.startsWith('//') ||
            RegExp(r'^[a-zA-Z]:').hasMatch(sanitized) ||
            sanitized.split('/').any((s) => s == '..')) {
          return ValidationResult.invalid(
            IngestionErrorCode.zipSlipDetected,
            'Manifest contains insecure path escaping sandbox: "$relPath".',
          );
        }
      }
    }

    return const ValidationResult.valid();
  }

  /// Validates a single Unicode scalar codepoint and metadata dictionary entry.
  ValidationResult validateMetadataEntry(Map<String, dynamic> entry) {
    // 1. Codepoint scalar sanity
    final rawCp = entry['codepoint'];
    if (rawCp == null || rawCp is! int) {
      return const ValidationResult.invalid(
        IngestionErrorCode.invalidCodepoint,
        'Missing or non-integer "codepoint" field.',
      );
    }
    final cp = rawCp;
    if (cp <= 0 || cp > 0x10FFFF) {
      return ValidationResult.invalid(
        IngestionErrorCode.invalidCodepoint,
        'Codepoint $cp (0x${cp.toRadixString(16)}) is outside valid Unicode range (1..0x10FFFF).',
      );
    }

    // Surrogate range check: 0xD800..0xDFFF
    if (cp >= 0xD800 && cp <= 0xDFFF) {
      return ValidationResult.invalid(
        IngestionErrorCode.invalidCodepoint,
        'Codepoint 0x${cp.toRadixString(16)} is in the forbidden Unicode surrogate range (0xD800..0xDFFF).',
      );
    }

    // 2. Literal glyph consistency
    final literal = entry['literal'] as String?;
    if (literal == null || literal.isEmpty) {
      return const ValidationResult.invalid(
        IngestionErrorCode.schemaMismatch,
        'Metadata entry is missing "literal" glyph.',
      );
    }

    final runes = literal.runes.toList();
    if (runes.length != 1 || runes.first != cp) {
      return ValidationResult.invalid(
        IngestionErrorCode.schemaMismatch,
        'Literal "$literal" (rune 0x${runes.isNotEmpty ? runes.first.toRadixString(16) : ""}) does not match codepoint $cp (0x${cp.toRadixString(16)}).',
      );
    }

    // 3. Meanings non-empty check
    final meanings = entry['meanings'];
    if (meanings == null || meanings is! List || meanings.isEmpty) {
      return ValidationResult.invalid(
        IngestionErrorCode.schemaMismatch,
        'Kanji entry $literal ($cp) must have at least one English/target meaning.',
      );
    }
    final validMeanings = meanings.where((m) => m != null && m.toString().trim().isNotEmpty);
    if (validMeanings.isEmpty) {
      return ValidationResult.invalid(
        IngestionErrorCode.schemaMismatch,
        'Kanji entry $literal ($cp) has only empty or blank meanings.',
      );
    }

    // 4. Stroke count bounds (1..64)
    final strokeCount = entry['stroke_count'] ?? entry['strokeCount'];
    if (strokeCount != null) {
      if (strokeCount is! int || strokeCount < minStrokeCount || strokeCount > maxStrokeCount) {
        return ValidationResult.invalid(
          IngestionErrorCode.invalidStrokeData,
          'Kanji entry $literal ($cp) has invalid stroke count $strokeCount. Must be between $minStrokeCount and $maxStrokeCount.',
        );
      }
    }

    return const ValidationResult.valid();
  }

  /// Validates a 400-byte IEEE 754 little-endian binary stroke points blob.
  ValidationResult validatePointsBlob(Uint8List blob) {
    if (blob.lengthInBytes != strokePointsBlobBytes) {
      return ValidationResult.invalid(
        IngestionErrorCode.invalidStrokeData,
        'Stroke points blob size is ${blob.lengthInBytes} bytes; expected exactly $strokePointsBlobBytes bytes (50 points * 2 coords * 4 bytes).',
      );
    }

    final byteData = ByteData.sublistView(blob);
    for (var i = 0; i < strokePointsBlobBytes; i += 4) {
      final f = byteData.getFloat32(i, Endian.little);
      if (!f.isFinite) {
        return ValidationResult.invalid(
          IngestionErrorCode.invalidStrokeData,
          'Stroke blob contains non-finite IEEE 754 float ($f) at byte offset $i.',
        );
      }
    }

    return const ValidationResult.valid();
  }

  /// Validates an SVG `d` path attribute string.
  ValidationResult validateSvgPath(String svgPath) {
    final trimmed = svgPath.trim();
    if (trimmed.isEmpty) {
      return const ValidationResult.invalid(
        IngestionErrorCode.invalidStrokeData,
        'SVG path is empty.',
      );
    }

    final matches = _svgTokenRegExp.allMatches(trimmed).toList();
    if (matches.isEmpty) {
      return ValidationResult.invalid(
        IngestionErrorCode.invalidStrokeData,
        'SVG path "$svgPath" contains no valid SVG tokens.',
      );
    }

    // Check if it has a move command ('M' or 'm')
    final hasMove = matches.any((m) {
      final cmd = m.group(1);
      return cmd == 'M' || cmd == 'm';
    });
    if (!hasMove) {
      return ValidationResult.invalid(
        IngestionErrorCode.invalidStrokeData,
        'SVG path "$svgPath" missing initial move command (M/m).',
      );
    }

    // Check for drawing command ('C', 'c', 'S', 's', 'L', 'l', 'Q', 'q', 'H', 'h', 'V', 'v', 'Z', 'z')
    final hasDraw = matches.any((m) {
      final cmd = m.group(1);
      return cmd != null && cmd != 'M' && cmd != 'm';
    });

    // If there is no draw command and only a single move point (e.g. "M 10 10"), arc length is 0
    if (!hasDraw) {
      // If only M with numbers, check how many numbers
      final numberTokens = matches.where((m) => m.group(2) != null).toList();
      if (numberTokens.length <= 2) {
        return ValidationResult.invalid(
          IngestionErrorCode.invalidStrokeData,
          'SVG path "$svgPath" is a degenerate zero-length path.',
        );
      }
    }

    return const ValidationResult.valid();
  }

  /// Validates stroke data for a single Kanji character.
  ValidationResult validateStrokeData({
    required int codepoint,
    required List<dynamic> rawStrokes,
    int? expectedStrokeCount,
  }) {
    if (rawStrokes.isEmpty || rawStrokes.length > maxStrokeCount) {
      return ValidationResult.invalid(
        IngestionErrorCode.invalidStrokeData,
        'Codepoint $codepoint stroke count ${rawStrokes.length} is outside allowed range ($minStrokeCount..$maxStrokeCount).',
      );
    }

    if (expectedStrokeCount != null && rawStrokes.length != expectedStrokeCount) {
      return ValidationResult.invalid(
        IngestionErrorCode.invalidStrokeData,
        'Codepoint $codepoint stroke count ${rawStrokes.length} does not match expected count $expectedStrokeCount.',
      );
    }

    for (var i = 0; i < rawStrokes.length; i++) {
      final strokeItem = rawStrokes[i];
      if (strokeItem is! Map) {
        return ValidationResult.invalid(
          IngestionErrorCode.invalidStrokeData,
          'Codepoint $codepoint stroke at index $i is not a JSON object.',
        );
      }

      final sMap = strokeItem.cast<String, dynamic>();

      // Check points or points blob or svg_path
      if (sMap.containsKey('points_blob')) {
        final rawBlob = sMap['points_blob'];
        Uint8List blobBytes;
        if (rawBlob is String) {
          try {
            blobBytes = base64Decode(rawBlob);
          } catch (_) {
            return ValidationResult.invalid(
              IngestionErrorCode.invalidStrokeData,
              'Codepoint $codepoint stroke $i has invalid base64 points_blob.',
            );
          }
        } else if (rawBlob is List<int>) {
          blobBytes = Uint8List.fromList(rawBlob);
        } else {
          return ValidationResult.invalid(
            IngestionErrorCode.invalidStrokeData,
            'Codepoint $codepoint stroke $i points_blob is neither String nor byte list.',
          );
        }

        final blobRes = validatePointsBlob(blobBytes);
        if (!blobRes.isValid) return blobRes;
      } else if (sMap.containsKey('points')) {
        final pointsRaw = sMap['points'];
        if (pointsRaw is! List || pointsRaw.isEmpty) {
          return ValidationResult.invalid(
            IngestionErrorCode.invalidStrokeData,
            'Codepoint $codepoint stroke $i points array is empty or invalid.',
          );
        }
        for (final p in pointsRaw) {
          if (p is! Map || p['x'] is! num || p['y'] is! num) {
            return ValidationResult.invalid(
              IngestionErrorCode.invalidStrokeData,
              'Codepoint $codepoint stroke $i has malformed point coordinates: $p',
            );
          }
          final x = (p['x'] as num).toDouble();
          final y = (p['y'] as num).toDouble();
          if (!x.isFinite || !y.isFinite) {
            return ValidationResult.invalid(
              IngestionErrorCode.invalidStrokeData,
              'Codepoint $codepoint stroke $i point contains non-finite coordinates ($x, $y).',
            );
          }
        }
      } else if (sMap.containsKey('svg_path')) {
        final svgPath = sMap['svg_path'] as String? ?? '';
        final svgRes = validateSvgPath(svgPath);
        if (!svgRes.isValid) return svgRes;
      } else {
        return ValidationResult.invalid(
          IngestionErrorCode.invalidStrokeData,
          'Codepoint $codepoint stroke $i must define points, points_blob, or svg_path.',
        );
      }
    }

    return const ValidationResult.valid();
  }

  /// Validates audio file bytes: size bounds (32B..10MB) and container magic bytes.
  ValidationResult validateAudioBytes(List<int> bytes, {String? filename}) {
    final len = bytes.length;
    if (len < minAudioSizeBytes) {
      return ValidationResult.invalid(
        IngestionErrorCode.invalidAudioData,
        'Audio file "${filename ?? 'unknown'}" is too small ($len bytes; minimum is $minAudioSizeBytes bytes).',
      );
    }

    if (len > maxAudioFileSizeBytes) {
      return ValidationResult.invalid(
        IngestionErrorCode.invalidAudioData,
        'Audio file "${filename ?? 'unknown'}" exceeds 10MB limit ($len bytes).',
      );
    }

    // Inspect container header magic bytes:
    // 1. WAV: 'RIFF' .... 'WAVE'
    final isWav = len >= 12 &&
        bytes[0] == 0x52 && // 'R'
        bytes[1] == 0x49 && // 'I'
        bytes[2] == 0x46 && // 'F'
        bytes[3] == 0x46 && // 'F'
        bytes[8] == 0x57 && // 'W'
        bytes[9] == 0x41 && // 'A'
        bytes[10] == 0x56 && // 'V'
        bytes[11] == 0x45; // 'E'

    // 2. MP3:
    // ID3v2: 'ID3'
    final isId3 = len >= 3 &&
        bytes[0] == 0x49 && // 'I'
        bytes[1] == 0x44 && // 'D'
        bytes[2] == 0x33; // '3'

    // MPEG sync word: 11 bits set (0xFF followed by high 3 bits set in second byte: 0xE0)
    final isMp3Sync = len >= 2 &&
        bytes[0] == 0xFF &&
        (bytes[1] & 0xE0) == 0xE0;

    // 3. OGG: 'OggS'
    final isOgg = len >= 4 &&
        bytes[0] == 0x4F && // 'O'
        bytes[1] == 0x67 && // 'g'
        bytes[2] == 0x67 && // 'g'
        bytes[3] == 0x53; // 'S'

    // 4. M4A / MP4: 'ftyp' at offset 4..7
    final isM4a = len >= 8 &&
        bytes[4] == 0x66 && // 'f'
        bytes[5] == 0x74 && // 't'
        bytes[6] == 0x79 && // 'y'
        bytes[7] == 0x70; // 'p'

    if (!isWav && !isId3 && !isMp3Sync && !isOgg && !isM4a) {
      return ValidationResult.invalid(
        IngestionErrorCode.invalidAudioData,
        'Audio file "${filename ?? 'unknown'}" does not have valid magic bytes for WAV, MP3, OGG, or M4A.',
      );
    }

    return const ValidationResult.valid();
  }

  /// Deep validation of an entire staged package directory against its manifest.
  Future<IngestionResult> validatePackageDirectory(
    Directory packageDir, {
    SourceManifest? explicitManifest,
  }) async {
    if (!await packageDir.exists()) {
      return IngestionResult.failure(
        errorCode: IngestionErrorCode.storageError,
        errorMessage: 'Staging directory does not exist: ${packageDir.path}',
      );
    }

    SourceManifest manifest;
    if (explicitManifest != null) {
      manifest = explicitManifest;
    } else {
      final manifestFile = File(p.join(packageDir.path, 'manifest.json'));
      if (!await manifestFile.exists()) {
        return const IngestionResult.failure(
          errorCode: IngestionErrorCode.missingManifest,
          errorMessage: 'Package missing required "manifest.json" file at root.',
        );
      }

      String manifestStr;
      try {
        manifestStr = await manifestFile.readAsString();
      } catch (e) {
        return IngestionResult.failure(
          errorCode: IngestionErrorCode.invalidManifest,
          errorMessage: 'Could not read manifest.json: $e',
        );
      }

      dynamic jsonMap;
      try {
        jsonMap = jsonDecode(manifestStr);
      } catch (e) {
        return IngestionResult.failure(
          errorCode: IngestionErrorCode.invalidManifest,
          errorMessage: 'Malformed JSON in manifest.json: $e',
        );
      }

      if (jsonMap is! Map<String, dynamic>) {
        return const IngestionResult.failure(
          errorCode: IngestionErrorCode.invalidManifest,
          errorMessage: 'manifest.json root must be a JSON object.',
        );
      }

      final schemaRes = validateManifest(jsonMap);
      if (!schemaRes.isValid) {
        return IngestionResult.failure(
          errorCode: schemaRes.errorCode!,
          errorMessage: schemaRes.errorMessage!,
        );
      }

      try {
        manifest = SourceManifest.fromJson(jsonMap);
      } catch (e) {
        return IngestionResult.failure(
          errorCode: IngestionErrorCode.invalidManifest,
          errorMessage: 'Manifest construction error: $e',
        );
      }
    }

    // Checksums verification if provided
    if (manifest.checksums != null && manifest.checksums!.isNotEmpty) {
      for (final entry in manifest.checksums!.entries) {
        final relPath = entry.key;
        final expectedHash = entry.value.trim().toLowerCase();
        final assetFile = File(p.join(packageDir.path, relPath));
        if (!await assetFile.exists()) {
          return IngestionResult.failure(
            errorCode: IngestionErrorCode.missingAssetFile,
            errorMessage: 'File "$relPath" declared in checksums does not exist.',
          );
        }

        final bytes = await assetFile.readAsBytes();
        final actualHash = sha256.convert(bytes).toString().toLowerCase();

        // Support 'sha256:<hex>' or pure '<hex>'
        final cleanExpected = expectedHash.startsWith('sha256:')
            ? expectedHash.substring(7)
            : expectedHash;

        if (actualHash != cleanExpected) {
          return IngestionResult.failure(
            errorCode: IngestionErrorCode.checksumMismatch,
            errorMessage:
                'Checksum mismatch for "$relPath". Expected $cleanExpected, computed $actualHash.',
          );
        }
      }
    }

    // 1. Metadata Capability
    if (manifest.capabilities.contains(SourceCapability.metadata)) {
      final metaRel = manifest.metadataPath ?? 'metadata.json';
      final metaFile = File(p.join(packageDir.path, metaRel));
      if (!await metaFile.exists()) {
        return IngestionResult.failure(
          errorCode: IngestionErrorCode.missingAssetFile,
          errorMessage: 'Declared metadata file "$metaRel" is missing in package.',
        );
      }

      String content;
      try {
        content = await metaFile.readAsString();
      } catch (e) {
        return IngestionResult.failure(
          errorCode: IngestionErrorCode.corruptedData,
          errorMessage: 'Could not read metadata file "$metaRel": $e',
        );
      }

      dynamic decoded;
      try {
        decoded = jsonDecode(content);
      } catch (e) {
        return IngestionResult.failure(
          errorCode: IngestionErrorCode.schemaMismatch,
          errorMessage: 'Metadata file "$metaRel" contains malformed JSON: $e',
        );
      }

      List<dynamic> entries;
      if (decoded is List) {
        entries = decoded;
      } else if (decoded is Map) {
        entries = decoded.values.toList();
      } else {
        return IngestionResult.failure(
          errorCode: IngestionErrorCode.schemaMismatch,
          errorMessage: 'Metadata file "$metaRel" root must be an array or map of entries.',
        );
      }

      for (var i = 0; i < entries.length; i++) {
        final entry = entries[i];
        if (entry is! Map) {
          return IngestionResult.failure(
            errorCode: IngestionErrorCode.schemaMismatch,
            errorMessage: 'Metadata entry at index $i is not a JSON object.',
          );
        }
        final res = validateMetadataEntry(entry.cast<String, dynamic>());
        if (!res.isValid) {
          return IngestionResult.failure(
            errorCode: res.errorCode!,
            errorMessage: res.errorMessage!,
          );
        }
      }
    }

    // 2. Strokes Capability
    if (manifest.capabilities.contains(SourceCapability.strokes)) {
      final strokeRel = manifest.strokesPath ?? 'strokes.json';
      final strokeFile = File(p.join(packageDir.path, strokeRel));
      if (!await strokeFile.exists()) {
        return IngestionResult.failure(
          errorCode: IngestionErrorCode.missingAssetFile,
          errorMessage: 'Declared stroke file "$strokeRel" is missing in package.',
        );
      }

      String content;
      try {
        content = await strokeFile.readAsString();
      } catch (e) {
        return IngestionResult.failure(
          errorCode: IngestionErrorCode.corruptedData,
          errorMessage: 'Could not read stroke file "$strokeRel": $e',
        );
      }

      dynamic decoded;
      try {
        decoded = jsonDecode(content);
      } catch (e) {
        return IngestionResult.failure(
          errorCode: IngestionErrorCode.schemaMismatch,
          errorMessage: 'Stroke file "$strokeRel" contains malformed JSON: $e',
        );
      }

      if (decoded is! Map) {
        return IngestionResult.failure(
          errorCode: IngestionErrorCode.schemaMismatch,
          errorMessage: 'Stroke file "$strokeRel" root must be a map keyed by codepoint.',
        );
      }

      for (final entry in decoded.entries) {
        final keyStr = entry.key.toString();
        final cp = int.tryParse(keyStr);
        if (cp == null || cp <= 0 || cp > 0x10FFFF) {
          return IngestionResult.failure(
            errorCode: IngestionErrorCode.invalidCodepoint,
            errorMessage: 'Invalid stroke map key "$keyStr". Must be valid codepoint integer.',
          );
        }
        if (cp >= 0xD800 && cp <= 0xDFFF) {
          return IngestionResult.failure(
            errorCode: IngestionErrorCode.invalidCodepoint,
            errorMessage: 'Stroke map key "$keyStr" is in forbidden surrogate range.',
          );
        }

        final strokeList = entry.value;
        if (strokeList is! List) {
          return IngestionResult.failure(
            errorCode: IngestionErrorCode.invalidStrokeData,
            errorMessage: 'Stroke list for codepoint $cp must be an array.',
          );
        }

        final res = validateStrokeData(codepoint: cp, rawStrokes: strokeList);
        if (!res.isValid) {
          return IngestionResult.failure(
            errorCode: res.errorCode!,
            errorMessage: res.errorMessage!,
          );
        }
      }
    }

    // 3. Audio Capability
    if (manifest.capabilities.contains(SourceCapability.audio)) {
      final audioRel = manifest.audioPath ?? 'audio';
      final audioDir = Directory(p.join(packageDir.path, audioRel));
      if (!await audioDir.exists()) {
        return IngestionResult.failure(
          errorCode: IngestionErrorCode.missingAssetFile,
          errorMessage: 'Declared audio directory "$audioRel" is missing in package.',
        );
      }

      final audioEntities = await audioDir.list().toList();
      for (final entity in audioEntities) {
        if (entity is File) {
          final fileName = p.basename(entity.path);
          if (fileName.startsWith('.') || fileName.endsWith('.json')) {
            continue; // Skip hidden or index metadata files
          }
          final bytes = await entity.readAsBytes();
          final res = validateAudioBytes(bytes, filename: fileName);
          if (!res.isValid) {
            return IngestionResult.failure(
              errorCode: res.errorCode!,
              errorMessage: res.errorMessage!,
            );
          }
        }
      }
    }

    return IngestionResult.success(
      manifest: manifest,
      packageDirectory: packageDir.path,
    );
  }
}
