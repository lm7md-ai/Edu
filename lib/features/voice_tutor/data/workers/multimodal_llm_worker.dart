import 'dart:typed_data';

import 'package:edu/features/voice_tutor/data/native/native_runtime_config.dart';
import 'package:edu/features/voice_tutor/data/workers/inference_worker_port.dart';
import 'package:edu/features/voice_tutor/data/workers/native_model_isolate_worker.dart';
import 'package:edu/features/voice_tutor/domain/entities/tutor_engine_event.dart';
import 'package:edu/features/voice_tutor/domain/entities/tutor_prompt.dart';

/// Dedicated Gemma multimodal inference isolate with incremental, validated
/// JSON-to-whiteboard-step parsing performed inside that isolate.
final class MultimodalLlmWorker {
  MultimodalLlmWorker({
    required NativeRuntimeConfig config,
    NativeWorkerDriver driver = NativeWorkerDriver.ffi,
    InferenceWorkerPort? worker,
  })  : modelConfig = config,
        _worker = worker ?? NativeModelIsolateWorker(config: config, driver: driver);

  final NativeRuntimeConfig modelConfig;
  final InferenceWorkerPort _worker;

  InferenceWorkerPort get workerPort => _worker;

  Future<void> initialize() => _worker.initialize();

  Stream<TutorEngineEvent> generate(
    TutorPrompt prompt, {
    Uint8List? audioContext,
    Uint8List? webpSnapshot,
  }) =>
      _worker.runTutorPrompt(
        prompt,
        audioContext: audioContext,
        webpSnapshot: webpSnapshot,
      );

  Future<void> interrupt(String requestId) => _worker.interrupt(requestId);

  Future<void> unload() => _worker.unload();

  Future<void> dispose() => _worker.dispose();
}
