import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Programmatic generator for valid, malformed, truncated, checksum-mismatched,
/// and Zip-Slip packages for hermetic E2E testing.
class TestPackageBuilder {
  /// Generates a valid minimal WAV file header and payload.
  static List<int> createWavBytes(int length) {
    assert(length >= 44, 'WAV files require at least 44 bytes for standard header');
    final bytes = Uint8List(length);
    // 'RIFF'
    bytes[0] = 0x52; bytes[1] = 0x49; bytes[2] = 0x46; bytes[3] = 0x46;
    // Length in header
    final byteData = ByteData.sublistView(bytes);
    byteData.setUint32(4, length - 8, Endian.little);
    // 'WAVE'
    bytes[8] = 0x57; bytes[9] = 0x41; bytes[10] = 0x56; bytes[11] = 0x45;
    // 'fmt ' chunk
    bytes[12] = 0x66; bytes[13] = 0x6D; bytes[14] = 0x74; bytes[15] = 0x20;
    byteData.setUint32(16, 16, Endian.little); // chunk size
    byteData.setUint16(20, 1, Endian.little); // PCM
    byteData.setUint16(22, 1, Endian.little); // Mono
    byteData.setUint32(24, 44100, Endian.little); // Sample rate
    byteData.setUint32(28, 88200, Endian.little); // Byte rate
    byteData.setUint16(32, 2, Endian.little); // Block align
    byteData.setUint16(34, 16, Endian.little); // Bits per sample
    // 'data' chunk
    bytes[36] = 0x64; bytes[37] = 0x61; bytes[38] = 0x74; bytes[39] = 0x61;
    byteData.setUint32(40, length - 44, Endian.little);
    return bytes;
  }

  /// Generates valid MP3 ID3v2 header and payload.
  static List<int> createMp3Bytes(int length) {
    assert(length >= 32, 'MP3 requires at least 32 bytes');
    final bytes = Uint8List(length);
    // 'ID3'
    bytes[0] = 0x49; bytes[1] = 0x44; bytes[2] = 0x33;
    bytes[3] = 0x03; // version 2.3.0
    bytes[4] = 0x00;
    bytes[5] = 0x00; // flags
    // size (synchsafe int)
    bytes[6] = 0x00; bytes[7] = 0x00; bytes[8] = 0x00; bytes[9] = 0x10;
    // payload
    for (var i = 10; i < length; i++) {
      bytes[i] = 0xAA;
    }
    return bytes;
  }

  /// Generates a valid 400-byte IEEE 754 Float32 points blob for 50 2D points.
  static Uint8List createFloat32PointsBlob({int pointCount = 50}) {
    final floatCount = pointCount * 2;
    final byteData = ByteData(floatCount * 4);
    for (var i = 0; i < pointCount; i++) {
      final t = i / (pointCount - 1);
      final x = 100.0 + t * 800.0;
      final y = 200.0 + t * 600.0;
      byteData.setFloat32(i * 8, x, Endian.little);
      byteData.setFloat32(i * 8 + 4, y, Endian.little);
    }
    return byteData.buffer.asUint8List();
  }

  /// Computes the hex SHA-256 digest of a byte list.
  static String sha256Hex(List<int> bytes) {
    return sha256.convert(bytes).toString();
  }

  /// Builds a valid in-memory ZIP package Archive.
  static Archive buildValidPackageArchive({
    String id = 'sample_package',
    String name = 'Sample Package',
    String version = '1.0.0',
    String? author = 'Tsuzuri Team',
    String? description = 'Sample offline test package',
    bool includeMetadata = true,
    bool includeStrokes = true,
    bool includeAudio = true,
    int sampleCodepoint = 0x4E00,
    String sampleLiteral = '一',
    List<String> meanings = const ['one', 'first'],
    List<String> onyomi = const ['イチ'],
    List<String> kunyomi = const ['ひと'],
  }) {
    final archive = Archive();
    final capabilities = <String>[];
    if (includeMetadata) capabilities.add('metadata');
    if (includeStrokes) capabilities.add('strokes');
    if (includeAudio) capabilities.add('audio');

    final manifestMap = <String, dynamic>{
      'formatVersion': 1,
      'id': id,
      'name': name,
      'version': version,
      if (author != null) 'author': author,
      if (description != null) 'description': description,
      'capabilities': capabilities,
      if (includeMetadata) 'metadataPath': 'metadata.json',
      if (includeStrokes) 'strokesPath': 'strokes.json',
      if (includeAudio) 'audioPath': 'audio',
    };

    if (includeMetadata) {
      final metadataList = [
        {
          'codepoint': sampleCodepoint,
          'literal': sampleLiteral,
          'stroke_count': 1,
          'grade': 1,
          'jlpt_level': 5,
          'frequency': 2,
          'onyomi': onyomi,
          'kunyomi': kunyomi,
          'meanings': meanings,
        }
      ];
      archive.addFile(ArchiveFile.string('metadata.json', jsonEncode(metadataList)));
    }

    if (includeStrokes) {
      final strokesMap = {
        sampleCodepoint.toString(): [
          {
            'stroke_order': 1,
            'svg_path': 'M 100 500 L 900 500',
            'points': [
              {'x': 100.0, 'y': 500.0},
              {'x': 900.0, 'y': 500.0},
            ],
          }
        ]
      };
      archive.addFile(ArchiveFile.string('strokes.json', jsonEncode(strokesMap)));
    }

    if (includeAudio) {
      final wavBytes = createWavBytes(64);
      final hexCode = sampleCodepoint.toRadixString(16).toUpperCase().padLeft(4, '0');
      archive.addFile(ArchiveFile('audio/$hexCode.wav', wavBytes.length, wavBytes));

      final indexMap = {
        sampleCodepoint.toString(): [
          {
            'reading': onyomi.isNotEmpty ? onyomi.first : 'イチ',
            'file': 'audio/$hexCode.wav',
          }
        ]
      };
      archive.addFile(ArchiveFile.string('audio/audio_index.json', jsonEncode(indexMap)));
    }

    archive.addFile(ArchiveFile.string('manifest.json', jsonEncode(manifestMap)));
    return archive;
  }

  /// Encodes [archive] to ZIP bytes.
  static Uint8List encodeZip(Archive archive) {
    return Uint8List.fromList(ZipEncoder().encode(archive)!);
  }

  /// Writes a valid ZIP package to [targetFile].
  static Future<File> writeValidZipPackage(
    File targetFile, {
    String id = 'sample_package',
    String name = 'Sample Package',
    String version = '1.0.0',
    int sampleCodepoint = 0x4E00,
    String sampleLiteral = '一',
    List<String> meanings = const ['one', 'first'],
  }) async {
    final archive = buildValidPackageArchive(
      id: id,
      name: name,
      version: version,
      sampleCodepoint: sampleCodepoint,
      sampleLiteral: sampleLiteral,
      meanings: meanings,
    );
    final bytes = encodeZip(archive);
    await targetFile.parent.create(recursive: true);
    return targetFile.writeAsBytes(bytes);
  }

  /// Builds a Zip-Slip attack archive containing a relative traversal path.
  static Uint8List createZipSlipZipBytes({
    String maliciousPath = '../../evil_exploit.txt',
    String id = 'zip_slip_exploit',
  }) {
    final archive = Archive();
    final manifestMap = {
      'formatVersion': 1,
      'id': id,
      'name': 'Zip Slip Test Package',
      'version': '1.0.0',
      'capabilities': ['metadata'],
      'metadataPath': 'metadata.json',
    };
    archive.addFile(ArchiveFile.string('manifest.json', jsonEncode(manifestMap)));
    archive.addFile(ArchiveFile.string('metadata.json', '[]'));
    archive.addFile(ArchiveFile.string(maliciousPath, 'MALICIOUS_PAYLOAD'));
    return encodeZip(archive);
  }

  /// Creates a directory package on disk.
  static Future<Directory> writeDirectoryPackage(
    Directory targetDir, {
    String id = 'dir_package',
    String name = 'Directory Package',
    String version = '1.0.0',
    int sampleCodepoint = 0x4E00,
    String sampleLiteral = '一',
    List<String> meanings = const ['one'],
  }) async {
    await targetDir.create(recursive: true);
    final manifestMap = {
      'formatVersion': 1,
      'id': id,
      'name': name,
      'version': version,
      'capabilities': ['metadata'],
      'metadataPath': 'metadata.json',
    };
    await File(p.join(targetDir.path, 'manifest.json')).writeAsString(jsonEncode(manifestMap));
    final metadataList = [
      {
        'codepoint': sampleCodepoint,
        'literal': sampleLiteral,
        'stroke_count': 1,
        'meanings': meanings,
      }
    ];
    await File(p.join(targetDir.path, 'metadata.json')).writeAsString(jsonEncode(metadataList));
    return targetDir;
  }
}
