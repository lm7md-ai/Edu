import 'dart:math' as math;
import 'dart:ui';

import 'package:edu/features/whiteboard/domain/entities/whiteboard_sync_step.dart';
import 'package:flutter/painting.dart';

/// Cached immutable geometry and PathMetrics for an action at one viewport
/// size. Recomputed only when the board size or text direction changes.
final class CachedActionPath {
  factory CachedActionPath(
    Path path, {
    Rect? nodeRect,
    TextPainter? nodeLabel,
    TextPainter? arrowLabel,
  }) {
    final metrics = path.computeMetrics().toList(growable: false);
    final totalLength = metrics.fold<double>(
      0,
      (double sum, PathMetric metric) => sum + metric.length,
    );
    return CachedActionPath._(
      path,
      metrics,
      totalLength,
      nodeRect,
      nodeLabel,
      arrowLabel,
    );
  }

  const CachedActionPath._(
    this.path,
    this.metrics,
    this.totalLength,
    this.nodeRect,
    this.nodeLabel,
    this.arrowLabel,
  );

  final Path path;
  final List<PathMetric> metrics;
  final double totalLength;
  final Rect? nodeRect;
  final TextPainter? nodeLabel;
  final TextPainter? arrowLabel;
}

final class PathMetricCache {
  Size? _cachedSize;
  TextDirection? _cachedDirection;
  final Map<WhiteboardAction, CachedActionPath> _paths =
      <WhiteboardAction, CachedActionPath>{};

  CachedActionPath forAction(
    WhiteboardAction action,
    Size size,
    TextDirection textDirection,
  ) {
    if (_cachedSize != size || _cachedDirection != textDirection) {
      _cachedSize = size;
      _cachedDirection = textDirection;
      _paths.clear();
    }
    return _paths.putIfAbsent(action, () {
      if (action.operation == WhiteboardOperation.drawNode) {
        final rect = nodeRect(action, size, textDirection);
        final label = _nodeLabel(action, rect, textDirection);
        final path = Path()
          ..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(11)));
        return CachedActionPath(path, nodeRect: rect, nodeLabel: label);
      }
      final path = _buildPath(action, size);
      final arrowLabel = action.operation == WhiteboardOperation.drawArrow &&
              action.content != null
          ? _arrowLabel(action, size, textDirection)
          : null;
      return CachedActionPath(path, arrowLabel: arrowLabel);
    });
  }

  void clear() {
    _cachedSize = null;
    _cachedDirection = null;
    _paths.clear();
  }

  static Path _buildPath(WhiteboardAction action, Size size) {
    final mapper = _Mapper(size);
    final path = Path();
    switch (action.operation) {
      case WhiteboardOperation.drawNode:
        break;
      case WhiteboardOperation.drawArrow:
        final start = mapper.point(action.x!, action.y!);
        final end = mapper.point(action.endX!, action.endY!);
        final delta = end - start;
        final length = delta.distance;
        path.moveTo(start.dx, start.dy);
        path.lineTo(end.dx, end.dy);
        if (length > 0.001) {
          final unit = delta / length;
          final normal = Offset(-unit.dy, unit.dx);
          const headLength = 10.0;
          const headHalfWidth = 5.0;
          final base = end - unit * headLength;
          path.moveTo(end.dx, end.dy);
          path.lineTo((base + normal * headHalfWidth).dx,
              (base + normal * headHalfWidth).dy);
          path.moveTo(end.dx, end.dy);
          path.lineTo((base - normal * headHalfWidth).dx,
              (base - normal * headHalfWidth).dy);
        }
        break;
      case WhiteboardOperation.highlight:
        final first = mapper.point(action.x!, action.y!);
        final second = mapper.point(action.endX!, action.endY!);
        path.addRect(Rect.fromPoints(first, second));
        break;
      case WhiteboardOperation.writeMath:
      case WhiteboardOperation.clear:
        break;
    }
    return path;
  }

  static Rect nodeRect(
    WhiteboardAction action,
    Size size,
    TextDirection textDirection,
  ) {
    final maxWidth = math.max(1.0, math.min(280.0, size.width - 24)).toDouble();
    final textPainter = TextPainter(
      text: TextSpan(
        text: action.content ?? '',
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      textDirection: textDirection,
      maxLines: 2,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);

    final width = math.min(size.width, textPainter.width + 22).toDouble();
    final height = math.min(size.height, textPainter.height + 16).toDouble();
    final center = _Mapper(size).point(action.x!, action.y!);
    final left = (center.dx - width / 2).clamp(0.0, size.width - width).toDouble();
    final top = (center.dy - height / 2).clamp(0.0, size.height - height).toDouble();
    return Rect.fromLTWH(left, top, width, height);
  }

  static TextPainter _arrowLabel(
    WhiteboardAction action,
    Size size,
    TextDirection textDirection,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: action.content,
        style: TextStyle(
          color: _styleColor(action.style),
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: textDirection,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: math.min(200.0, size.width).toDouble());
    return painter;
  }

  static Color _styleColor(WhiteboardStyle? style) => switch (style) {
        WhiteboardStyle.primary => const Color(0xFF2F67D8),
        WhiteboardStyle.accent => const Color(0xFF7752C8),
        WhiteboardStyle.warning => const Color(0xFFE18A18),
        WhiteboardStyle.dashed => const Color(0xFF286F79),
        null => const Color(0xFF2F67D8),
      };

  static TextPainter _nodeLabel(
    WhiteboardAction action,
    Rect rect,
    TextDirection textDirection,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: action.content ?? '',
        style: const TextStyle(
          color: Color(0xFF182238),
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: textDirection,
      maxLines: 2,
      ellipsis: '…',
    )..layout(maxWidth: math.max(1.0, rect.width - 22).toDouble());
    return painter;
  }
}

final class _Mapper {
  const _Mapper(this.size);

  final Size size;

  Offset point(double x, double y) => Offset(x * size.width, y * size.height);
}
