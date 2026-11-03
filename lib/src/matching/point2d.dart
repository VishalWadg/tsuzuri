import 'dart:math' as math;
import 'dart:typed_data';

/// Immutable 2D coordinate in the 109x109 KanjiVG coordinate space.
class Point2D {
  final double x;
  final double y;

  const Point2D(this.x, this.y);

  double distanceTo(Point2D other) {
    final dx = x - other.x;
    final dy = y - other.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  Point2D operator +(Point2D other) => Point2D(x + other.x, y + other.y);
  Point2D operator -(Point2D other) => Point2D(x - other.x, y - other.y);
  Point2D operator *(double scalar) => Point2D(x * scalar, y * scalar);

  @override
  String toString() => 'Point2D(${x.toStringAsFixed(2)}, ${y.toStringAsFixed(2)})';
}

/// Axis-aligned bounding box for stroke normalization and translation/scale alignment.
class BoundingBox2D {
  final double minX;
  final double minY;
  final double maxX;
  final double maxY;

  const BoundingBox2D({
    required this.minX,
    required this.minY,
    required this.maxX,
    required this.maxY,
  });

  double get width => maxX - minX;
  double get height => maxY - minY;
  Point2D get center => Point2D((minX + maxX) * 0.5, (minY + maxY) * 0.5);

  static BoundingBox2D fromPoints(List<Point2D> points) {
    if (points.isEmpty) {
      return const BoundingBox2D(minX: 0, minY: 0, maxX: 0, maxY: 0);
    }
    var minX = points.first.x;
    var maxX = points.first.x;
    var minY = points.first.y;
    var maxY = points.first.y;
    for (var i = 1; i < points.length; i++) {
      final p = points[i];
      if (p.x < minX) minX = p.x;
      if (p.x > maxX) maxX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.y > maxY) maxY = p.y;
    }
    return BoundingBox2D(minX: minX, minY: minY, maxX: maxX, maxY: maxY);
  }
}

/// Geometry utilities for 109x109 normalization, arc-length resampling, and binary blob decoding.
class StrokeGeometry {
  static const double kanjiBoxSize = 109.0;
  static const int defaultSamplePoints = 50;

  /// Normalizes raw canvas touch coordinates into the 109x109 KanjiVG space.
  static List<Point2D> normalizeToKanjiSpace(
    List<Point2D> canvasPoints, {
    required double canvasWidth,
    required double canvasHeight,
  }) {
    if (canvasWidth <= 0 || canvasHeight <= 0) return canvasPoints;
    final sx = kanjiBoxSize / canvasWidth;
    final sy = kanjiBoxSize / canvasHeight;
    return canvasPoints.map((p) => Point2D(p.x * sx, p.y * sy)).toList(growable: false);
  }

  /// Computes total Euclidean arc length of a polyline.
  static double polylineArcLength(List<Point2D> points) {
    if (points.length < 2) return 0.0;
    var length = 0.0;
    for (var i = 1; i < points.length; i++) {
      length += points[i - 1].distanceTo(points[i]);
    }
    return length;
  }

  /// Resamples a polyline to [numPoints] equidistant points by arc length.
  static List<Point2D> resampleByArcLength(
    List<Point2D> points, {
    int numPoints = defaultSamplePoints,
  }) {
    if (points.isEmpty) {
      throw ArgumentError('Cannot resample an empty point list.');
    }
    if (points.length == 1) {
      return List<Point2D>.filled(numPoints, points.first, growable: false);
    }

    final cumDist = List<double>.filled(points.length, 0.0);
    for (var i = 1; i < points.length; i++) {
      cumDist[i] = cumDist[i - 1] + points[i - 1].distanceTo(points[i]);
    }

    final totalLength = cumDist.last;
    if (totalLength < 1e-6) {
      return List<Point2D>.filled(numPoints, points.first, growable: false);
    }

    final sampled = <Point2D>[points.first];
    final step = totalLength / (numPoints - 1);
    var segIdx = 0;

    for (var k = 1; k < numPoints - 1; k++) {
      final target = k * step;
      while (segIdx + 1 < cumDist.length && cumDist[segIdx + 1] < target) {
        segIdx++;
      }
      final d0 = cumDist[segIdx];
      final d1 = cumDist[segIdx + 1];
      final span = d1 - d0;
      final t = span > 1e-9 ? (target - d0) / span : 0.0;
      final p0 = points[segIdx];
      final p1 = points[segIdx + 1];
      sampled.add(Point2D(
        p0.x + (p1.x - p0.x) * t,
        p0.y + (p1.y - p0.y) * t,
      ));
    }

    sampled.add(points.last);
    return sampled;
  }

  /// Translates and scales [userPoints] to align with the bounding box of [referencePoints],
  /// clamping scale ratios so flat horizontal/vertical strokes are not distorted (Fix #5).
  static List<Point2D> alignToReferenceBoundingBox(
    List<Point2D> userPoints,
    List<Point2D> referencePoints,
  ) {
    final uBox = BoundingBox2D.fromPoints(userPoints);
    final rBox = BoundingBox2D.fromPoints(referencePoints);

    final uCenter = uBox.center;
    final rCenter = rBox.center;

    var sx = (uBox.width > 8.0 && rBox.width > 8.0) ? (rBox.width / uBox.width) : 1.0;
    var sy = (uBox.height > 8.0 && rBox.height > 8.0) ? (rBox.height / uBox.height) : 1.0;
    sx = sx.clamp(0.65, 1.50);
    sy = sy.clamp(0.65, 1.50);

    return userPoints
        .map((p) => Point2D(
              (p.x - uCenter.x) * sx + rCenter.x,
              (p.y - uCenter.y) * sy + rCenter.y,
            ))
        .toList(growable: false);
  }

  /// Decodes a 400-byte little-endian float32 BLOB into 50 [Point2D] coordinates (Fix #7).
  static List<Point2D> unpackPointsBlob(Uint8List blob) {
    final byteData = ByteData.sublistView(blob);
    final floatCount = blob.lengthInBytes ~/ 4;
    final points = <Point2D>[];
    for (var i = 0; i < floatCount; i += 2) {
      final x = byteData.getFloat32(i * 4, Endian.little);
      final y = byteData.getFloat32((i + 1) * 4, Endian.little);
      points.add(Point2D(x, y));
    }
    return points;
  }

  /// Packs a list of [Point2D] coordinates into a little-endian float32 BLOB.
  static Uint8List packPointsBlob(List<Point2D> points) {
    final byteData = ByteData(points.length * 8);
    for (var i = 0; i < points.length; i++) {
      byteData.setFloat32(i * 8, points[i].x, Endian.little);
      byteData.setFloat32(i * 8 + 4, points[i].y, Endian.little);
    }
    return byteData.buffer.asUint8List();
  }
}
