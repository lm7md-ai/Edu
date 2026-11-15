import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:edu/features/whiteboard/domain/entities/whiteboard_sync_step.dart';
import 'package:flutter/animation.dart';
import 'package:flutter/scheduler.dart';

/// Read-only hardware output clock. Frame positions must be monotonic and
/// measured after samples have left the device output queue.
abstract interface class AudioPlaybackClock {
  int get playedFramePosition;
  int get sampleRateHz;
}

/// Adapter for a native audio engine's lock-free played-frame counter.
///
/// The callback must be a synchronous O(1) read, such as a native-backed FFI
/// counter. It must not invoke a MethodChannel or wait on a Future from a frame
/// callback.
final class CallbackAudioPlaybackClock implements AudioPlaybackClock {
  CallbackAudioPlaybackClock({
    required int Function() readPlayedFramePosition,
    required this.sampleRateHz,
  })  : _readPlayedFramePosition = readPlayedFramePosition {
    if (sampleRateHz <= 0) {
      throw ArgumentError.value(sampleRateHz, 'sampleRateHz');
    }
  }

  final int Function() _readPlayedFramePosition;
  @override
  final int sampleRateHz;
  int _lastFrame = -1;

  @override
  int get playedFramePosition {
    final frame = _readPlayedFramePosition();
    if (frame < 0 || frame < _lastFrame) {
      throw StateError('Audio played-frame clock must be non-negative and monotonic.');
    }
    _lastFrame = frame;
    return frame;
  }
}

/// Output-device interval for one scheduled step. End is exclusive.
final class AudioPlaybackWindow {
  const AudioPlaybackWindow({
    required this.startFrame,
    required this.endFrame,
  }) : assert(startFrame >= 0 && endFrame > startFrame);

  final int startFrame;
  final int endFrame;
}

/// Native audio queue boundary used by the visual scheduler.
abstract interface class PcmStepScheduler {
  AudioPlaybackClock get clock;

  /// Schedules all chunks in order, no earlier than [notBeforeFrame].
  ///
  /// Returned frames use [clock]'s output frame domain (after any resampling).
  /// An implementation must settle an in-flight schedule request when
  /// [flush] is called and must cancel all not-yet-played audio before it
  /// completes.
  Future<AudioPlaybackWindow> scheduleStep({
    required int stepId,
    required List<Uint8List> pcmChunks,
    required int sampleRateHz,
    required int channels,
    required int notBeforeFrame,
  });

  /// Stops current playback and atomically flushes the native output queue.
  Future<void> flush();
}

typedef NativePcmEnqueue = Future<AudioPlaybackWindow> Function({
  required int stepId,
  required List<Uint8List> pcmChunks,
  required int sampleRateHz,
  required int channels,
  required int notBeforeFrame,
});

typedef NativePcmFlush = Future<void> Function();

/// Validating adapter around the JNI/FFI audio output functions. The native
/// implementation owns resampling, device scheduling, and its played-frame
/// counter; this adapter enforces the Dart-side protocol and cancellation epoch.
final class NativePcmStepScheduler implements PcmStepScheduler {
  NativePcmStepScheduler({
    required this.clock,
    required NativePcmEnqueue enqueueNative,
    required NativePcmFlush flushNative,
  })  : _enqueueNative = enqueueNative,
        _flushNative = flushNative;

  @override
  final AudioPlaybackClock clock;
  final NativePcmEnqueue _enqueueNative;
  final NativePcmFlush _flushNative;
  Future<void> _flushTail = Future<void>.value();
  int _generation = 0;

  @override
  Future<AudioPlaybackWindow> scheduleStep({
    required int stepId,
    required List<Uint8List> pcmChunks,
    required int sampleRateHz,
    required int channels,
    required int notBeforeFrame,
  }) async {
    if (stepId < 0 || stepId > 0xffffffff) {
      throw RangeError.range(stepId, 0, 0xffffffff, 'stepId');
    }
    if (sampleRateHz <= 0 || (channels != 1 && channels != 2)) {
      throw ArgumentError('PCM must have a positive sample rate and one or two channels.');
    }
    if (notBeforeFrame < clock.playedFramePosition) {
      throw ArgumentError.value(notBeforeFrame, 'notBeforeFrame', 'Frame is already played.');
    }
    if (pcmChunks.isEmpty ||
        pcmChunks.any((chunk) => chunk.isEmpty || chunk.length % (2 * channels) != 0)) {
      throw ArgumentError('PCM chunks must contain complete S16LE sample frames.');
    }

    final generation = _generation;
    await _flushTail;
    if (generation != _generation) throw const PcmScheduleCancelled();
    final window = await _enqueueNative(
      stepId: stepId,
      pcmChunks: List<Uint8List>.unmodifiable(pcmChunks),
      sampleRateHz: sampleRateHz,
      channels: channels,
      notBeforeFrame: notBeforeFrame,
    );
    if (generation != _generation) throw const PcmScheduleCancelled();
    if (window.startFrame < notBeforeFrame ||
        window.startFrame < 0 ||
        window.endFrame <= window.startFrame) {
      throw StateError('Native audio output returned an invalid playback window.');
    }
    return window;
  }

  @override
  Future<void> flush() {
    _generation++;
    final previousFlush = _flushTail;
    final operation = () async {
      try {
        await previousFlush;
      } on Object {
        // A prior failed flush must not prevent this cancellation attempt.
      }
      // Invoke native flush immediately after prior flushes, rather than
      // waiting for an enqueue future; native flush is responsible for
      // settling/canceling any enqueue currently in flight.
      await _flushNative();
    }();
    _flushTail = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return operation;
  }
}

final class PcmScheduleCancelled implements Exception {
  const PcmScheduleCancelled();
}

enum StepPlaybackResult { completed, cancelled }

/// Serializes tutor steps and derives their visual progress from the audio
/// device's played-frame counter, never from wall-clock timers.
///
/// Its [AnimationController] is manually driven from a Flutter vsync ticker.
/// The ticker only samples the synchronous hardware clock; it does not
/// estimate audio position from elapsed frame time.
final class AudioSyncedWhiteboardStepController extends ChangeNotifier {
  AudioSyncedWhiteboardStepController({
    required TickerProvider vsync,
    required PcmStepScheduler scheduler,
    this.minimumSchedulingLead = const Duration(milliseconds: 120),
    this.maxQueuedSteps = 8,
    this.maxQueuedPcmBytes = 32 * 1024 * 1024,
    this.onStepStarted,
    this.onActionStarted,
    this.onActionCompleted,
    this.onStepCompleted,
  })  : _scheduler = scheduler,
        progress = AnimationController(
          vsync: vsync,
          lowerBound: 0,
          upperBound: 1,
          value: 0,
        ) {
    _frameTicker = vsync.createTicker(_onFrame);
  }

  final PcmStepScheduler _scheduler;
  final Duration minimumSchedulingLead;
  final int maxQueuedSteps;
  final int maxQueuedPcmBytes;
  final void Function(WhiteboardSyncStep step)? onStepStarted;
  final void Function(WhiteboardSyncStep step, WhiteboardAction action)?
      onActionStarted;
  final void Function(
    WhiteboardSyncStep step,
    int actionIndex,
    WhiteboardAction action,
  )? onActionCompleted;
  final void Function(WhiteboardSyncStep step)? onStepCompleted;

  /// Notifies Flutter painters/widgets. Its value is set from the hardware
  /// frame clock and is never advanced by `forward`, `repeat`, or a Timer.
  final AnimationController progress;

  late final Ticker _frameTicker;
  final Queue<_QueuedAudioVisualStep> _queue = Queue<_QueuedAudioVisualStep>();
  final Set<int> _outstandingStepIds = <int>{};
  _QueuedAudioVisualStep? _active;
  AudioPlaybackWindow? _window;
  bool _draining = false;
  bool _disposed = false;
  bool _audioHasStarted = false;
  bool _hasScheduledAudio = false;
  int _generation = 0;
  int _queuedPcmBytes = 0;
  int _announcedActionCount = 0;
  int _completedActionCount = 0;

  WhiteboardSyncStep? get activeStep => _active?.step;
  int get queuedStepCount => _queue.length;
  AudioPlaybackClock get clock => _scheduler.clock;

  /// Index of the action currently receiving the audio-aligned time slice.
  int get activeActionIndex {
    final count = activeStep?.actions.length ?? 0;
    if (count == 0) return -1;
    if (progress.value >= 1) return count - 1;
    return (progress.value * count).floor().clamp(0, count - 1).toInt();
  }

  double actionProgress(int actionIndex) {
    final count = activeStep?.actions.length ?? 0;
    if (actionIndex < 0 || actionIndex >= count) return 0;
    return (progress.value * count - actionIndex).clamp(0.0, 1.0).toDouble();
  }

  bool isActionComplete(int actionIndex) {
    final count = activeStep?.actions.length ?? 0;
    if (actionIndex < 0 || actionIndex >= count) return false;
    return progress.value >= (actionIndex + 1) / count;
  }

  /// Adds an item to a FIFO queue and returns its terminal disposition.
  /// Queue order is the order in which this method is called. PCM buffers are
  /// retained without a UI-isolate byte copy; callers must not mutate them
  /// until the returned future completes.
  Future<StepPlaybackResult> enqueueStep({
    required WhiteboardSyncStep step,
    required List<Uint8List> pcmChunks,
    required int sampleRateHz,
    required int channels,
  }) {
    if (_disposed) {
      return Future<StepPlaybackResult>.error(
        StateError('Audio/visual controller is disposed.'),
      );
    }
    if (_outstandingStepIds.contains(step.stepId)) {
      return Future<StepPlaybackResult>.error(
        StateError('Step id ${step.stepId} is already queued or playing.'),
      );
    }
    if (pcmChunks.isEmpty) {
      return Future<StepPlaybackResult>.error(
        ArgumentError.value(pcmChunks, 'pcmChunks', 'A step requires PCM audio.'),
      );
    }
    if (sampleRateHz <= 0 || (channels != 1 && channels != 2)) {
      return Future<StepPlaybackResult>.error(
        ArgumentError('PCM must have a positive sample rate and one or two channels.'),
      );
    }
    if (pcmChunks.any((chunk) =>
        chunk.isEmpty || chunk.length % (2 * channels) != 0)) {
      return Future<StepPlaybackResult>.error(
        ArgumentError('PCM chunks must contain complete S16LE sample frames.'),
      );
    }

    final totalPcmBytes = pcmChunks.fold<int>(
      0,
      (int total, Uint8List chunk) => total + chunk.length,
    );
    final outstandingSteps = _queue.length + (_active == null ? 0 : 1);
    if (maxQueuedSteps < 1 || outstandingSteps >= maxQueuedSteps) {
      return Future<StepPlaybackResult>.error(
        StateError('Audio/visual queue is at its step capacity.'),
      );
    }
    if (maxQueuedPcmBytes < 1 ||
        totalPcmBytes > maxQueuedPcmBytes - _queuedPcmBytes) {
      return Future<StepPlaybackResult>.error(
        StateError('Audio/visual queue is at its PCM memory limit.'),
      );
    }

    final job = _QueuedAudioVisualStep(
      step: step,
      pcmChunks: List<Uint8List>.unmodifiable(pcmChunks),
      sampleRateHz: sampleRateHz,
      channels: channels,
      byteCount: totalPcmBytes,
    );
    _queuedPcmBytes += totalPcmBytes;
    _outstandingStepIds.add(step.stepId);
    _queue.addLast(job);
    unawaited(_drainQueue());
    return job.completer.future;
  }

  /// Barge-in cancellation. The visible partial step and all queued steps are
  /// canceled synchronously before awaiting the native queue flush.
  Future<void> bargeIn() async {
    if (_disposed) return;
    _generation++;
    _frameTicker.stop();
    _window = null;
    _audioHasStarted = false;
    _hasScheduledAudio = false;
    _announcedActionCount = 0;
    _completedActionCount = 0;
    progress.value = 0;

    final active = _active;
    _active = null;
    if (active != null) _complete(active, StepPlaybackResult.cancelled);

    while (_queue.isNotEmpty) {
      _complete(_queue.removeFirst(), StepPlaybackResult.cancelled);
    }
    notifyListeners();

    await _scheduler.flush();
  }

  Future<void> _drainQueue() async {
    if (_draining || _disposed) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty && !_disposed) {
        final job = _queue.removeFirst();
        final generation = _generation;
        _active = job;
        _window = null;
        _audioHasStarted = false;
        _announcedActionCount = 0;
        _completedActionCount = 0;
        progress.value = 0;
        _frameTicker.start();
        notifyListeners();

        try {
          final audioClock = _scheduler.clock;
          if (audioClock.sampleRateHz <= 0 || minimumSchedulingLead.isNegative) {
            throw StateError('Audio clock or scheduling lead is invalid.');
          }
          final currentFrame = audioClock.playedFramePosition;
          if (currentFrame < 0) throw StateError('Audio frame clock is negative.');
          final leadFrames = _hasScheduledAudio
              ? 0
              : (audioClock.sampleRateHz *
                      minimumSchedulingLead.inMicroseconds /
                      Duration.microsecondsPerSecond)
                  .ceil();
          final notBeforeFrame = currentFrame + (leadFrames < 1 && !_hasScheduledAudio
              ? 1
              : leadFrames);

          final window = await _scheduler.scheduleStep(
            stepId: job.step.stepId,
            pcmChunks: job.pcmChunks,
            sampleRateHz: job.sampleRateHz,
            channels: job.channels,
            notBeforeFrame: notBeforeFrame,
          );

          if (_disposed || generation != _generation || !identical(_active, job)) {
            _complete(job, StepPlaybackResult.cancelled);
            continue;
          }
          if (window.startFrame < notBeforeFrame ||
              window.startFrame < 0 ||
              window.endFrame <= window.startFrame) {
            throw StateError('Audio scheduler returned an invalid playback window.');
          }
          if (audioClock.playedFramePosition >= window.endFrame) {
            throw StateError('Audio scheduler acknowledged a step after it had ended.');
          }

          _window = window;
          _hasScheduledAudio = true;
          notifyListeners();
          await job.completer.future;
        } on Object catch (error, stackTrace) {
          if (identical(_active, job) && generation == _generation) {
            _failActive(job, error, stackTrace);
          } else {
            _complete(job, StepPlaybackResult.cancelled);
          }
        } finally {
          if (identical(_active, job)) {
            _active = null;
            _window = null;
            _frameTicker.stop();
            notifyListeners();
          }
        }
      }
    } finally {
      _draining = false;
      if (_queue.isNotEmpty && !_disposed) unawaited(_drainQueue());
    }
  }

  void _onFrame(Duration elapsed) {
    if (_disposed) return;
    final job = _active;
    final window = _window;
    final generation = _generation;
    if (job == null || window == null) return;

    try {
      final playedFrame = _scheduler.clock.playedFramePosition;
      if (playedFrame < window.startFrame) return;

      if (!_audioHasStarted) {
        _audioHasStarted = true;
        onStepStarted?.call(job.step);
      }

      final fraction = ((playedFrame - window.startFrame) /
              (window.endFrame - window.startFrame))
          .clamp(0.0, 1.0)
          .toDouble();
      _advanceActions(job.step, fraction);
      if (_disposed || generation != _generation || !identical(_active, job)) {
        return;
      }

      if ((progress.value - fraction).abs() > 0.000001) {
        progress.value = fraction;
      }
      notifyListeners();

      if (fraction >= 1) {
        onStepCompleted?.call(job.step);
        _active = null;
        _window = null;
        _audioHasStarted = false;
        if (_queue.isEmpty) _hasScheduledAudio = false;
        _frameTicker.stop();
        _complete(job, StepPlaybackResult.completed);
        notifyListeners();
      }
    } on Object catch (error, stackTrace) {
      _failActive(job, error, stackTrace);
    }
  }

  void _advanceActions(WhiteboardSyncStep step, double fraction) {
    final count = step.actions.length;
    final completedCount = (fraction * count).floor().clamp(0, count);
    final startedCount = count == 0
        ? 0
        : fraction >= 1
            ? count
            : (fraction * count).floor() + 1;
    final actionsToVisit =
        startedCount > completedCount ? startedCount : completedCount;

    for (var index = 0; index < actionsToVisit; index++) {
      if (index == _announcedActionCount && index < startedCount) {
        _announcedActionCount++;
        onActionStarted?.call(step, step.actions[index]);
      }
      if (index == _completedActionCount && index < completedCount) {
        _completedActionCount++;
        onActionCompleted?.call(step, index, step.actions[index]);
      }
    }
  }

  void _failActive(
    _QueuedAudioVisualStep job,
    Object error,
    StackTrace stackTrace,
  ) {
    if (!identical(_active, job)) return;
    _generation++;
    _frameTicker.stop();
    _active = null;
    _window = null;
    _audioHasStarted = false;
    _hasScheduledAudio = false;
    if (!_disposed) {
      progress.value = 0;
      notifyListeners();
    }
    _completeError(job, error, stackTrace);
    while (_queue.isNotEmpty) {
      _complete(_queue.removeFirst(), StepPlaybackResult.cancelled);
    }
    unawaited(_flushAfterFailure());
  }

  Future<void> _flushAfterFailure() async {
    try {
      await _scheduler.flush();
    } on Object {
      // The original scheduling/playback failure is delivered to the caller.
    }
  }

  void _complete(
    _QueuedAudioVisualStep job,
    StepPlaybackResult result,
  ) {
    if (!job.completer.isCompleted) job.completer.complete(result);
    _releasePcmReservation(job);
  }

  void _completeError(
    _QueuedAudioVisualStep job,
    Object error,
    StackTrace stackTrace,
  ) {
    if (!job.completer.isCompleted) {
      job.completer.completeError(error, stackTrace);
    }
    _releasePcmReservation(job);
  }

  void _releasePcmReservation(_QueuedAudioVisualStep job) {
    if (job.released) return;
    job.released = true;
    _outstandingStepIds.remove(job.step.stepId);
    _queuedPcmBytes -= job.byteCount;
    assert(_queuedPcmBytes >= 0);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _frameTicker.dispose();
    _window = null;
    final active = _active;
    _active = null;
    if (active != null) _complete(active, StepPlaybackResult.cancelled);
    while (_queue.isNotEmpty) {
      _complete(_queue.removeFirst(), StepPlaybackResult.cancelled);
    }
    progress.dispose();
    unawaited(_flushAfterDispose());
    super.dispose();
  }

  Future<void> _flushAfterDispose() async {
    try {
      await _scheduler.flush();
    } on Object {
      // Disposal is best-effort; no UI listener remains to receive the error.
    }
  }
}

final class _QueuedAudioVisualStep {
  _QueuedAudioVisualStep({
    required this.step,
    required this.pcmChunks,
    required this.sampleRateHz,
    required this.channels,
    required this.byteCount,
  });

  final WhiteboardSyncStep step;
  final List<Uint8List> pcmChunks;
  final int sampleRateHz;
  final int channels;
  final int byteCount;
  bool released = false;
  final Completer<StepPlaybackResult> completer =
      Completer<StepPlaybackResult>();
}
