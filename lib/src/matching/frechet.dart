import 'dart:math' as math;
import 'point2d.dart';

/// Iterative discrete Fréchet distance implementation (Section 3, Step 5).
/// Uses a 2-row rolling dynamic programming buffer in O(N*M) time and O(M) space,
/// avoiding recursion stack overhead on mobile devices.
class DiscreteFrechet {
  static double compute(List<Point2D> p, List<Point2D> q) {
    if (p.isEmpty || q.isEmpty) {
      throw ArgumentError('Point sequences must not be empty.');
    }
    final n = p.length;
    final m = q.length;

    var prev = List<double>.filled(m, 0.0);
    var curr = List<double>.filled(m, 0.0);

    for (var i = 0; i < n; i++) {
      final pi = p[i];
      for (var j = 0; j < m; j++) {
        final d = pi.distanceTo(q[j]);
        if (i == 0 && j == 0) {
          curr[j] = d;
        } else if (i == 0) {
          curr[j] = math.max(curr[j - 1], d);
        } else if (j == 0) {
          curr[j] = math.max(prev[0], d);
        } else {
          final prevMin = math.min(prev[j], math.min(curr[j - 1], prev[j - 1]));
          curr[j] = math.max(prevMin, d);
        }
      }
      final tmp = prev;
      prev = curr;
      curr = tmp;
    }

    return prev[m - 1];
  }
}
