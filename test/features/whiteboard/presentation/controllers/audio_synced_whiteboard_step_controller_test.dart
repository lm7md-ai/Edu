import 'dart:async';
import 'dart:typed_data';

import 'package:edu/features/whiteboard/domain/entities/whiteboard_sync_step.dart';
import 'package:edu/features/whiteboard/presentation/controllers/audio_synced_whiteboard_step_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('visual fraction follows played output frames, not elapsed time',
      (WidgetTester tester) async {
    final clock = _FakeAudioClock();
    final scheduler = _FakePcmStepScheduler(clock);
    final controller = AudioSyncedWhiteboardStepController(
      vsync: const TestVSync(),
      scheduler: scheduler,
      minimumSchedulingLead: Duration.zero,
    );
    final step = _stepWithActions(1, actionCount: 4);
    final completion = controller.enqueueStep(
      step: step,
      pcmChunks: <Uint8List>[Uint8List.fromList(<int>[0, 0])],
      sampleRateHz: 16000,
      channels: 1,
    );

    await tester.pump();
    expect(scheduler.windows, hasLength(1));
    final window = scheduler.windows.single;

    await tester.pump(const Duration(seconds: 5));
    expect(controller.progress.value, 0);

    clock.playedFramePosition = window.startFrame + 125;
    await tester.pump(const Duration(milliseconds: 16));
    expect(controller.progress.value, closeTo(0.125, 0.001));
    expect(controller.activeActionIndex, 0);
    expect(controller.actionProgress(0), closeTo(0.5, 0.001));
    expect(controller.isActionComplete(0), isFalse);

    clock.playedFramePosition = window.startFrame + 375;
    await tester.pump(const Duration(milliseconds: 16));
    expect(controller.progress.value, closeTo(0.375, 0.001));
    expect(controller.activeActionIndex, 1);
    expect(controller.actionProgress(1), closeTo(0.5, 0.001));
    expect(controller.isActionComplete(0), isTrue);
    expect(controller.isActionComplete(1), isFalse);

    clock.playedFramePosition = window.startFrame + 625;
    await tester.pump(const Duration(milliseconds: 16));
    expect(controller.progress.value, closeTo(0.625, 0.001));
    expect(controller.activeActionIndex, 2);
    expect(controller.actionProgress(2), closeTo(0.5, 0.001));

    clock.playedFramePosition = window.endFrame;
    await tester.pump(const Duration(milliseconds: 16));
    expect(await completion, StepPlaybackResult.completed);
    expect(controller.activeStep, isNull);
    controller.dispose();
  });

  testWidgets('queued tutor steps are scheduled in deterministic FIFO order',
      (WidgetTester tester) async {
    final clock = _FakeAudioClock();
    final scheduler = _FakePcmStepScheduler(clock);
    final controller = AudioSyncedWhiteboardStepController(
      vsync: const TestVSync(),
      scheduler: scheduler,
      minimumSchedulingLead: Duration.zero,
    );
    final audio = <Uint8List>[Uint8List.fromList(<int>[0, 0])];
    final first = controller.enqueueStep(
      step: _step(21),
      pcmChunks: audio,
      sampleRateHz: 16000,
      channels: 1,
    );
    final second = controller.enqueueStep(
      step: _step(22),
      pcmChunks: audio,
      sampleRateHz: 16000,
      channels: 1,
    );

    await tester.pump();
    expect(scheduler.stepIds, <int>[21]);
    clock.playedFramePosition = scheduler.windows.first.endFrame;
    await tester.pump(const Duration(milliseconds: 16));
    expect(await first, StepPlaybackResult.completed);
    expect(scheduler.stepIds, <int>[21, 22]);
    expect(controller.activeStep?.stepId, 22);

    final secondWindow = scheduler.windows.last;
    clock.playedFramePosition = secondWindow.endFrame;
    await tester.pump(const Duration(milliseconds: 16));
    expect(await second, StepPlaybackResult.completed);
    controller.dispose();
  });

  testWidgets('barge-in immediately cancels active and queued steps',
      (WidgetTester tester) async {
    final clock = _FakeAudioClock();
    final scheduler = _FakePcmStepScheduler(
      clock,
      flushGate: Completer<void>(),
    );
    final controller = AudioSyncedWhiteboardStepController(
      vsync: const TestVSync(),
      scheduler: scheduler,
      minimumSchedulingLead: Duration.zero,
    );
    final audio = <Uint8List>[Uint8List.fromList(<int>[0, 0])];
    final first = controller.enqueueStep(
      step: _step(10),
      pcmChunks: audio,
      sampleRateHz: 16000,
      channels: 1,
    );

    await tester.pump();
    expect(controller.activeStep?.stepId, 10);
    expect(scheduler.windows, hasLength(1));

    final second = controller.enqueueStep(
      step: _step(11),
      pcmChunks: audio,
      sampleRateHz: 16000,
      channels: 1,
    );
    expect(controller.queuedStepCount, 1);

    final flush = controller.bargeIn();
    expect(controller.activeStep, isNull);
    expect(controller.queuedStepCount, 0);
    expect(scheduler.flushCount, 1);

    // The queued/active completers settle before native flush finishes.
    expect(await first, StepPlaybackResult.cancelled);
    expect(await second, StepPlaybackResult.cancelled);
    expect(scheduler.flushGate!.isCompleted, isFalse);
    expect(controller.progress.value, 0);

    scheduler.flushGate!.complete();
    await flush;
    controller.dispose();
  });
}

WhiteboardSyncStep _step(int stepId) => _stepWithActions(stepId);

WhiteboardSyncStep _stepWithActions(int stepId, {int actionCount = 1}) =>
    WhiteboardSyncStep(
      stepId: stepId,
      speechText: 'A synchronized step.',
      actions: <WhiteboardAction>[
        for (var index = 0; index < actionCount; index++)
          WhiteboardAction(
            operation: WhiteboardOperation.drawNode,
            targetId: 'node-$stepId-$index',
            x: 0.2 + index * 0.2,
            y: 0.5,
            content: 'Step $stepId action $index',
          ),
      ],
    );

final class _FakeAudioClock implements AudioPlaybackClock {
  @override
  int playedFramePosition = 0;

  @override
  int get sampleRateHz => 1000;
}

final class _FakePcmStepScheduler implements PcmStepScheduler {
  _FakePcmStepScheduler(this.clock, {this.flushGate});

  @override
  final _FakeAudioClock clock;

  final List<AudioPlaybackWindow> windows = <AudioPlaybackWindow>[];
  final List<int> stepIds = <int>[];
  final Completer<void>? flushGate;
  int flushCount = 0;

  @override
  Future<AudioPlaybackWindow> scheduleStep({
    required int stepId,
    required List<Uint8List> pcmChunks,
    required int sampleRateHz,
    required int channels,
    required int notBeforeFrame,
  }) async {
    final window = AudioPlaybackWindow(
      startFrame: notBeforeFrame,
      endFrame: notBeforeFrame + 1000,
    );
    windows.add(window);
    stepIds.add(stepId);
    return window;
  }

  @override
  Future<void> flush() async {
    flushCount++;
    await flushGate?.future;
  }
}
