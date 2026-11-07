import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;

import '../../contracts/kanji_stroke_source.dart';
import '../../ingestion/models/source_manifest.dart';
import '../../../matching/point2d.dart';
import '../../../matching/stroke_matcher.dart';

/// Concrete stroke source adapter instantiated from an ingested custom package.
class CustomStrokeSource implements IKanjiStrokeSource {
  final String _sourceId;
  final String _displayName;
  final String _version;
  final Map<int, List<ReferenceStroke>> _strokeMap;

  CustomStrokeSource({
    required String sourceId,
    required String displayName,
    required String version,
    required Map<int, List<ReferenceStroke>> strokeMap,
  })  : _sourceId = sourceId,
        _displayName = displayName,
        _version = version,
        _strokeMap = Map.unmodifiable(strokeMap);

  /// Constructs a [CustomStrokeSource] by loading and parsing strokes from [packageDir].
  static Future<CustomStrokeSource> fromDirectory(
    Directory packageDir,
    SourceManifest manifest,
  ) async {
    final strokeRel = manifest.strokesPath ?? 'strokes.json';
    final file = File(p.join(packageDir.path, strokeRel));
    if (!await file.exists()) {
      throw FileSystemException('Strokes file missing in package', file.path);
    }

    final content = await file.readAsString();
    final decoded = jsonDecode(content);
    if (decoded is! Map) {
      throw const FormatException('Strokes JSON root must be a map keyed by codepoint.');
    }

    final strokeMap = <int, List<ReferenceStroke>>{};

    decoded.forEach((key, value) {
      final codepoint = int.tryParse(key.toString());
      if (codepoint == null) return;

      if (value is! List) return;
      final rawList = value;
      final strokes = <ReferenceStroke>[];

      for (var i = 0; i < rawList.length; i++) {
        final item = rawList[i];
        if (item is! Map) continue;
        final sMap = item.cast<String, dynamic>();

        List<Point2D> points = [];

        if (sMap.containsKey('points_blob')) {
          final blobVal = sMap['points_blob'];
          Uint8List blobBytes;
          if (blobVal is String) {
            blobBytes = base64Decode(blobVal);
          } else if (blobVal is List<int>) {
            blobBytes = Uint8List.fromList(blobVal);
          } else {
            blobBytes = Uint8List(0);
          }
          if (blobBytes.length == 400) {
            points = StrokeGeometry.unpackPointsBlob(blobBytes);
          }
        } else if (sMap.containsKey('points') || sMap.containsKey('sampled_points')) {
          final rawPts = (sMap['points'] ?? sMap['sampled_points']) as List<dynamic>?;
          if (rawPts != null) {
            for (final p in rawPts) {
              if (p is Map && p['x'] is num && p['y'] is num) {
                points.add(Point2D((p['x'] as num).toDouble(), (p['y'] as num).toDouble()));
              }
            }
          }
        }

        // If points need resampling to 50 points
        if (points.isNotEmpty && points.length != StrokeGeometry.defaultSamplePoints) {
          points = StrokeGeometry.resampleByArcLength(points);
        }

        final arcLen = (sMap['arc_length'] as num?)?.toDouble() ??
            (points.isNotEmpty ? StrokeGeometry.polylineArcLength(points) : 10.0);

        final strokeOrder = (sMap['stroke_order'] as int?) ??
            (sMap['strokeOrder'] as int?) ??
            (i + 1);

        strokes.add(ReferenceStroke(
          strokeOrder: strokeOrder,
          strokeType: (sMap['stroke_type'] as String?) ?? (sMap['strokeType'] as String?) ?? '',
          svgPath: (sMap['svg_path'] as String?) ?? (sMap['svgPath'] as String?) ?? '',
          arcLength: arcLen,
          sampledPoints: points,
        ));
      }

      strokeMap[codepoint] = List.unmodifiable(strokes);
    });

    return CustomStrokeSource(
      sourceId: manifest.id,
      displayName: manifest.name,
      version: manifest.version,
      strokeMap: strokeMap,
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
  Future<List<ReferenceStroke>?> getStrokes(int codepoint) async => _strokeMap[codepoint];

  @override
  Future<bool> containsStrokes(int codepoint) async =>
      _strokeMap.containsKey(codepoint) && _strokeMap[codepoint]!.isNotEmpty;
}
