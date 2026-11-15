import 'dart:math' as math;
import 'dart:ui';

import 'package:edu/features/whiteboard/domain/entities/board_element.dart';
import 'package:edu/features/whiteboard/domain/entities/whiteboard_sync_step.dart';
import 'package:edu/features/whiteboard/presentation/controllers/whiteboard_canvas_controller.dart';
import 'package:edu/features/whiteboard/presentation/rendering/whiteboard_canvas_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

/// Responsive normalized-coordinate whiteboard for tutor rendering and student
/// S-Pen/touch input. Supply [snapshotBoundaryKey] to the on-demand snapshot
/// exporter; this widget never captures a snapshot automatically.
final class WhiteboardCanvas extends StatefulWidget {
  const WhiteboardCanvas({
    required this.controller,
    required this.snapshotBoundaryKey,
    this.backgroundColor = const Color(0xFFFCFCFE),
    super.key,
  });

  final WhiteboardCanvasController controller;
  final GlobalKey snapshotBoundaryKey;
  final Color backgroundColor;

  @override
  State<WhiteboardCanvas> createState() => _WhiteboardCanvasState();
}

final class _WhiteboardCanvasState extends State<WhiteboardCanvas>
    with SingleTickerProviderStateMixin {
  late final AnimationController _highlightPulse;

  @override
  void initState() {
    super.initState();
    _highlightPulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
      lowerBound: 0,
      upperBound: 1,
      value: 0.5,
    );
    widget.controller.addListener(_syncHighlightPulse);
    _syncHighlightPulse();
  }

  @override
  void didUpdateWidget(covariant WhiteboardCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncHighlightPulse);
      widget.controller.addListener(_syncHighlightPulse);
      _syncHighlightPulse();
    }
  }

  void _syncHighlightPulse() {
    final persistentHighlight = widget.controller.boardState.hasHighlights;
    final step = widget.controller.playback.activeStep;
    final actionIndex = widget.controller.playback.activeActionIndex;
    final activeHighlight = step != null &&
        actionIndex >= 0 &&
        actionIndex < step.actions.length &&
        step.actions[actionIndex].operation == WhiteboardOperation.highlight &&
        widget.controller.playback.actionProgress(actionIndex) > 0;
    if (persistentHighlight || activeHighlight) {
      if (!_highlightPulse.isAnimating) _highlightPulse.repeat(reverse: true);
    } else if (_highlightPulse.isAnimating) {
      _highlightPulse.stop();
      _highlightPulse.value = 0.5;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncHighlightPulse);
    _highlightPulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textDirection = Directionality.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final width = constraints.maxWidth.isFinite ? constraints.maxWidth : 600.0;
        final height = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : width * 0.72;
        final boardSize = Size(width, height);

        return RepaintBoundary(
          key: widget.snapshotBoundaryKey,
          child: SizedBox(
            width: width,
            height: height,
            child: DecoratedBox(
              decoration: BoxDecoration(color: widget.backgroundColor),
              child: ClipRect(
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (event) =>
                      widget.controller.handlePointerEvent(event, boardSize),
                  onPointerMove: (event) =>
                      widget.controller.handlePointerEvent(event, boardSize),
                  onPointerUp: (event) =>
                      widget.controller.handlePointerEvent(event, boardSize),
                  onPointerCancel: (event) =>
                      widget.controller.handlePointerEvent(event, boardSize),
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      CustomPaint(
                        painter: WhiteboardCanvasPainter(
                          controller: widget.controller,
                          textDirection: textDirection,
                          highlightPulse: _highlightPulse,
                        ),
                      ),
                      ValueListenableBuilder<int>(
                        valueListenable: widget.controller.mathOverlayRevision,
                        builder: (context, revision, child) => Stack(
                          key: ValueKey<int>(revision),
                          fit: StackFit.expand,
                          children: _mathOverlays(boardSize, textDirection),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  List<Widget> _mathOverlays(Size size, TextDirection textDirection) {
    final actions = <String, WhiteboardAction>{};
    for (final BoardElement element in widget.controller.boardState.elements) {
      if (element.action.operation == WhiteboardOperation.writeMath) {
        actions[element.targetId] = element.action;
      }
    }

    final step = widget.controller.playback.activeStep;
    if (step != null) {
      final activeIndex = widget.controller.playback.activeActionIndex;
      if (activeIndex >= 0) {
        final action = step.actions[activeIndex];
        if (action.operation == WhiteboardOperation.writeMath) {
          actions[action.targetId!] = action;
        }
      }
    }

    return actions.values
        .map((action) => _buildMathOverlay(action, size, textDirection))
        .toList(growable: false);
  }

  Widget _buildMathOverlay(
    WhiteboardAction action,
    Size size,
    TextDirection textDirection,
  ) {
    final left = (action.x! * size.width)
        .clamp(0.0, math.max(0.0, size.width - 1));
    final top = (action.y! * size.height)
        .clamp(0.0, math.max(0.0, size.height - 1));
    final availableWidth = math.max(1.0, size.width - left).toDouble();
    final color = _mathColor(action.style);

    return Positioned(
      key: ValueKey<String>('math:${action.targetId}'),
      left: left.toDouble(),
      top: top.toDouble(),
      width: availableWidth,
      child: IgnorePointer(
        child: RepaintBoundary(
          child: Directionality(
            textDirection: textDirection,
            child: Math.tex(
              action.content!,
              textStyle: TextStyle(fontSize: 20, color: color),
            ),
          ),
        ),
      ),
    );
  }

  static Color _mathColor(WhiteboardStyle? style) => switch (style) {
        WhiteboardStyle.primary => const Color(0xFF2F67D8),
        WhiteboardStyle.accent => const Color(0xFF7752C8),
        WhiteboardStyle.warning => const Color(0xFFE18A18),
        WhiteboardStyle.dashed => const Color(0xFF286F79),
        null => const Color(0xFF2F67D8),
      };
}
