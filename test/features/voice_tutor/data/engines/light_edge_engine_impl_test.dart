import 'dart:typed_data';

import 'package:edu/features/voice_tutor/data/engines/light_edge_engine_impl.dart';
import 'package:edu/features/voice_tutor/data/native/native_runtime_bridge.dart';
import 'package:edu/features/voice_tutor/data/native/native_runtime_config.dart';
import 'package:edu/features/voice_tutor/data/orchestrator/dynamic_model_orchestrator.dart';
import 'package:edu/features/voice_tutor/data/orchestrator/native_model_resources.dart';
import 'package:edu/features/voice_tutor/data/workers/inference_worker_port.dart';
import 'package:edu/features/voice_tutor/data/workers/multimodal_llm_worker.dart';
import 'package:edu/features/voice_tutor/data/workers/realtime_voice_worker.dart';
import 'package:edu/features/voice_tutor/domain/entities/tutor_engine_event.dart';
import 'package:edu/features/voice_tutor/domain/entities/tutor_prompt.dart';
import 'package:edu/features/whiteboard/domain/entities/whiteboard_sync_step.dart';
import 'package:edu/features/whiteboard/presentation/controllers/audio_synced_whiteboard_step_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Light Edge enforces Gemma 4 E2B with q4_0 KV cache and reduced context', () async {
    final config = NativeRuntimeConfig.gemma4LightEdge(
      modelPath: '/models/gemma-4-e2b-q4_0.litertlm',
      grammarPath: 'assets/grammar/whiteboard.gbnf',
    );
    final llmWorker = MultimodalLlmWorker(
      config: config,
      worker: _FakeWorker(),
    );
    final voiceWorker = _voiceWorker();
    final orchestrator = createTutorModelOrchestrator(
      llmWorker: llmWorker,
      voiceWorker: voiceWorker,
      embeddingModel: NativeEmbeddingModelResource(
        config: _embeddingConfig(),
        workerFactory: _FakeWorker.new,
      ),
    );
    final engine = LightEdgeEngineImpl(
      llmWorker: llmWorker,
      voiceWorker: voiceWorker,
      modelOrchestrator: orchestrator,
      modelConfig: config,
    );

    expect(engine.modelConfig.modelId, 'gemma-4-e2b-q4_0');
    expect(engine.modelConfig.kvCacheQuantization, KvCacheQuantization.q4_0);
    expect(engine.modelConfig.contextTokens, lessThan(8192));
    expect(engine.modelConfig.backend, NativeModelBackend.liteRtLm);
    await engine.initialize();
    await engine.dispose();
  });

  test('Light Edge rejects a host-sized E4B profile', () {
    final hostConfig = NativeRuntimeConfig.gemma4Host(
      modelPath: '/models/gemma-e4b.litertlm',
      grammarPath: 'assets/grammar/whiteboard.gbnf',
    );
    expect(
      () => LightEdgeEngineImpl(
        llmWorker: MultimodalLlmWorker(config: hostConfig, worker: _FakeWorker()),
        voiceWorker: _voiceWorker(),
        modelOrchestrator: _emptyOrchestratorForConstruction(),
        modelConfig: hostConfig,
      ),
      throwsArgumentError,
    );
  });
}

RealTimeVoiceWorker _voiceWorker() => RealTimeVoiceWorker(
      vadWorker: _FakeWorker(),
      asrWorker: _FakeWorker(),
      ttsWorker: _FakeWorker(),
      playbackSink: _FakePlaybackSink(),
    );

NativeRuntimeConfig _embeddingConfig() => NativeRuntimeConfig(
      modelId: 'multilingual-e5-small',
      modelPath: '/models/multilingual-e5-small.onnx',
      backend: NativeModelBackend.llamaCpp,
      quantization: 'Q8_0',
      accelerator: NativeAccelerator.cpu,
      contextTokens: 512,
      grammarPath: 'assets/grammar/whiteboard.gbnf',
    );

DynamicModelOrchestrator _emptyOrchestratorForConstruction() {
  // Construction rejects the profile before the orchestrator is used.
  return createTutorModelOrchestrator(
    llmWorker: MultimodalLlmWorker(
      config: NativeRuntimeConfig.gemma4LightEdge(
        modelPath: '/models/edge.litertlm',
        grammarPath: 'assets/grammar/whiteboard.gbnf',
      ),
      worker: _FakeWorker(),
    ),
    voiceWorker: _voiceWorker(),
    embeddingModel: NativeEmbeddingModelResource(
      config: _embeddingConfig(),
      workerFactory: _FakeWorker.new,
    ),
  );
}

class _FakeWorker implements InferenceWorkerPort {
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
  }) async* {}

  @override
  Stream<TutorEngineEvent> runTutorPrompt(
    TutorPrompt prompt, {
    Uint8List? audioContext,
    Uint8List? webpSnapshot,
  }) async* {}

  @override
  Future<void> interrupt(String requestId) async {}

  @override
  Future<void> unload() async {
    _initialized = false;
  }

  @override
  Future<void> dispose() async {
    _initialized = false;
  }
}

class _FakePlaybackSink implements TutorStepPlaybackSink {
  @override
  Future<StepPlaybackResult> enqueueStep(
    WhiteboardSyncStep step,
    List<Uint8List> pcmChunks,
  ) async =>
      StepPlaybackResult.completed;

  @override
  Future<void> bargeIn() async {}
}
