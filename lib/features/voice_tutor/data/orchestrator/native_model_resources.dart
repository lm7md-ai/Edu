import 'dart:typed_data';

import 'package:edu/features/voice_tutor/data/native/native_runtime_config.dart';
import 'package:edu/features/voice_tutor/data/orchestrator/dynamic_model_orchestrator.dart';
import 'package:edu/features/voice_tutor/data/workers/inference_worker_port.dart';
import 'package:edu/features/voice_tutor/data/workers/multimodal_llm_worker.dart';
import 'package:edu/features/voice_tutor/data/workers/native_model_isolate_worker.dart';
import 'package:edu/features/voice_tutor/data/workers/realtime_voice_worker.dart';

/// A native model resource whose actual session and tensors are owned by a
/// persistent inference isolate.
class IsolateManagedModelResource implements ManagedModelResource {
  IsolateManagedModelResource({
    required this.config,
    this.driver = NativeWorkerDriver.ffi,
    InferenceWorkerPort Function()? workerFactory,
  }) : _workerFactory = workerFactory ??
            (() => NativeModelIsolateWorker(config: config, driver: driver));

  final NativeRuntimeConfig config;
  final NativeWorkerDriver driver;
  final InferenceWorkerPort Function() _workerFactory;
  InferenceWorkerPort? _worker;

  @override
  String get modelId => config.modelId;

  @override
  bool get isLoaded => _worker?.isInitialized ?? false;

  @override
  Future<void> load() async {
    if (isLoaded) return;
    final worker = _workerFactory();
    try {
      await worker.initialize();
      _worker = worker;
    } on Object {
      await worker.dispose();
      rethrow;
    }
  }

  @override
  Future<void> unload() async {
    final worker = _worker;
    _worker = null;
    await worker?.dispose();
  }

  InferenceWorkerPort get worker =>
      _worker ?? (throw StateError('Model $modelId is not loaded.'));
}

/// Lazy multilingual embedding resource used only during document indexing.
final class NativeEmbeddingModelResource extends IsolateManagedModelResource
    implements EmbeddingModelResource {
  NativeEmbeddingModelResource({
    required super.config,
    super.driver,
    super.workerFactory,
  });

  int _nextEmbeddingRequest = 1;

  @override
  Future<Float32List> embed(String document) async {
    if (document.trim().isEmpty) throw ArgumentError.value(document, 'document');
    final output = <Float32List>[];
    final requestId = 'embedding-${_nextEmbeddingRequest++}';
    await for (final event in worker.runNativeTask(
      requestId: requestId,
      task: 'multilingual_text_embedding',
      prompt: document,
    )) {
      if (event.type == 'embedding' && event.embedding != null) {
        output.add(event.embedding!);
      } else if (event.type == 'failed') {
        throw StateError(event.error ?? 'Embedding inference failed.');
      }
    }
    if (output.length != 1) {
      throw StateError('Embedding model returned ${output.length} vectors for one document.');
    }
    return output.single;
  }
}

/// Creates one session lifecycle for the four always-warm models and one
/// strictly lazy embedding model, sharing the exact workers used by engines.
DynamicModelOrchestrator createTutorModelOrchestrator({
  required MultimodalLlmWorker llmWorker,
  required RealTimeVoiceWorker voiceWorker,
  required NativeEmbeddingModelResource embeddingModel,
}) =>
    DynamicModelOrchestrator(
      warmModels: <WarmModelRole, ManagedModelResource>{
        WarmModelRole.sileroVad: WorkerManagedModelResource(
          modelId: 'silero-vad',
          worker: voiceWorker.vadWorker,
        ),
        WarmModelRole.asr: WorkerManagedModelResource(
          modelId: 'moonshine-whisper-asr',
          worker: voiceWorker.asrWorker,
        ),
        WarmModelRole.kokoroTts: WorkerManagedModelResource(
          modelId: 'kokoro-82m-tts',
          worker: voiceWorker.ttsWorker,
        ),
        WarmModelRole.primaryGemma: WorkerManagedModelResource(
          modelId: llmWorker.modelConfig.modelId,
          worker: llmWorker.workerPort,
        ),
      },
      embeddingModel: embeddingModel,
    );

final class WorkerManagedModelResource implements ManagedModelResource {
  const WorkerManagedModelResource({required this.modelId, required this.worker});

  @override
  final String modelId;
  final InferenceWorkerPort worker;

  @override
  bool get isLoaded => worker.isInitialized;

  @override
  Future<void> load() => worker.initialize();

  @override
  Future<void> unload() => worker.unload();
}
