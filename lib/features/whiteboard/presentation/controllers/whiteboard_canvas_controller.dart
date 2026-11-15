import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';

import 'package:edu/features/whiteboard/domain/services/board_state_tracker.dart';
import 'package:edu/features/whiteboard/domain/entities/student_stylus_event.dart';
import 'package:edu/features/whiteboard/domain/entities/whiteboard_sync_step.dart';
import 'package:edu/features/whiteboard/presentation/controllers/audio_synced_whiteboard_step_controller.dart';
import 'package:edu/features/whiteboard/presentation/controllers/board_coordinate_mapper.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:perfect_freehand/perfect_freehand.dart';

/// Coordinates semantic board state, audio-synced tutor steps, and local ink.
final class WhiteboardCanvasController extends ChangeNotifier {
  WhiteboardCanvasController({
    required TickerProvider vsync,
    required PcmStepScheduler scheduler,
    this.acceptTouchInput = true,
    Duration minimumSchedulingLead = const Duration(milliseconds: 120),
  }) : boardState = BoardStateTracker() {
    playback = AudioSyncedWhiteboardStepController(
      vsync: vsync,
      scheduler: scheduler,
      minimumSchedulingLead: minimumSchedulingLead,
      onActionStarted: _onActionStarted,
      onActionCompleted: _onActionCompleted,
      onStepCompleted: _onStepCompleted,
    );
    playback.addListener(_onPlaybackChanged);
  }

  static const int maxPointsPerStroke = 4096;
  static const int maxActivePointers = 10;
  static const int maxInkPoints = 65536;
  static const int maxCompletedStrokes = 512;

  final BoardStateTracker boardState;
  final bool acceptTouchInput;
  late final AudioSyncedWhiteboardStepController playback;

  final StreamController<StudentStylusEvent> _stylusEvents =
      StreamController<StudentStylusEvent>.broadcast(sync: true);
  final ValueNotifier<int> mathOverlayRevision = ValueNotifier<int>(0);
  final Map<int, _MutableInkStroke> _activeStrokes = <int, _MutableInkStroke>{};
  final List<_MutableInkStroke> _completedStrokes = <_MutableInkStroke>[];

  int _totalInkPoints = 0;
  int _inkRevision = 0;
  int _cachedInkRevision = -1;
  Size? _cachedInkSize;
  List<Path> _cachedInkPaths = const <Path>[];
  bool _disposed = false;

  Stream<StudentStylusEvent> get studentStylusEvents => _stylusEvents.stream;

  Future<StepPlaybackResult> enqueueStep({
    required WhiteboardSyncStep step,
    required List<Uint8List> pcmChunks,
    required int sampleRateHz,
    required int channels,
  }) =>
      playback.enqueueStep(
        step: step,
        pcmChunks: pcmChunks,
        sampleRateHz: sampleRateHz,
        channels: channels,
      );

  Future<void> bargeIn() async {
    if (_disposed) return;
    final flush = playback.bargeIn();
    _bumpMathOverlayRevision();
    notifyListeners();
    await flush;
  }

  /// Consumes pointer down/move/up/cancel and publishes normalized events.
  /// Returns false for unsupported pointer kinds or an unmatched move/up.
  bool handlePointerEvent(PointerEvent event, Size viewportSize) {
    if (_disposed || !_acceptsKind(event.kind) ||
        !viewportSize.width.isFinite || !viewportSize.height.isFinite ||
        viewportSize.width <= 0 || viewportSize.height <= 0 ||
        !event.localPosition.dx.isFinite || !event.localPosition.dy.isFinite) {
      return false;
    }

    final StudentStylusPhase phase;
    if (event is PointerDownEvent) {
      phase = StudentStylusPhase.down;
    } else if (event is PointerMoveEvent) {
      phase = StudentStylusPhase.move;
    } else if (event is PointerUpEvent) {
      phase = StudentStylusPhase.up;
    } else if (event is PointerCancelEvent) {
      phase = StudentStylusPhase.cancel;
    } else {
      return false;
    }

    if (phase != StudentStylusPhase.down &&
        !_activeStrokes.containsKey(event.pointer)) {
      return false;
    }
    if (phase == StudentStylusPhase.down &&
        !_activeStrokes.containsKey(event.pointer) &&
        _activeStrokes.length >= maxActivePointers) {
      return false;
    }

    final normalized = _normalizedPoint(event.localPosition, viewportSize);
    final pressure = _normalizedPressure(event);
    final stylusEvent = StudentStylusEvent(
      pointerId: event.pointer,
      phase: phase,
      x: normalized.x,
      y: normalized.y,
      pressure: pressure,
      timestampUs: event.timeStamp.inMicroseconds < 0
          ? 0
          : event.timeStamp.inMicroseconds,
    );

    switch (phase) {
      case StudentStylusPhase.down:
        final replacedStroke = _activeStrokes.remove(event.pointer);
        if (replacedStroke != null) {
          _totalInkPoints -= replacedStroke.points.length;
        }
        final stroke = _MutableInkStroke();
        if (_totalInkPoints < maxInkPoints) {
          stroke.add(NormalizedInkPoint(normalized.x, normalized.y, pressure));
          _totalInkPoints++;
        }
        _activeStrokes[event.pointer] = stroke;
        break;
      case StudentStylusPhase.move:
        _appendSample(event.pointer, normalized, pressure);
        break;
      case StudentStylusPhase.up:
        _appendSample(event.pointer, normalized, pressure);
        final stroke = _activeStrokes.remove(event.pointer);
        if (stroke != null && stroke.points.isNotEmpty) {
          stroke.complete();
          _completedStrokes.add(stroke);
          while (_completedStrokes.length > maxCompletedStrokes) {
            _totalInkPoints -= _completedStrokes.removeAt(0).points.length;
          }
        }
        break;
      case StudentStylusPhase.cancel:
        final stroke = _activeStrokes.remove(event.pointer);
        if (stroke != null) _totalInkPoints -= stroke.points.length;
        break;
    }

    _invalidateInk();
    _stylusEvents.add(stylusEvent);
    notifyListeners();
    return true;
  }

  /// Applies normalized pen events received from a paired companion.
  /// Remote pointer IDs are isolated in a high-bit namespace so they do not
  /// collide with local touch/stylus pointer identifiers.
  bool applyRemoteStylusEvent(StudentStylusEvent event) {
    if (_disposed) return false;
    final pointerId = 0x40000000 | (event.pointerId & 0x3fffffff);
    switch (event.phase) {
      case StudentStylusPhase.down:
        final previous = _activeStrokes.remove(pointerId);
        if (previous != null) _totalInkPoints -= previous.points.length;
        if (_activeStrokes.length >= maxActivePointers) return false;
        final stroke = _MutableInkStroke();
        if (_totalInkPoints < maxInkPoints) {
          stroke.add(NormalizedInkPoint(event.x, event.y, event.pressure));
          _totalInkPoints++;
        }
        _activeStrokes[pointerId] = stroke;
        break;
      case StudentStylusPhase.move:
        if (!_activeStrokes.containsKey(pointerId)) return false;
        _appendSample(pointerId, NormalizedInkPoint(event.x, event.y, event.pressure), event.pressure);
        break;
      case StudentStylusPhase.up:
        if (!_activeStrokes.containsKey(pointerId)) return false;
        _appendSample(pointerId, NormalizedInkPoint(event.x, event.y, event.pressure), event.pressure);
        final stroke = _activeStrokes.remove(pointerId);
        if (stroke != null && stroke.points.isNotEmpty) {
          stroke.complete();
          _completedStrokes.add(stroke);
          while (_completedStrokes.length > maxCompletedStrokes) {
            _totalInkPoints -= _completedStrokes.removeAt(0).points.length;
          }
        }
        break;
      case StudentStylusPhase.cancel:
        final stroke = _activeStrokes.remove(pointerId);
        if (stroke == null) return false;
        _totalInkPoints -= stroke.points.length;
        break;
    }
    _invalidateInk();
    notifyListeners();
    return true;
  }

  /// Cached freehand polygons in current logical-pixel coordinates.
  ///
  /// `perfect_freehand` recomputes only a changed stroke, or all strokes once
  /// after a viewport resize; static ink is not rebuilt on animation frames.
  List<Path> freehandPaths(Size viewportSize) {
    if (_cachedInkRevision == _inkRevision && _cachedInkSize == viewportSize) {
      return _cachedInkPaths;
    }
    final paths = <Path>[
      for (final stroke in _completedStrokes)
        if (stroke.points.isNotEmpty) stroke.pathFor(viewportSize),
      for (final stroke in _activeStrokes.values)
        if (stroke.points.isNotEmpty) stroke.pathFor(viewportSize),
    ];
    _cachedInkRevision = _inkRevision;
    _cachedInkSize = viewportSize;
    _cachedInkPaths = List<Path>.unmodifiable(paths);
    return _cachedInkPaths;
  }

  List<List<NormalizedInkPoint>> get inkStrokes =>
      List<List<NormalizedInkPoint>>.unmodifiable(<List<NormalizedInkPoint>>[
        for (final stroke in _completedStrokes)
          List<NormalizedInkPoint>.unmodifiable(stroke.points),
        for (final stroke in _activeStrokes.values)
          List<NormalizedInkPoint>.unmodifiable(stroke.points),
      ]);

  /// Instant reset. Tutor `clear` actions invoke this state path at the audio
  /// start boundary; no image capture or asynchronous work is performed.
  Future<void> resetBoard({bool clearStudentInk = true}) async {
    if (_disposed) return;
    final audioFlush = playback.bargeIn();
    boardState.reset();
    _bumpMathOverlayRevision();
    if (clearStudentInk) {
      _activeStrokes.clear();
      _completedStrokes.clear();
      _totalInkPoints = 0;
      _invalidateInk();
    }
    notifyListeners();
    await audioFlush;
  }

  void clearStudentInk() {
    if (_disposed) return;
    _activeStrokes.clear();
    _completedStrokes.clear();
    _totalInkPoints = 0;
    _invalidateInk();
    notifyListeners();
  }

  bool _acceptsKind(PointerDeviceKind kind) {
    if (kind == PointerDeviceKind.stylus ||
        kind == PointerDeviceKind.invertedStylus) {
      return true;
    }
    return acceptTouchInput && kind == PointerDeviceKind.touch;
  }

  static NormalizedInkPoint _normalizedPoint(Offset local, Size size) {
    final normalized = BoardCoordinateMapper(size).toNormalized(local);
    return NormalizedInkPoint(normalized.dx, normalized.dy, 0.5);
  }

  static double _normalizedPressure(PointerEvent event) {
    final range = event.pressureMax - event.pressureMin;
    if (range <= 0 || !range.isFinite) return 0.5;
    return ((event.pressure - event.pressureMin) / range)
        .clamp(0.0, 1.0)
        .toDouble();
  }

  void _appendSample(int pointerId, NormalizedInkPoint point, double pressure) {
    final stroke = _activeStrokes[pointerId];
    if (stroke == null ||
        stroke.points.length >= maxPointsPerStroke ||
        _totalInkPoints >= maxInkPoints) {
      return;
    }

    final sample = NormalizedInkPoint(point.x, point.y, pressure);
    if (stroke.points.isNotEmpty) {
      final previous = stroke.points.last;
      final dx = sample.x - previous.x;
      final dy = sample.y - previous.y;
      if (dx * dx + dy * dy < 0.00000025) return;
    }
    stroke.add(sample);
    _totalInkPoints++;
  }

  void _onActionStarted(WhiteboardSyncStep step, WhiteboardAction action) {
    if (action.operation == WhiteboardOperation.writeMath) {
      _bumpMathOverlayRevision();
      return;
    }
    if (action.operation != WhiteboardOperation.clear) return;
    boardState.applyAction(action);
    _bumpMathOverlayRevision();
    if (action.targetId == null) {
      _activeStrokes.clear();
      _completedStrokes.clear();
      _totalInkPoints = 0;
      _invalidateInk();
    }
    notifyListeners();
  }

  void _onActionCompleted(
    WhiteboardSyncStep step,
    int actionIndex,
    WhiteboardAction action,
  ) {
    if (actionIndex < 0 ||
        actionIndex >= step.actions.length ||
        step.actions[actionIndex] != action) {
      throw StateError('Audio controller reported an inconsistent action index.');
    }
    if (action.operation == WhiteboardOperation.clear) return;
    boardState.applyAction(action);
    _bumpMathOverlayRevision();
    notifyListeners();
  }

  void _onStepCompleted(WhiteboardSyncStep step) {
    if (step.actions.any((action) =>
        action.operation == WhiteboardOperation.writeMath ||
        action.operation == WhiteboardOperation.clear)) {
      _bumpMathOverlayRevision();
    }
    notifyListeners();
  }

  void _onPlaybackChanged() {
    if (!_disposed) notifyListeners();
  }

  void _bumpMathOverlayRevision() {
    mathOverlayRevision.value++;
  }

  void _invalidateInk() {
    _inkRevision++;
    _cachedInkRevision = -1;
    _cachedInkPaths = const <Path>[];
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    playback.removeListener(_onPlaybackChanged);
    playback.dispose();
    mathOverlayRevision.dispose();
    unawaited(_stylusEvents.close());
    super.dispose();
  }
}

@immutable
final class NormalizedInkPoint {
  const NormalizedInkPoint(this.x, this.y, this.pressure);

  final double x;
  final double y;
  final double pressure;
}

final class _MutableInkStroke {
  final List<NormalizedInkPoint> points = <NormalizedInkPoint>[];
  int _revision = 0;
  int _cachedRevision = -1;
  Size? _cachedSize;
  Path? _cachedPath;
  bool _isComplete = false;

  void add(NormalizedInkPoint point) {
    if (points.length >= WhiteboardCanvasController.maxPointsPerStroke) return;
    points.add(point);
    _revision++;
  }

  void complete() {
    _isComplete = true;
    _revision++;
  }

  Path pathFor(Size viewportSize) {
    if (_cachedRevision == _revision && _cachedSize == viewportSize) {
      return _cachedPath!;
    }

    final input = points
        .map(
          (point) => PointVector(
            point.x * viewportSize.width,
            point.y * viewportSize.height,
            point.pressure,
          ),
        )
        .toList(growable: false);
    final path = Path();
    if (input.isNotEmpty) {
      final outline = getStroke(
        input,
        options: StrokeOptions(
          size: 4.2,
          thinning: 0.55,
          smoothing: 0.55,
          streamline: 0.3,
          simulatePressure: false,
          isComplete: _isComplete,
        ),
      );
      if (outline.length >= 3) {
        path.moveTo(outline.first.dx, outline.first.dy);
        for (final point in outline.skip(1)) {
          path.lineTo(point.dx, point.dy);
        }
        path.close();
      } else {
        const radius = 2.1;
        final point = input.last;
        path.addOval(
          Rect.fromCircle(center: Offset(point.x, point.y), radius: radius),
        );
      }
    }

    _cachedRevision = _revision;
    _cachedSize = viewportSize;
    _cachedPath = path;
    return path;
  }
}
