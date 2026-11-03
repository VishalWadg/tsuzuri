import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_kanji_practice/src/matching/frechet.dart';
import 'package:offline_kanji_practice/src/matching/point2d.dart';
import 'package:offline_kanji_practice/src/matching/stroke_matcher.dart';

void main() {
  group('Phase 2: Pure-Dart Stroke Matching Engine', () {
    // Reference strokes for Kanji「十」(U+5341):
    // Stroke 0: Horizontal left-to-right (12.75, 51.25) -> (95.25, 48.0)
    // Stroke 1: Vertical top-to-bottom (53.25, 11.5) -> (53.25, 96.5)
    late ReferenceStroke horizRef;
    late ReferenceStroke vertRef;
    late List<ReferenceStroke> tenStrokes;

    setUp(() {
      final hPts = StrokeGeometry.resampleByArcLength(
        const [Point2D(12.75, 51.25), Point2D(95.25, 48.0)],
        numPoints: 50,
      );
      horizRef = ReferenceStroke(
        strokeOrder: 0,
        strokeType: '㇐',
        svgPath: 'M12.75,51.25 L95.25,48.0',
        arcLength: StrokeGeometry.polylineArcLength(hPts),
        sampledPoints: hPts,
      );

      final vPts = StrokeGeometry.resampleByArcLength(
        const [Point2D(53.25, 11.5), Point2D(53.25, 96.5)],
        numPoints: 50,
      );
      vertRef = ReferenceStroke(
        strokeOrder: 1,
        strokeType: '㇑',
        svgPath: 'M53.25,11.5 L53.25,96.5',
        arcLength: StrokeGeometry.polylineArcLength(vPts),
        sampledPoints: vPts,
      );

      tenStrokes = [horizRef, vertRef];
    });

    test('Iterative discrete Frechet distance is zero for identical curves', () {
      expect(
        DiscreteFrechet.compute(horizRef.sampledPoints, horizRef.sampledPoints),
        closeTo(0.0, 1e-6),
      );
    });

    test('Passes noisy variant (jitter + slight scale 0.9x + shift + wobble)', () {
      final rng = math.Random(42);
      final noisy = <Point2D>[];
      for (var i = 0; i < horizRef.sampledPoints.length; i++) {
        final p = horizRef.sampledPoints[i];
        final wobble = math.sin(i * 0.3) * 1.2;
        noisy.add(Point2D(
          (p.x - 54.5) * 0.90 + 54.5 + 4.0 + (rng.nextDouble() - 0.5) * 2.0,
          (p.y - 54.5) * 0.90 + 54.5 - 3.0 + wobble + (rng.nextDouble() - 0.5) * 2.0,
        ));
      }

      final result = StrokeMatcher.validateStroke(
        userPointsInKanjiSpace: noisy,
        expectedStrokeIndex: 0,
        allReferenceStrokes: tenStrokes,
      );
      expect(result.status, equals(StrokeMatchStatus.pass));
    });

    test('Rejects reversed stroke as wrongDirection (Fix #4)', () {
      final reversed = horizRef.sampledPoints.reversed.toList();
      final result = StrokeMatcher.validateStroke(
        userPointsInKanjiSpace: reversed,
        expectedStrokeIndex: 0,
        allReferenceStrokes: tenStrokes,
      );
      expect(result.status, equals(StrokeMatchStatus.wrongDirection));
    });

    test('Detects wrong stroke order when user draws stroke 2 before stroke 1 (Fix #6)', () {
      final result = StrokeMatcher.validateStroke(
        userPointsInKanjiSpace: vertRef.sampledPoints,
        expectedStrokeIndex: 0,
        allReferenceStrokes: tenStrokes,
      );
      expect(result.status, equals(StrokeMatchStatus.wrongOrder));
      expect(result.matchedLaterStrokeIndex, equals(1));
    });

    test('Rejects accidental tap as tooShort', () {
      final tap = const [Point2D(50.0, 50.0), Point2D(52.0, 51.0)];
      final result = StrokeMatcher.validateStroke(
        userPointsInKanjiSpace: tap,
        expectedStrokeIndex: 0,
        allReferenceStrokes: tenStrokes,
      );
      expect(result.status, equals(StrokeMatchStatus.tooShort));
    });

    test('Rejects stroke failing length-ratio gate (< 50% of reference length) (Fix #3)', () {
      final shortLine = const [Point2D(20.0, 50.0), Point2D(45.0, 50.0)]; // length 25 vs ref 82.5
      final result = StrokeMatcher.validateStroke(
        userPointsInKanjiSpace: shortLine,
        expectedStrokeIndex: 0,
        allReferenceStrokes: tenStrokes,
      );
      expect(result.status, equals(StrokeMatchStatus.badShape));
    });
  });
}
