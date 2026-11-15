import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:edu/features/companion_sync/data/protocol/audio_step_frame_codec.dart';
import 'package:edu/features/voice_tutor/data/engines/on_device_engine_impl.dart';
import 'package:edu/features/voice_tutor/data/native/native_runtime_bridge.dart';
import 'package:edu/features/whiteboard/domain/entities/whiteboard_sync_step.dart';
import 'package:edu/features/whiteboard/presentation/controllers/audio_synced_whiteboard_step_controller.dart';
import 'package:edu/features/voice_tutor/data/native/native_runtime_config.dart';
import 'package:edu/features/voice_tutor/data/orchestrator/dynamic_model_orchestrator.dart';
import 'package:edu/features/voice_tutor/data/workers/inference_worker_port.dart';
import 'package:edu/features/voice_tutor/data/workers/multimodal_llm_worker.dart';
import 'package:edu/features/voice_tutor/data/workers/realtime_voice_worker.dart';
import 'package:edu/features/voice_tutor/domain/entities/tutor_engine_event.dart';
import 'package:edu/features/voice_tutor/domain/entities/tutor_prompt.dart';
import 'package:edu/features/whiteboard/domain/entities/student_stylus_event.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/io.dart';

void main() {
  const pairingKey = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  test('host handles companion PCM/stylus/WebP/interrupt and returns synchronized tutor frames', () async {
    final modelWorker = _FakeTutorWorker();
    final vadWorker = _FakeTaskWorker();
    final asrWorker = _FakeTaskWorker();
    final ttsWorker = _FakeTaskWorker();
    final sink = _RecordingPlaybackSink();
    final voice = RealTimeVoiceWorker(
      vadWorker: vadWorker,
      asrWorker: asrWorker,
      ttsWorker: ttsWorker,
      playbackSink: sink,
      preRollFrameCount: 0,
    );
    final modelConfig = NativeRuntimeConfig.gemma4Host(
      modelPath: '/models/gemma-4-e4b.litertlm',
      grammarPath: 'assets/grammar/whiteboard.gbnf',
    );
    final llm = MultimodalLlmWorker(config: modelConfig, worker: modelWorker);
    final orchestrator = DynamicModelOrchestrator(
      warmModels: <WarmModelRole, ManagedModelResource>{
        for (final role in WarmModelRole.values) role: _LifecycleResource(role.name),
      },
      embeddingModel: _EmbeddingResource(),
    );
    final stylusSeen = Completer<StudentStylusEvent>();
    final engine = OnDeviceEngineImpl(
      llmWorker: llm,
      voiceWorker: voice,
      modelOrchestrator: orchestrator,
      onRemoteStylusEvent: (event) {
        if (!stylusSeen.isCompleted) stylusSeen.complete(event);
      },
    );
    final engineDone = Completer<void>();
    final engineSubscription = engine.events.listen((event) {
      if (event is TutorTurnCompleted && !engineDone.isCompleted) engineDone.complete();
    });

    await engine.initialize();
    final port = await engine.startCompanionHost(pairingKey: pairingKey, port: 0);
    final socket = IOWebSocketChannel.connect(
      Uri(scheme: 'ws', host: '127.0.0.1', port: port, path: '/sync'),
      headers: <String, dynamic>{'Authorization': 'Bearer $pairingKey'},
    );
    await socket.ready;

    final inboundFrames = <Object?>[];
    final synchronizedBatch = Completer<void>();
    final socketSubscription = socket.stream.listen((frame) {
      inboundFrames.add(frame);
      if (frame is String) {
        final decoded = jsonDecode(frame);
        if (decoded is Map<String, dynamic> && decoded['type'] == 'audio_end') {
          if (!synchronizedBatch.isCompleted) synchronizedBatch.complete();
        }
      }
    });

    socket.sink.add(jsonEncode(<String, Object?>{
      'type': 'student_stylus_event',
      'event': <String, Object?>{
        'type': 'stylus',
        'pointerId': 8,
        'phase': 'down',
        'x': 0.2,
        'y': 0.4,
        'pressure': 0.6,
        'timestampUs': 900,
      },
    }));
    final stylus = await stylusSeen.future.timeout(const Duration(seconds: 5));
    expect(stylus.pointerId, 8);
    expect(stylus.x, 0.2);

    final webp = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x10, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20,
      0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]);
    socket.sink.add(jsonEncode(<String, Object?>{
      'type': 'board_snapshot',
      'format': 'webp',
      'data': base64Encode(webp),
    }));
    await _eventually(() => engine.latestBoardSnapshot != null);
    expect(engine.latestBoardSnapshot, orderedEquals(webp));

    final pcm = Uint8List.fromList(<int>[0, 1, 2, 3]);
    socket.sink.add(pcm);
    await _eventually(() => vadWorker.lastAudioContext != null);
    expect(vadWorker.lastAudioContext, orderedEquals(pcm));

    socket.sink.add(jsonEncode(<String, Object?>{'type': 'interrupt', 'request_id': 'turn-1'}));
    await _eventually(() => sink.bargeInCount > 0);

    socket.sink.add(jsonEncode(<String, Object?>{
      'type': 'prompt',
      'request_id': 'turn-1',
      'text': 'Explain the board and return a synchronized step.',
      'created_at': DateTime.utc(2026).toIso8601String(),
    }));
    await engineDone.future.timeout(const Duration(seconds: 5));
    await synchronizedBatch.future.timeout(const Duration(seconds: 5));

    final jsonFrames = inboundFrames.whereType<String>().map(jsonDecode).whereType<Map<String, dynamic>>().toList();
    final stepFrame = jsonFrames.firstWhere((frame) => frame['type'] == 'whiteboard_step');
    final rawStep = Map<String, dynamic>.from(
      stepFrame['step'] as Map<String, dynamic>,
    );
    expect(stepFrame['request_id'], 'turn-1');
    expect(WhiteboardSyncStep.fromJson(rawStep).stepId, 29);
    final stepFrameIndex = inboundFrames.indexWhere((frame) =>
        frame is String && (jsonDecode(frame) as Map<String, dynamic>)['type'] == 'whiteboard_step');
    final audioEndIndex = inboundFrames.indexWhere((frame) =>
        frame is String && (jsonDecode(frame) as Map<String, dynamic>)['type'] == 'audio_end');
    final audioFrameIndex = inboundFrames.indexWhere((frame) => frame is Uint8List || frame is List<int>);
    expect(stepFrameIndex, lessThan(audioFrameIndex));
    expect(audioFrameIndex, lessThan(audioEndIndex));
    final audioFrame = inboundFrames
        .where((frame) => frame is Uint8List || frame is List<int>)
        .map((frame) => frame is Uint8List ? frame : Uint8List.fromList(frame as List<int>))
        .single;
    final decodedAudio = AudioStepFrameCodec.decode(audioFrame);
    expect(decodedAudio.stepId, 29);
    expect(decodedAudio.pcmChunk, orderedEquals(Uint8List.fromList(<int>[9, 0, 8, 0])));
    expect(sink.stepIds, contains(29));

    await socketSubscription.cancel();
    await socket.sink.close();
    await engineSubscription.cancel();
    await engine.dispose();
  });
}

Future<void> _eventually(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('Condition did not become true.');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

final class _LifecycleResource implements ManagedModelResource {
  _LifecycleResource(this.modelId);
  @override
  final String modelId;
  bool loaded = false;
  @override
  bool get isLoaded => loaded;
  @override
  Future<void> load() async {
    loaded = true;
  }
  @override
  Future<void> unload() async {
    loaded = false;
  }
}

final class _EmbeddingResource implements EmbeddingModelResource {
  bool loaded = false;
  @override
  String get modelId => 'embedding';
  @override
  bool get isLoaded => loaded;
  @override
  Future<void> load() async {
    loaded = true;
  }
  @override
  Future<void> unload() async {
    loaded = false;
  }
  @override
  Future<Float32List> embed(String document) async => Float32List.fromList(<double>[1, 0, 0]);
}

final class _FakeTutorWorker implements InferenceWorkerPort {
  bool _loaded = false;
  final WhiteboardSyncStep step = WhiteboardSyncStep(
    stepId: 29,
    speechText: 'A synchronized reply.',
    actions: const <WhiteboardAction>[],
  );
  @override
  bool get isInitialized => _loaded;
  @override
  Future<void> initialize() async {
    _loaded = true;
  }
  @override
  Future<void> unload() async {
    _loaded = false;
  }
  @override
  Future<void> dispose() async {
    _loaded = false;
  }

  @override
  Stream<TutorEngineEvent> runTutorPrompt(
    TutorPrompt prompt, {
    Uint8List? audioContext,
    Uint8List? webpSnapshot,
  }) async* {
    yield TutorWhiteboardStepEvent(requestId: prompt.requestId, step: step);
    yield TutorTurnCompleted(requestId: prompt.requestId);
  }

  @override
  Stream<NativeRuntimeEvent> runNativeTask({
    required String requestId,
    required String task,
    String prompt = '',
    Uint8List? audioContext,
    int? stepId,
  }) async* {}

  @override
  Future<void> interrupt(String requestId) async {}
}

final class _FakeTaskWorker implements InferenceWorkerPort {
  bool _loaded = false;
  Uint8List? lastAudioContext;
  @override
  bool get isInitialized => _loaded;
  @override
  Future<void> initialize() async {
    _loaded = true;
  }
  @override
  Future<void> unload() async {
    _loaded = false;
  }
  @override
  Future<void> dispose() async {
    _loaded = false;
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
    if (task.startsWith('kokoro')) {
      yield NativeRuntimeEvent(
        requestId: requestId,
        type: 'audio_chunk',
        pcmS16le: Uint8List.fromList(<int>[9, 0, 8, 0]),
        stepId: stepId,
      );
      yield NativeRuntimeEvent(requestId: requestId, type: 'completed');
    }
  }

  @override
  Stream<TutorEngineEvent> runTutorPrompt(
    TutorPrompt prompt, {
    Uint8List? audioContext,
    Uint8List? webpSnapshot,
  }) async* {}

  @override
  Future<void> interrupt(String requestId) async {}
}

final class _RecordingPlaybackSink implements TutorStepPlaybackSink {
  final List<int> stepIds = <int>[];
  int bargeInCount = 0;

  @override
  Future<StepPlaybackResult> enqueueStep(WhiteboardSyncStep step, List<Uint8List> pcmChunks) async {
    stepIds.add(step.stepId);
    return StepPlaybackResult.completed;
  }

  @override
  Future<void> bargeIn() async {
    bargeInCount++;
  }
}
