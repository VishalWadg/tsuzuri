import 'dart:ui';

/// Lightweight SVG path parser for KanjiVG stroke paths (`109x109` viewBox).
///
/// Section 2 & 3 of the Approach Plan state:
/// "Skip a runtime SVG library: you need each stroke as a `Path` in a `CustomPainter`
/// to highlight, animate, and snap it individually."
class KanjiSvgPathParser {
  static final RegExp _tokenRegExp = RegExp(
    r'([MmLlHhVvCcSsZz])|([-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)',
  );

  /// Parses an SVG `d` attribute string into a Flutter [Path], scaled from the
  /// 109x109 KanjiVG coordinate space to [canvasSize].
  static Path parseToCanvasPath(String svgPath, Size canvasSize) {
    final sx = canvasSize.width / 109.0;
    final sy = canvasSize.height / 109.0;

    final tokens = _tokenRegExp
        .allMatches(svgPath)
        .map((m) => m.group(0)!)
        .toList(growable: false);

    final path = Path();
    var cx = 0.0;
    var cy = 0.0;
    var startX = 0.0;
    var startY = 0.0;
    double? prevCtrlX;
    double? prevCtrlY;
    var i = 0;
    var cmd = '';

    double nextDouble() => double.parse(tokens[i++]);

    while (i < tokens.length) {
      final token = tokens[i];
      if (_isCommand(token)) {
        cmd = token;
        i++;
      }

      switch (cmd) {
        case 'M':
        case 'm':
          final dx = nextDouble();
          final dy = nextDouble();
          cx = cmd == 'M' ? dx : cx + dx;
          cy = cmd == 'M' ? dy : cy + dy;
          startX = cx;
          startY = cy;
          path.moveTo(cx * sx, cy * sy);
          prevCtrlX = null;
          prevCtrlY = null;
          cmd = cmd == 'M' ? 'L' : 'l';
          break;

        case 'L':
        case 'l':
          final dx = nextDouble();
          final dy = nextDouble();
          cx = cmd == 'L' ? dx : cx + dx;
          cy = cmd == 'L' ? dy : cy + dy;
          path.lineTo(cx * sx, cy * sy);
          prevCtrlX = null;
          prevCtrlY = null;
          break;

        case 'H':
        case 'h':
          final dx = nextDouble();
          cx = cmd == 'H' ? dx : cx + dx;
          path.lineTo(cx * sx, cy * sy);
          prevCtrlX = null;
          prevCtrlY = null;
          break;

        case 'V':
        case 'v':
          final dy = nextDouble();
          cy = cmd == 'V' ? dy : cy + dy;
          path.lineTo(cx * sx, cy * sy);
          prevCtrlX = null;
          prevCtrlY = null;
          break;

        case 'C':
        case 'c':
          var x1 = nextDouble();
          var y1 = nextDouble();
          var x2 = nextDouble();
          var y2 = nextDouble();
          var x3 = nextDouble();
          var y3 = nextDouble();
          if (cmd == 'c') {
            x1 += cx;
            y1 += cy;
            x2 += cx;
            y2 += cy;
            x3 += cx;
            y3 += cy;
          }
          path.cubicTo(x1 * sx, y1 * sy, x2 * sx, y2 * sy, x3 * sx, y3 * sy);
          prevCtrlX = x2;
          prevCtrlY = y2;
          cx = x3;
          cy = y3;
          break;

        case 'S':
        case 's':
          var x2 = nextDouble();
          var y2 = nextDouble();
          var x3 = nextDouble();
          var y3 = nextDouble();
          if (cmd == 's') {
            x2 += cx;
            y2 += cy;
            x3 += cx;
            y3 += cy;
          }
          final x1 = prevCtrlX != null ? (2.0 * cx - prevCtrlX) : cx;
          final y1 = prevCtrlY != null ? (2.0 * cy - prevCtrlY) : cy;
          path.cubicTo(x1 * sx, y1 * sy, x2 * sx, y2 * sy, x3 * sx, y3 * sy);
          prevCtrlX = x2;
          prevCtrlY = y2;
          cx = x3;
          cy = y3;
          break;

        case 'Z':
        case 'z':
          path.close();
          cx = startX;
          cy = startY;
          prevCtrlX = null;
          prevCtrlY = null;
          break;

        default:
          i++;
          break;
      }
    }

    return path;
  }

  static bool _isCommand(String token) {
    if (token.length != 1) return false;
    final code = token.codeUnitAt(0);
    return (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
  }
}
