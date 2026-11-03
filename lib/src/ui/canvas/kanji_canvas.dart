import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../matching/point2d.dart';
import '../../matching/stroke_matcher.dart';
import 'svg_path_parser.dart';

/// Callback fired when all strokes of the target kanji have been completed.
typedef KanjiCompletedCallback = void Function(int mistakes, int hintsUsed);

/// Phase 4 Handwriting Canvas with three CustomPainter layers:
/// 1. Four-quadrant background grid + verified strokes layer (turns green on completion).
/// 2. Hint layer (faint outline of next stroke + animated stroke demonstration on repeated errors).
/// 3. Live ink layer (single-pointer gesture capture, flashes red with reason on failure).
class KanjiWritingCanvas extends StatefulWidget {
  final List<ReferenceStroke> referenceStrokes;
  final LeniencyPreset leniency;
  final bool hintsEnabled;
  final bool hapticsEnabled;
  final KanjiCompletedCallback onCompleted;

  const KanjiWritingCanvas({
    super.key,
    required this.referenceStrokes,
    required this.leniency,
    required this.hintsEnabled,
    required this.hapticsEnabled,
    required this.onCompleted,
  });

  @override
  State<KanjiWritingCanvas> createState() => KanjiWritingCanvasState();
}

class KanjiWritingCanvasState extends State<KanjiWritingCanvas>
    with TickerProviderStateMixin {
  int _currentStrokeIndex = 0;
  int _mistakesOnCurrentKanji = 0;
  int _mistakesOnCurrentStroke = 0;
  int _hintsUsedOnCurrentKanji = 0;
  bool _showStaticHintOutline = false;

  int? _activePointerId;
  final List<Offset> _activePoints = [];
  List<Offset> _failedFlashPoints = const [];
  String? _feedbackBannerText;
  Color _feedbackBannerColor = Colors.transparent;

  late final AnimationController _hintAnimController;
  late final AnimationController _failFadeController;
  late final AnimationController _completionPulseController;

  @override
  void initState() {
    super.initState();
    _hintAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 950),
    );
    _failFadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed && mounted) {
          setState(() {
            _failedFlashPoints = const [];
          });
        }
      });
    _completionPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
  }

  @override
  void didUpdateWidget(covariant KanjiWritingCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.referenceStrokes != widget.referenceStrokes) {
      resetCanvas();
    }
  }

  @override
  void dispose() {
    _hintAnimController.dispose();
    _failFadeController.dispose();
    _completionPulseController.dispose();
    super.dispose();
  }

  bool get isCompleted => _currentStrokeIndex >= widget.referenceStrokes.length;
  int get currentStrokeIndex => _currentStrokeIndex;
  int get mistakesCount => _mistakesOnCurrentKanji;
  int get hintsUsedCount => _hintsUsedOnCurrentKanji;

  /// Clears the most recently verified stroke (undo last stroke).
  void undoLastVerifiedStroke() {
    if (_currentStrokeIndex > 0 && !isCompleted) {
      setState(() {
        _currentStrokeIndex--;
        _mistakesOnCurrentStroke = 0;
        _showStaticHintOutline = false;
        _feedbackBannerText = null;
      });
      _hintAnimController.stop();
    }
  }

  /// Resets the entire kanji canvas back to stroke 0.
  void resetCanvas() {
    _hintAnimController.stop();
    _failFadeController.stop();
    _completionPulseController.reset();
    setState(() {
      _currentStrokeIndex = 0;
      _mistakesOnCurrentKanji = 0;
      _mistakesOnCurrentStroke = 0;
      _hintsUsedOnCurrentKanji = 0;
      _showStaticHintOutline = false;
      _activePointerId = null;
      _activePoints.clear();
      _failedFlashPoints = const [];
      _feedbackBannerText = null;
    });
  }

  /// Triggers a progressive hint for the current stroke (faint outline first, then animated demo).
  void triggerHint() {
    if (isCompleted || !widget.hintsEnabled) return;
    setState(() {
      _hintsUsedOnCurrentKanji++;
      _showStaticHintOutline = true;
    });
    _hintAnimController.forward(from: 0.0);
  }

  void _onPointerDown(PointerDownEvent event) {
    if (isCompleted || _activePointerId != null) return;
    setState(() {
      _activePointerId = event.pointer;
      _activePoints
        ..clear()
        ..add(event.localPosition);
      _failedFlashPoints = const [];
      _feedbackBannerText = null;
    });
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _activePointerId || isCompleted) return;
    setState(() {
      _activePoints.add(event.localPosition);
    });
  }

  void _onPointerUpOrCancel(PointerEvent event, Size canvasSize) {
    if (event.pointer != _activePointerId) return;
    final drawnOffsets = List<Offset>.of(_activePoints);
    _activePointerId = null;
    _activePoints.clear();

    if (isCompleted || drawnOffsets.isEmpty) {
      setState(() {});
      return;
    }

    final normalizedPoints = StrokeGeometry.normalizeToKanjiSpace(
      drawnOffsets.map((o) => Point2D(o.dx, o.dy)).toList(growable: false),
      canvasWidth: canvasSize.width,
      canvasHeight: canvasSize.height,
    );

    final matchResult = StrokeMatcher.validateStroke(
      userPointsInKanjiSpace: normalizedPoints,
      expectedStrokeIndex: _currentStrokeIndex,
      allReferenceStrokes: widget.referenceStrokes,
      leniency: widget.leniency,
    );

    if (matchResult.isPass) {
      if (widget.hapticsEnabled) {
        unawaited(HapticFeedback.lightImpact());
      }
      _hintAnimController.stop();
      setState(() {
        _currentStrokeIndex++;
        _mistakesOnCurrentStroke = 0;
        _showStaticHintOutline = false;
        _feedbackBannerText = 'Stroke $_currentStrokeIndex / ${widget.referenceStrokes.length}';
        _feedbackBannerColor = const Color(0xFF2E7D32);
      });

      if (_currentStrokeIndex >= widget.referenceStrokes.length) {
        _completionPulseController.forward(from: 0.0);
        widget.onCompleted(_mistakesOnCurrentKanji, _hintsUsedOnCurrentKanji);
      }
    } else if (matchResult.status == StrokeMatchStatus.tooShort) {
      setState(() {
        _feedbackBannerText = 'Too short — draw the full stroke';
        _feedbackBannerColor = const Color(0xFFEF6C00);
      });
    } else {
      if (widget.hapticsEnabled) {
        unawaited(HapticFeedback.heavyImpact());
      }
      _mistakesOnCurrentKanji++;
      _mistakesOnCurrentStroke++;

      setState(() {
        _failedFlashPoints = drawnOffsets;
        _feedbackBannerText = matchResult.status.feedbackMessage;
        _feedbackBannerColor = const Color(0xFFC62828);

        // Automatic progressive hints after repeated errors (Section 4)
        if (widget.hintsEnabled) {
          if (_mistakesOnCurrentStroke >= 2) {
            _showStaticHintOutline = true;
          }
          if (_mistakesOnCurrentStroke >= 3) {
            _hintsUsedOnCurrentKanji++;
            _hintAnimController.forward(from: 0.0);
          }
        }
      });
      _failFadeController.forward(from: 0.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Feedback banner row
        SizedBox(
          height: 36,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: _feedbackBannerText != null
                ? Container(
                    key: ValueKey(_feedbackBannerText),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: _feedbackBannerColor.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: _feedbackBannerColor, width: 1.2),
                    ),
                    child: Text(
                      _feedbackBannerText!,
                      style: TextStyle(
                        color: _feedbackBannerColor,
                        fontWeight: FontWeight.w600,
                        fontSize: 13.5,
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ),
        const SizedBox(height: 8),

        // Square 4-quadrant interactive canvas
        AspectRatio(
          aspectRatio: 1.0,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = Size(constraints.maxWidth, constraints.maxHeight);
              return Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: _onPointerDown,
                onPointerMove: _onPointerMove,
                onPointerUp: (e) => _onPointerUpOrCancel(e, size),
                onPointerCancel: (e) => _onPointerUpOrCancel(e, size),
                child: AnimatedBuilder(
                  animation: Listenable.merge([
                    _hintAnimController,
                    _failFadeController,
                    _completionPulseController,
                  ]),
                  builder: (context, _) {
                    return CustomPaint(
                      size: size,
                      painter: _KanjiThreeLayerPainter(
                        referenceStrokes: widget.referenceStrokes,
                        completedStrokeCount: _currentStrokeIndex,
                        isCharacterCompleted: isCompleted,
                        showStaticHintOutline: _showStaticHintOutline,
                        hintAnimationProgress: _hintAnimController.isAnimating
                            ? _hintAnimController.value
                            : (_hintAnimController.value == 1.0 ? 0.0 : _hintAnimController.value),
                        activePoints: _activePoints,
                        failedFlashPoints: _failedFlashPoints,
                        failFadeProgress: _failFadeController.value,
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 12),

        // Canvas action controls (Hint, Undo Stroke, Restart)
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: (!isCompleted && widget.hintsEnabled) ? triggerHint : null,
              icon: const Icon(Icons.lightbulb_outline, size: 18),
              label: const Text('Hint'),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: (_currentStrokeIndex > 0 && !isCompleted)
                  ? undoLastVerifiedStroke
                  : null,
              icon: const Icon(Icons.undo, size: 18),
              label: const Text('Undo Stroke'),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: resetCanvas,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Restart'),
            ),
          ],
        ),
      ],
    );
  }
}

class _KanjiThreeLayerPainter extends CustomPainter {
  final List<ReferenceStroke> referenceStrokes;
  final int completedStrokeCount;
  final bool isCharacterCompleted;
  final bool showStaticHintOutline;
  final double hintAnimationProgress;
  final List<Offset> activePoints;
  final List<Offset> failedFlashPoints;
  final double failFadeProgress;

  _KanjiThreeLayerPainter({
    required this.referenceStrokes,
    required this.completedStrokeCount,
    required this.isCharacterCompleted,
    required this.showStaticHintOutline,
    required this.hintAnimationProgress,
    required this.activePoints,
    required this.failedFlashPoints,
    required this.failFadeProgress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // 0. Background surface + Four-Quadrant Practice Grid
    final bgPaint = Paint()..color = const Color(0xFFFDFBF7);
    final borderPaint = Paint()
      ..color = const Color(0xFF9E9D89)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(12)),
      bgPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(12)),
      borderPaint,
    );

    _drawFourQuadrantGrid(canvas, size);

    // 1. Layer 1: Verified Strokes (snapped to KanjiVG paths; turns green on completion)
    final verifiedPaint = Paint()
      ..color = isCharacterCompleted
          ? const Color(0xFF2E7D32)
          : const Color(0xFF1F2937)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.048
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    for (var i = 0; i < completedStrokeCount && i < referenceStrokes.length; i++) {
      final path = KanjiSvgPathParser.parseToCanvasPath(
        referenceStrokes[i].svgPath,
        size,
      );
      canvas.drawPath(path, verifiedPaint);
    }

    // 2. Layer 2: Hint Layer (faint outline + animated demonstration of next stroke)
    if (!isCharacterCompleted && completedStrokeCount < referenceStrokes.length) {
      final nextStroke = referenceStrokes[completedStrokeCount];
      final nextPath = KanjiSvgPathParser.parseToCanvasPath(nextStroke.svgPath, size);

      if (showStaticHintOutline) {
        final hintOutlinePaint = Paint()
          ..color = const Color(0xFF90A4AE).withValues(alpha: 0.45)
          ..style = PaintingStyle.stroke
          ..strokeWidth = size.width * 0.045
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;
        canvas.drawPath(nextPath, hintOutlinePaint);
      }

      if (hintAnimationProgress > 0.0) {
        final animPaint = Paint()
          ..color = const Color(0xFF1565C0).withValues(alpha: 0.85)
          ..style = PaintingStyle.stroke
          ..strokeWidth = size.width * 0.048
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;

        for (final metric in nextPath.computeMetrics()) {
          final subPath = metric.extractPath(0.0, metric.length * hintAnimationProgress);
          canvas.drawPath(subPath, animPaint);
        }
      }
    }

    // 3. Layer 3: Live Ink + Failed Stroke Red Flash
    if (failedFlashPoints.length >= 2) {
      final alpha = (1.0 - failFadeProgress).clamp(0.0, 1.0);
      final failPaint = Paint()
        ..color = const Color(0xFFD32F2F).withValues(alpha: alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width * 0.048
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      canvas.drawPath(_polylineToPath(failedFlashPoints), failPaint);
    }

    if (activePoints.length >= 2) {
      final livePaint = Paint()
        ..color = const Color(0xFF0D47A1)
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width * 0.046
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      canvas.drawPath(_polylineToPath(activePoints), livePaint);
    }
  }

  void _drawFourQuadrantGrid(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = const Color(0xFFD6D3C4)
      ..strokeWidth = 1.2;

    const dashLen = 6.0;
    const gapLen = 5.0;

    // Horizontal center dashed line
    final midY = size.height * 0.5;
    for (var x = 0.0; x < size.width; x += dashLen + gapLen) {
      canvas.drawLine(
        Offset(x, midY),
        Offset((x + dashLen).clamp(0.0, size.width), midY),
        gridPaint,
      );
    }

    // Vertical center dashed line
    final midX = size.width * 0.5;
    for (var y = 0.0; y < size.height; y += dashLen + gapLen) {
      canvas.drawLine(
        Offset(midX, y),
        Offset(midX, (y + dashLen).clamp(0.0, size.height)),
        gridPaint,
      );
    }
  }

  Path _polylineToPath(List<Offset> points) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx, points[i].dy);
    }
    return path;
  }

  @override
  bool shouldRepaint(covariant _KanjiThreeLayerPainter oldDelegate) => true;
}
