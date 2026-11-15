import 'dart:math' as math;
import 'dart:ui';

import 'package:edu/features/whiteboard/domain/entities/board_element.dart';
import 'package:edu/features/whiteboard/domain/entities/whiteboard_sync_step.dart';
import 'package:edu/features/whiteboard/presentation/controllers/whiteboard_canvas_controller.dart';
import 'package:edu/features/whiteboard/presentation/rendering/path_metric_cache.dart';
import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

/// Paints persisted tutor elements, the currently audio-timed step, and local
/// pressure-sensitive student ink.
final class WhiteboardCanvasPainter extends CustomPainter {
  WhiteboardCanvasPainter({
    required this.controller,
    required this.textDirection,
    required this.highlightPulse,
  }) : super(repaint: Listenable.merge(<Listenable>[controller, highlightPulse]));

  final WhiteboardCanvasController controller;
  final TextDirection textDirection;
  final Animation<double> highlightPulse;
  final PathMetricCache _pathCache = PathMetricCache();

  @override
  void paint(Canvas canvas, Size size) {
    for (final element in controller.boardState.elements) {
      _paintPersistentElement(canvas, size, element);
    }

    final step = controller.playback.activeStep;
    if (step != null) {
      final activeIndex = controller.playback.activeActionIndex;
      if (activeIndex >= 0) {
        final fraction = controller.playback.actionProgress(activeIndex);
        if (fraction > 0) {
          _paintAction(canvas, size, step.actions[activeIndex], fraction);
        }
      }
    }

    final inkPaint = Paint()
      ..color = const Color(0xFF182238)
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    for (final path in controller.freehandPaths(size)) {
      canvas.drawPath(path, inkPaint);
    }
  }

  void _paintPersistentElement(Canvas canvas, Size size, BoardElement element) {
    _paintAction(canvas, size, element.action, 1);
    final highlight = element.highlightAction;
    if (element.highlighted && highlight != null) {
      _paintHighlight(canvas, size, highlight, 0.75);
    }
  }

  void _paintAction(
    Canvas canvas,
    Size size,
    WhiteboardAction action,
    double fraction,
  ) {
    final reveal = fraction.clamp(0.0, 1.0).toDouble();
    if (reveal <= 0) return;

    switch (action.operation) {
      case WhiteboardOperation.drawNode:
        _paintNode(canvas, size, action, reveal);
        break;
      case WhiteboardOperation.drawArrow:
        _paintArrow(canvas, size, action, reveal);
        break;
      case WhiteboardOperation.highlight:
        _paintHighlight(canvas, size, action, reveal);
        break;
      case WhiteboardOperation.writeMath:
      case WhiteboardOperation.clear:
        break;
    }
  }

  void _paintNode(Canvas canvas, Size size, WhiteboardAction action, double fraction) {
    final geometry = _pathCache.forAction(action, size, textDirection);
    final rect = geometry.nodeRect!;
    final color = _styleColor(action.style);

    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(11)),
      Paint()
        ..color = color.withOpacity(0.10 * fraction)
        ..style = PaintingStyle.fill
        ..isAntiAlias = true,
    );
    _drawMetricProgress(canvas, geometry, fraction, color, action.style);

    final textPainter = geometry.nodeLabel;
    if (textPainter != null && fraction > 0) {
      textPainter.paint(
        canvas,
        Offset(
          rect.center.dx - textPainter.width / 2,
          rect.center.dy - textPainter.height / 2,
        ),
      );
    }
  }

  void _paintArrow(Canvas canvas, Size size, WhiteboardAction action, double fraction) {
    final geometry = _pathCache.forAction(action, size, textDirection);
    _drawMetricProgress(
      canvas,
      geometry,
      fraction,
      _styleColor(action.style),
      action.style,
    );

    final textPainter = geometry.arrowLabel;
    if (textPainter != null && fraction > 0) {
      final start = Offset(action.x! * size.width, action.y! * size.height);
      final end = Offset(action.endX! * size.width, action.endY! * size.height);
      final middle = Offset.lerp(start, end, 0.5)!;
      textPainter.paint(canvas, middle - Offset(textPainter.width / 2, 8));
    }
  }

  void _paintHighlight(
    Canvas canvas,
    Size size,
    WhiteboardAction action,
    double fraction,
  ) {
    final geometry = _pathCache.forAction(action, size, textDirection);
    final color = _styleColor(action.style);
    final reveal = fraction.clamp(0.0, 1.0).toDouble();
    final pulse = 0.72 + highlightPulse.value * 0.28;
    final opacity = reveal * pulse;

    canvas.drawPath(
      geometry.path,
      Paint()
        ..color = color.withOpacity(0.10 * opacity)
        ..style = PaintingStyle.fill
        ..isAntiAlias = true,
    );
    canvas.drawPath(
      geometry.path,
      Paint()
        ..color = color.withOpacity(0.35 * opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 7 * opacity)
        ..isAntiAlias = true,
    );
    _drawMetricProgress(canvas, geometry, opacity, color, action.style);
  }

  void _drawMetricProgress(
    Canvas canvas,
    CachedActionPath geometry,
    double fraction,
    Color color,
    WhiteboardStyle? style,
  ) {
    if (geometry.totalLength <= 0) return;
    final remaining = geometry.totalLength * fraction.clamp(0.0, 1.0);
    final path = Path();
    var consumed = 0.0;

    for (final metric in geometry.metrics) {
      if (consumed >= remaining) break;
      final visibleLength = math.min(metric.length, remaining - consumed).toDouble();
      if (style == WhiteboardStyle.dashed) {
        const dashLength = 9.0;
        const gapLength = 6.0;
        var offset = 0.0;
        while (offset < visibleLength) {
          final end = math.min(offset + dashLength, visibleLength).toDouble();
          if (end > offset) path.addPath(metric.extractPath(offset, end), Offset.zero);
          offset += dashLength + gapLength;
        }
      } else if (visibleLength > 0) {
        path.addPath(metric.extractPath(0, visibleLength), Offset.zero);
      }
      consumed += metric.length;
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = color.withOpacity(fraction.clamp(0.0, 1.0).toDouble())
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true,
    );
  }

  static Color _styleColor(WhiteboardStyle? style) => switch (style) {
        WhiteboardStyle.primary => const Color(0xFF2F67D8),
        WhiteboardStyle.accent => const Color(0xFF7752C8),
        WhiteboardStyle.warning => const Color(0xFFE18A18),
        WhiteboardStyle.dashed => const Color(0xFF286F79),
        null => const Color(0xFF2F67D8),
      };

  @override
  bool shouldRepaint(covariant WhiteboardCanvasPainter oldDelegate) =>
      oldDelegate.controller != controller ||
      oldDelegate.textDirection != textDirection ||
      oldDelegate.highlightPulse != highlightPulse;
}
