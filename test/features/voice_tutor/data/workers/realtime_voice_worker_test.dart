import 'dart:async';
import 'dart:typed_data';

import 'package:edu/features/voice_tutor/data/native/native_runtime_bridge.dart';
import 'package:edu/features/voice_tutor/data/workers/inference_worker_port.dart';
import 'package:edu/features/voice_tutor/data/workers/realtime_voice_worker.dart';
import 'package:edu/features/voice_tutor/domain/entities/tutor_engine_event.dart';
import 'package:edu/features/voice_tutor/domain/entities/tutor_prompt.dart';
import 'package:edu/features/whiteboard/domain/entities/whiteboard_sync_step.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RealTimeVoiceWorker VAD barge-in', () {
    test('speech flushes every queued whiteboard step and notifies listeners once', () async {
      final vad = _FakeWorker(<NativeRuntimeEvent>[
        const NativeRuntimeEvent(requestId: 'vad', type: 'vad_speech'),
      ]);
      final sink = _QueuePlaybackSink();
      var callbackCount = 0;
      var listenerCount = 0;
      final voice = _voice(vad: vad, sink: sink, onBargeIn: () => callbackCount++);
      voice.addBargeInListener(() => listenerCount++);
      final first = sink.enqueueStep(_step(4), <Uint8List>[_pcm(2)]);
      final second = sink.enqueueStep(_step(5), <Uint8List>[_pcm(2)]);

      await voice.processMicrophoneFrame(
        _pcm(4),
        onTranscript: (_) {},
      );

      expect(sink.bargeInCount, 1);
      expect(callbackCount, 1);
      expect(listenerCount, 1);
      expect(await first, StepPlaybackResult.cancelled);
      expect(await second, StepPlaybackResult.cancelled);
      expect(sink.pendingCount, 0);
      await voice.dispose();
    });

    test('silence does not flush queued audio or produce a false barge-in', () async {
      final sink = _QueuePlaybackSink();
      final voice = _voice(
        vad: _FakeWorker(<NativeRuntimeEvent>[
          const NativeRuntimeEvent(requestId: 'vad', type: 'vad_silence'),
        ]),
        sink: sink,
      );
      final playback = sink.enqueueStep(_step(7), <Uint8List>[_pcm(2)]);

      await voice.processMicrophoneFrame(_pcm(4), onTranscript: (_) {});

      expect(sink.bargeInCount, 0);
      expect(sink.pendingCount, 1);
      sink.completePending(StepPlaybackResult.completed);
      expect(await playback, StepPlaybackResult.completed);
      await voice.dispose();
    });

    test('cancels in-flight Kokoro work before it can enqueue stale audio', () async {
      final tts = _BlockingTtsWorker();
      final sink = _QueuePlaybackSink();
      final voice = _voice(
        vad: _FakeWorker(<NativeRuntimeEvent>[
          const NativeRuntimeEvent(requestId: 'vad', type: 'vad_speech'),
        ]),
        sink: sink,
        tts: tts,
      );
      final synthesis = voice.synthesizeStep(_step(41));
      await tts.started.future;

      await voice.processMicrophoneFrame(_pcm(4), onTranscript: (_) {});

      await expectLater(synthesis, throwsA(isA<VoiceStepCancelled>()));
      expect(tts.interruptedRequests, <String>['tts-41-1']);
      expect(sink.bargeInCount, 1);
      expect(sink.pendingCount, 0);
      expect(sink.lastStepId, isNull);
      await voice.dispose();
    });

    test('a new step can be queued after a barge-in flush', () async {
      final sink = _QueuePlaybackSink();
      final voice = _voice(
        vad: _FakeWorker(<NativeRuntimeEvent>[
          const NativeRuntimeEvent(requestId: 'vad', type: 'vad_speech'),
        ]),
        sink: sink,
      );
      final stale = sink.enqueueStep(_step(1), <Uint8List>[_pcm(2)]);
      await voice.processMicrophoneFrame(_pcm(4), onTranscript: (_) {});
      expect(await stale, StepPlaybackResult.cancelled);

      final next = sink.enqueueStep(_step(2), <Uint8List>[_pcm(2)]);
      expect(sink.pendingCount, 1);
      sink.completePending(StepPlaybackResult.completed);
      expect(await next, StepPlaybackResult.completed);
      await voice.dispose();
    });
  });

  test('VAD silence closes an utterance and transcribes Arabic through ASR', () async {
    final vad = _FakeWorker(<NativeRuntimeEvent>[
      const NativeRuntimeEvent(requestId: 'vad', type: 'vad_speech'),
      const NativeRuntimeEvent(requestId: 'vad', type: 'vad_silence'),
    ]);
    final asr = _FakeWorker(<NativeRuntimeEvent>[
      NativeRuntimeEvent(requestId: 'asr', type: 'transcript', text: '  مرحباً  '),
    ]);
    final voice = _voice(vad: vad, sink: _QueuePlaybackSink(), asr: asr, preRoll: 0);
    final transcripts = <String>[];

    await voice.processMicrophoneFrame(_pcm(2), onTranscript: transcripts.add);
    await voice.processMicrophoneFrame(_pcm(2), onTranscript: transcripts.add);

    expect(transcripts, <String>['مرحباً']);
    expect(asr.lastTask, 'moonshine_whisper_ar_en_asr');
    expect(asr.lastAudioContext, hasLength(4));
    expect(voice.lastRecognizedAudioContext, hasLength(4));
    await voice.dispose();
  });

  test('Kokoro PCM is scheduled with its originating whiteboard step id', () async {
    final tts = _FakeWorker(<NativeRuntimeEvent>[
      NativeRuntimeEvent(
        requestId: 'tts',
        type: 'audio_chunk',
        pcmS16le: _pcm(4),
      ),
      const NativeRuntimeEvent(requestId: 'tts', type: 'completed'),
    ]);
    final sink = _QueuePlaybackSink();
    final voice = _voice(vad: _FakeWorker(const <NativeRuntimeEvent>[]), sink: sink, tts: tts);
    await voice.initialize();

    final synthesized = await voice.synthesizeStep(_step(23));

    expect(tts.lastTask, 'kokoro_82m_tts_s16le_16khz');
    expect(tts.lastStepId, 23);
    expect(sink.lastStepId, 23);
    expect(sink.lastPcmChunks.single.toList(), _pcm(4).toList());
    expect(synthesized.step.stepId, 23);
    await voice.bargeIn('test-cancel');
    expect(await synthesized.playback, StepPlaybackResult.cancelled);
    await voice.dispose();
  });

  test('enforces an utterance memory limit and rejects malformed PCM', () async {
    final voice = RealTimeVoiceWorker(
      vadWorker: _FakeWorker(<NativeRuntimeEvent>[
        const NativeRuntimeEvent(requestId: 'vad', type: 'vad_speech'),
        const NativeRuntimeEvent(requestId: 'vad', type: 'vad_speech'),
      ]),
      asrWorker: _FakeWorker(const <NativeRuntimeEvent>[]),
      ttsWorker: _FakeWorker(const <NativeRuntimeEvent>[]),
      playbackSink: _QueuePlaybackSink(),
      maxUtteranceBytes: 4,
      preRollFrameCount: 0,
    );

    await voice.processMicrophoneFrame(_pcm(2), onTranscript: (_) {});
    await expectLater(
      voice.processMicrophoneFrame(_pcm(4), onTranscript: (_) {}),
      throwsStateError,
    );
    await voice.dispose();
  });

  test('rejects malformed PCM frames before VAD inference', () async {
    final vad = _FakeWorker(const <NativeRuntimeEvent>[]);
    final voice = _voice(vad: vad, sink: _QueuePlaybackSink());

    await expectLater(
      voice.processMicrophoneFrame(Uint8List.fromList(<int>[0, 1, 2]), onTranscript: (_) {}),
      throwsFormatException,
    );
    expect(vad.lastTask, isNull);
    await voice.dispose();
  });

  test('bounds accumulated Kokoro PCM memory per step', () async {
    final voice = RealTimeVoiceWorker(
      vadWorker: _FakeWorker(const <NativeRuntimeEvent>[]),
      asrWorker: _FakeWorker(const <NativeRuntimeEvent>[]),
      ttsWorker: _FakeWorker(<NativeRuntimeEvent>[
        NativeRuntimeEvent(requestId: 'tts', type: 'audio_chunk', pcmS16le: _pcm(4)),
        NativeRuntimeEvent(requestId: 'tts', type: 'audio_chunk', pcmS16le: _pcm(2)),
      ]),
      playbackSink: _QueuePlaybackSink(),
      maxPcmBytesPerStep: 4,
    );

    await expectLater(voice.synthesizeStep(_step(9)), throwsStateError);
    await voice.dispose();
  });
}

RealTimeVoiceWorker _voice({
  required InferenceWorkerPort vad,
  required TutorStepPlaybackSink sink,
  InferenceWorkerPort? asr,
  InferenceWorkerPort? tts,
  int preRoll = 0,
  void Function()? onBargeIn,
}) =>
    RealTimeVoiceWorker(
      vadWorker: vad,
      asrWorker: asr ?? _FakeWorker(const <NativeRuntimeEvent>[]),
      ttsWorker: tts ?? _FakeWorker(const <NativeRuntimeEvent>[]),
      playbackSink: sink,
      preRollFrameCount: preRoll,
      onBargeIn: onBargeIn,
    );

WhiteboardSyncStep _step(int id) => WhiteboardSyncStep(
      stepId: id,
      speechText: 'Tutor step $id',
      actions: const <WhiteboardAction>[],
    );

Uint8List _pcm(int length) => Uint8List.fromList(List<int>.generate(length, (index) => index));

class _FakeWorker implements InferenceWorkerPort {
  _FakeWorker(this._events);

  final List<NativeRuntimeEvent> _events;
  Uint8List? lastAudioContext;
  int? lastStepId;
  String? lastTask;
  final List<String> interruptedRequests = <String>[];
  bool _initialized = false;

  @override
  bool get isInitialized => _initialized;

  @override
  Future<void> initialize() async {
    _initialized = true;
  }

  @override
  Stream<NativeRuntimeEvent> runNativeTask({
    required String requestId,
    required String task,
    String prompt = '',
    Uint8List? audioContext,
    int? stepId,
  }) async* {
    lastAudioContext = audioContext;
    lastStepId = stepId;
    lastTask = task;
    while (_events.isNotEmpty) {
      yield _events.removeAt(0);
    }
  }

  @override
  Stream<TutorEngineEvent> runTutorPrompt(
    TutorPrompt prompt, {
    Uint8List? audioContext,
    Uint8List? webpSnapshot,
  }) async* {}

  @override
  Future<void> interrupt(String requestId) async {
    interruptedRequests.add(requestId);
  }

  @override
  Future<void> unload() async {
    _initialized = false;
  }

  @override
  Future<void> dispose() async {
    _initialized = false;
  }
}

class _BlockingTtsWorker extends _FakeWorker {
  _BlockingTtsWorker() : super(const <NativeRuntimeEvent>[]);

  final Completer<void> started = Completer<void>();
  final Completer<void> _cancelled = Completer<void>();

  @override
  Stream<NativeRuntimeEvent> runNativeTask({
    required String requestId,
    required String task,
    String prompt = '',
    Uint8List? audioContext,
    int? stepId,
  }) async* {
    lastTask = task;
    lastStepId = stepId;
    if (!started.isCompleted) started.complete();
    yield NativeRuntimeEvent(
      requestId: requestId,
      type: 'audio_chunk',
      pcmS16le: _pcm(4),
    );
    await _cancelled.future;
    yield NativeRuntimeEvent(requestId: requestId, type: 'completed');
  }

  @override
  Future<void> interrupt(String requestId) async {
    interruptedRequests.add(requestId);
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

class _QueuePlaybackSink implements TutorStepPlaybackSink {
  int bargeInCount = 0;
  int? lastStepId;
  List<Uint8List> lastPcmChunks = const <Uint8List>[];
  final List<Completer<StepPlaybackResult>> _queued = <Completer<StepPlaybackResult>>[];

  int get pendingCount => _queued.where((item) => !item.isCompleted).length;

  @override
  Future<StepPlaybackResult> enqueueStep(
    WhiteboardSyncStep step,
    List<Uint8List> pcmChunks,
  ) {
    lastStepId = step.stepId;
    lastPcmChunks = pcmChunks;
    final completer = Completer<StepPlaybackResult>();
    _queued.add(completer);
    return completer.future;
  }

  void completePending(StepPlaybackResult result) {
    for (final queued in _queued) {
      if (!queued.isCompleted) queued.complete(result);
    }
    _queued.clear();
  }

  @override
  Future<void> bargeIn() async {
    bargeInCount++;
    completePending(StepPlaybackResult.cancelled);
  }
}
