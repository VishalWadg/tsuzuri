import 'dart:math' as math;
import 'frechet.dart';
import 'point2d.dart';

/// Leniency presets (Section 3 & 4: strict / normal / forgiving) that scale thresholds.
enum LeniencyPreset {
  strict(
    label: 'Strict',
    thresholdScale: 0.82,
    minLengthRatio: 0.60,
    maxLengthRatio: 1.65,
    minDirectionCosine: 0.38,
    maxCenterShift: 16.0,
  ),
  normal(
    label: 'Normal',
    thresholdScale: 1.00,
    minLengthRatio: 0.50,
    maxLengthRatio: 2.00,
    minDirectionCosine: 0.25,
    maxCenterShift: 22.0,
  ),
  forgiving(
    label: 'Forgiving',
    thresholdScale: 1.22,
    minLengthRatio: 0.42,
    maxLengthRatio: 2.35,
    minDirectionCosine: 0.12,
    maxCenterShift: 28.0,
  );

  final String label;
  final double thresholdScale;
  final double minLengthRatio;
  final double maxLengthRatio;
  final double minDirectionCosine;
  final double maxCenterShift;

  const LeniencyPreset({
    required this.label,
    required this.thresholdScale,
    required this.minLengthRatio,
    required this.maxLengthRatio,
    required this.minDirectionCosine,
    required this.maxCenterShift,
  });
}

/// Classification of a user stroke attempt (Phase 2 & Section 3).
enum StrokeMatchStatus {
  pass('Good stroke!'),
  badShape('Bad shape'),
  wrongDirection('Wrong direction'),
  wrongOrder('Wrong stroke order'),
  tooShort('Too short');

  final String feedbackMessage;
  const StrokeMatchStatus(this.feedbackMessage);

  bool get isPass => this == StrokeMatchStatus.pass;
}

/// Detailed diagnostic result returned by [StrokeMatcher.validateStroke].
class StrokeMatchResult {
  final StrokeMatchStatus status;
  final double effectiveDistance;
  final double rawDistance;
  final double threshold;
  final int? matchedLaterStrokeIndex;

  const StrokeMatchResult({
    required this.status,
    required this.effectiveDistance,
    this.rawDistance = double.infinity,
    required this.threshold,
    this.matchedLaterStrokeIndex,
  });

  bool get isPass => status == StrokeMatchStatus.pass;
}

/// Reference stroke model holding the pre-sampled 50 points and arc length.
class ReferenceStroke {
  final int strokeOrder;
  final String strokeType;
  final String svgPath;
  final double arcLength;
  final List<Point2D> sampledPoints;

  const ReferenceStroke({
    required this.strokeOrder,
    required this.strokeType,
    required this.svgPath,
    required this.arcLength,
    required this.sampledPoints,
  });
}

/// Pure-Dart stroke matching engine implementing the revised pipeline from Section 3:
/// 1. Normalize canvas coordinates to 109x109 space and smooth high-frequency touch jitter.
/// 2. Reject if too short (accidental tap).
/// 3. Resample user polyline U to 50 points by arc length.
/// 4. Run length-ratio gate (50%..200% of reference) and start-direction chord gate (first 25%).
/// 5. Compute iterative discrete Fréchet distance against expected stroke Q (as-drawn + bbox-aligned).
/// 6. Pass if distance <= length-scaled threshold (~25% of reference length, clamped).
/// 7. Check remaining strokes to classify wrong order vs bad shape.
class StrokeMatcher {
  static const double minTapLengthInKanjiSpace = 6.0;
  static const double bboxAlignmentPenalty = 1.15;
  static const double centerShiftPenaltyWeight = 0.35;
  static const int startChordPointIndex = 12; // 25% of 50 resampled points

  /// Applies a 1-pass 3-point moving average filter to reduce high-frequency touch sensor jitter.
  static List<Point2D> smoothPolyline(List<Point2D> points) {
    if (points.length < 3) return points;
    final smoothed = <Point2D>[points.first];
    for (var i = 1; i < points.length - 1; i++) {
      final prev = points[i - 1];
      final curr = points[i];
      final next = points[i + 1];
      smoothed.add(Point2D(
        0.25 * prev.x + 0.50 * curr.x + 0.25 * next.x,
        0.25 * prev.y + 0.50 * curr.y + 0.25 * next.y,
      ));
    }
    smoothed.add(points.last);
    return smoothed;
  }

  /// Validates a user's drawn stroke (already in 109x109 space)
  /// against [expectedStrokeIndex] within [allReferenceStrokes].
  static StrokeMatchResult validateStroke({
    required List<Point2D> userPointsInKanjiSpace,
    required int expectedStrokeIndex,
    required List<ReferenceStroke> allReferenceStrokes,
    LeniencyPreset leniency = LeniencyPreset.normal,
  }) {
    if (expectedStrokeIndex < 0 || expectedStrokeIndex >= allReferenceStrokes.length) {
      throw RangeError.index(expectedStrokeIndex, allReferenceStrokes, 'expectedStrokeIndex');
    }

    final smoothedPoints = smoothPolyline(userPointsInKanjiSpace);
    final userArcLength = StrokeGeometry.polylineArcLength(smoothedPoints);
    if (smoothedPoints.length < 2 || userArcLength < minTapLengthInKanjiSpace) {
      return const StrokeMatchResult(
        status: StrokeMatchStatus.tooShort,
        effectiveDistance: double.infinity,
        threshold: 0.0,
      );
    }

    final userSampled = StrokeGeometry.resampleByArcLength(
      smoothedPoints,
      numPoints: StrokeGeometry.defaultSamplePoints,
    );

    final expectedRef = allReferenceStrokes[expectedStrokeIndex];
    final primaryCheck = _evaluateAgainstReference(
      userSampled: userSampled,
      userArcLength: userArcLength,
      reference: expectedRef,
      leniency: leniency,
    );

    // Step 7 (Fix #6): Test remaining strokes to detect wrong stroke order.
    for (var laterIdx = expectedStrokeIndex + 1; laterIdx < allReferenceStrokes.length; laterIdx++) {
      final laterCheck = _evaluateAgainstReference(
        userSampled: userSampled,
        userArcLength: userArcLength,
        reference: allReferenceStrokes[laterIdx],
        leniency: leniency,
      );
      if (laterCheck.isPass) {
        if (!primaryCheck.isPass || (laterCheck.rawDistance + 6.0 < primaryCheck.rawDistance)) {
          return StrokeMatchResult(
            status: StrokeMatchStatus.wrongOrder,
            effectiveDistance: laterCheck.effectiveDistance,
            rawDistance: laterCheck.rawDistance,
            threshold: laterCheck.threshold,
            matchedLaterStrokeIndex: laterIdx,
          );
        }
      }
    }

    return primaryCheck;
  }

  static StrokeMatchResult _evaluateAgainstReference({
    required List<Point2D> userSampled,
    required double userArcLength,
    required ReferenceStroke reference,
    required LeniencyPreset leniency,
  }) {
    final refLength = math.max(reference.arcLength, 1.0);
    final baseThreshold = (refLength * 0.25).clamp(9.5, 25.0);
    final threshold = baseThreshold * leniency.thresholdScale;

    // Step 4a (Fix #3): Length-ratio gate
    final lengthRatio = userArcLength / refLength;
    if (lengthRatio < leniency.minLengthRatio || lengthRatio > leniency.maxLengthRatio) {
      return StrokeMatchResult(
        status: StrokeMatchStatus.badShape,
        effectiveDistance: double.infinity,
        threshold: threshold,
      );
    }

    // Step 4b (Fix #4): Start-direction chord over first ~25% of stroke (points 0..12)
    final refPoints = reference.sampledPoints;
    final startCosine = _chordCosineSimilarity(userSampled, refPoints, startChordPointIndex);
    final overallCosine = _chordCosineSimilarity(userSampled, refPoints, refPoints.length - 1);
    if (startCosine < leniency.minDirectionCosine || overallCosine < 0.0) {
      return StrokeMatchResult(
        status: StrokeMatchStatus.wrongDirection,
        effectiveDistance: double.infinity,
        threshold: threshold,
      );
    }

    // Step 5 (Fix #5): Discrete Fréchet distance on as-drawn and bounding-box-aligned variants.
    final rawDistance = DiscreteFrechet.compute(userSampled, refPoints);
    final alignedUser = StrokeGeometry.alignToReferenceBoundingBox(userSampled, refPoints);

    final userCenter = _centroid(userSampled);
    final refCenter = _centroid(refPoints);
    final centerShift = userCenter.distanceTo(refCenter);

    final alignedDistance = DiscreteFrechet.compute(alignedUser, refPoints) * bboxAlignmentPenalty +
        centerShiftPenaltyWeight * centerShift;

    final effectiveDistance =
        centerShift > leniency.maxCenterShift ? rawDistance : math.min(rawDistance, alignedDistance);

    if (effectiveDistance <= threshold) {
      return StrokeMatchResult(
        status: StrokeMatchStatus.pass,
        effectiveDistance: effectiveDistance,
        rawDistance: rawDistance,
        threshold: threshold,
      );
    }

    return StrokeMatchResult(
      status: StrokeMatchStatus.badShape,
      effectiveDistance: effectiveDistance,
      rawDistance: rawDistance,
      threshold: threshold,
    );
  }

  static double _chordCosineSimilarity(
    List<Point2D> p,
    List<Point2D> q,
    int targetIndex,
  ) {
    final idx = math.min(targetIndex, math.min(p.length - 1, q.length - 1));
    final vx1 = p[idx].x - p.first.x;
    final vy1 = p[idx].y - p.first.y;
    final vx2 = q[idx].x - q.first.x;
    final vy2 = q[idx].y - q.first.y;

    final norm1 = math.sqrt(vx1 * vx1 + vy1 * vy1);
    final norm2 = math.sqrt(vx2 * vx2 + vy2 * vy2);
    if (norm1 < 1e-5 || norm2 < 1e-5) {
      return 1.0;
    }
    return (vx1 * vx2 + vy1 * vy2) / (norm1 * norm2);
  }

  static Point2D _centroid(List<Point2D> points) {
    var sx = 0.0;
    var sy = 0.0;
    for (final p in points) {
      sx += p.x;
      sy += p.y;
    }
    return Point2D(sx / points.length, sy / points.length);
  }
}
