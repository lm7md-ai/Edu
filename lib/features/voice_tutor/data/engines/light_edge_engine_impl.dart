import 'dart:async';
import 'dart:typed_data';

import 'package:edu/features/voice_tutor/data/engines/local_tutor_engine_base.dart';
import 'package:edu/features/voice_tutor/data/native/native_runtime_config.dart';
import 'package:edu/features/voice_tutor/data/orchestrator/dynamic_model_orchestrator.dart';
import 'package:edu/features/voice_tutor/data/workers/multimodal_llm_worker.dart';
import 'package:edu/features/voice_tutor/data/workers/realtime_voice_worker.dart';
import 'package:edu/features/whiteboard/domain/entities/student_stylus_event.dart';

/// Standalone tablet fallback using Gemma 4 E2B and q4_0 KV-cache settings.
/// The selected runtime profile is required to be the RAM-bounded Light Edge
/// configuration rather than a host E4B profile.
final class LightEdgeEngineImpl extends LocalTutorEngineBase {
  LightEdgeEngineImpl({
    required MultimodalLlmWorker llmWorker,
    required RealTimeVoiceWorker voiceWorker,
    required DynamicModelOrchestrator modelOrchestrator,
    required NativeRuntimeConfig modelConfig,
    Stream<Uint8List> Function()? microphonePcmStream,
    Future<Uint8List?> Function()? snapshotProvider,
    FutureOr<void> Function(StudentStylusEvent event)? onRemoteStylusEvent,
    Future<String> Function(String question)? curriculumContextProvider,
  })  : modelConfig = _validateLightEdgeConfig(modelConfig),
        super(
          llmWorker: llmWorker,
          voiceWorker: voiceWorker,
          modelOrchestrator: modelOrchestrator,
          microphonePcmStream: microphonePcmStream,
          snapshotProvider: snapshotProvider,
          onRemoteStylusEvent: onRemoteStylusEvent,
          curriculumContextProvider: curriculumContextProvider,
        ) {
    if (llmWorker.modelConfig.modelId != modelConfig.modelId ||
        llmWorker.modelConfig.backend != modelConfig.backend ||
        llmWorker.modelConfig.quantization != modelConfig.quantization ||
        llmWorker.modelConfig.kvCacheQuantization != modelConfig.kvCacheQuantization ||
        llmWorker.modelConfig.contextTokens != modelConfig.contextTokens) {
      throw ArgumentError('Light Edge model profile must match the Gemma worker configuration.');
    }
  }

  final NativeRuntimeConfig modelConfig;

  static NativeRuntimeConfig _validateLightEdgeConfig(NativeRuntimeConfig config) {
    if (config.modelId != 'gemma-4-e2b-q4_0' ||
        config.backend != NativeModelBackend.liteRtLm ||
        config.quantization != 'q4_0' ||
        config.kvCacheQuantization != KvCacheQuantization.q4_0 ||
        config.accelerator != NativeAccelerator.automatic ||
        config.contextTokens > 4096) {
      throw ArgumentError.value(
        config,
        'modelConfig',
        'Light Edge requires Gemma 4 E2B, q4_0 KV cache, and a reduced context window.',
      );
    }
    return config;
  }
}
