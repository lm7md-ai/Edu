import 'dart:async';
import 'dart:typed_data';

import 'package:edu/core/execution/execution_mode.dart';
import 'package:edu/features/companion_sync/data/engines/lan_companion_engine_impl.dart';
import 'package:edu/features/companion_sync/data/services/p2p_lan_database_sync_service.dart';
import 'package:edu/features/companion_sync/domain/entities/pairing_credentials.dart';
import 'package:edu/features/rag_notes/data/curriculum_rag_service.dart';
import 'package:edu/features/voice_tutor/data/engines/light_edge_engine_impl.dart';
import 'package:edu/features/voice_tutor/data/engines/on_device_engine_impl.dart';
import 'package:edu/features/voice_tutor/data/native/native_runtime_config.dart';
import 'package:edu/features/voice_tutor/data/orchestrator/native_model_resources.dart';
import 'package:edu/features/voice_tutor/data/workers/multimodal_llm_worker.dart';
import 'package:edu/features/voice_tutor/data/workers/native_model_isolate_worker.dart';
import 'package:edu/features/voice_tutor/data/workers/realtime_voice_worker.dart';
import 'package:edu/features/voice_tutor/domain/repositories/tutor_engine_repository.dart';
import 'package:edu/features/whiteboard/presentation/controllers/whiteboard_canvas_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Filesystem paths are resolved by the app's model installer and supplied as
/// an override; model weights are not bundled in the source repository.
final class TutorModelPaths {
  const TutorModelPaths({
    required this.gemma4E4b,
    required this.gemma4E2b,
    required this.sileroVad,
    required this.moonshineWhisperAsr,
    required this.kokoro82m,
    required this.multilingualEmbedding,
    required this.grammar,
    this.gemma4E4bGgufFallback,
  });

  final String gemma4E4b;
  final String gemma4E2b;
  final String sileroVad;
  final String moonshineWhisperAsr;
  final String kokoro82m;
  final String multilingualEmbedding;
  final String grammar;
  final String? gemma4E4bGgufFallback;
}

/// Platform-owned capture, playback, model paths and optional pairing state.
/// The UI overrides this provider after it has created the hardware audio
/// scheduler and resolved downloaded model locations.
final class TutorEngineRuntimeDependencies {
  const TutorEngineRuntimeDependencies({
    required this.modelPaths,
    required this.workerDriver,
    required this.playbackSink,
    required this.microphonePcmStream,
    this.snapshotProvider,
    this.hostPairingCredentials,
    this.pairedHostCredentials,
    this.whiteboardController,
    this.databaseSyncService,
    this.curriculumRagService,
  });

  final TutorModelPaths modelPaths;
  final NativeWorkerDriver workerDriver;
  final TutorStepPlaybackSink playbackSink;
  final Stream<Uint8List> Function() microphonePcmStream;
  final Future<Uint8List?> Function()? snapshotProvider;
  final PairingCredentials? hostPairingCredentials;
  final PairingCredentials? pairedHostCredentials;
  final WhiteboardCanvasController? whiteboardController;
  final P2pLanDatabaseSyncService? databaseSyncService;
  final CurriculumRagService? curriculumRagService;
}

final StateProvider<ExecutionMode> executionModeProvider =
    StateProvider<ExecutionMode>((ref) => ExecutionMode.standaloneHost);

final StateProvider<PairingCredentials?> hostPairingCredentialsProvider =
    StateProvider<PairingCredentials?>((ref) => null);

final StateProvider<PairingCredentials?> pairedHostCredentialsProvider =
    StateProvider<PairingCredentials?>((ref) => null);

final Provider<TutorEngineRuntimeDependencies> tutorEngineRuntimeDependenciesProvider =
    Provider<TutorEngineRuntimeDependencies>((ref) {
  throw StateError(
    'Override tutorEngineRuntimeDependenciesProvider with installed model paths, '
    'microphone capture, and the audio-synchronized playback sink.',
  );
});

/// Chooses exactly one tutor repository for each execution topology.
final Provider<TutorEngineRepository> tutorEngineProvider =
    Provider<TutorEngineRepository>((ref) {
  final mode = ref.watch(executionModeProvider);
  final dependencies = ref.watch(tutorEngineRuntimeDependenciesProvider);
  final paths = dependencies.modelPaths;
  final driver = dependencies.workerDriver;
  final hostCredentials =
      dependencies.hostPairingCredentials ?? ref.watch(hostPairingCredentialsProvider);
  final pairedCredentials =
      dependencies.pairedHostCredentials ?? ref.watch(pairedHostCredentialsProvider);

  late final TutorEngineRepository engine;
  switch (mode) {
    case ExecutionMode.standaloneHost:
      final llmConfig = NativeRuntimeConfig.gemma4Host(
        modelPath: paths.gemma4E4b,
        grammarPath: paths.grammar,
        llamaFallbackModelPath: paths.gemma4E4bGgufFallback,
      );
      final llmWorker = MultimodalLlmWorker(config: llmConfig, driver: driver);
      final voiceWorker = _createVoiceWorker(paths, driver, dependencies.playbackSink);
      final embedding = _createEmbeddingModel(paths, driver);
      final modelOrchestrator = createTutorModelOrchestrator(
        llmWorker: llmWorker,
        voiceWorker: voiceWorker,
        embeddingModel: embedding,
      );
      engine = OnDeviceEngineImpl(
        llmWorker: llmWorker,
        voiceWorker: voiceWorker,
        modelOrchestrator: modelOrchestrator,
        microphonePcmStream: dependencies.microphonePcmStream,
        snapshotProvider: dependencies.snapshotProvider,
        hostPairingCredentials: hostCredentials,
        databaseSyncService: dependencies.databaseSyncService,
        onRemoteStylusEvent: dependencies.whiteboardController == null
            ? null
            : (event) {
                dependencies.whiteboardController!.applyRemoteStylusEvent(event);
              },
        curriculumContextProvider: dependencies.curriculumRagService?.groundedContext,
      );
      break;
    case ExecutionMode.lanCompanion:
      final credentials = pairedCredentials;
      final controller = dependencies.whiteboardController;
      if (credentials == null || controller == null) {
        throw StateError('LAN Companion requires paired host credentials and a whiteboard controller.');
      }
      engine = LanCompanionEngineImpl(
        endpoint: credentials.endpoint,
        pairingKey: credentials.pairingKey,
        whiteboardController: controller,
        microphonePcmStream: dependencies.microphonePcmStream,
        snapshotProvider: dependencies.snapshotProvider,
        databaseSyncService: dependencies.databaseSyncService,
      );
      break;
    case ExecutionMode.lightEdge:
      final llmConfig = NativeRuntimeConfig.gemma4LightEdge(
        modelPath: paths.gemma4E2b,
        grammarPath: paths.grammar,
      );
      final llmWorker = MultimodalLlmWorker(config: llmConfig, driver: driver);
      final voiceWorker = _createVoiceWorker(paths, driver, dependencies.playbackSink);
      final embedding = _createEmbeddingModel(paths, driver);
      final modelOrchestrator = createTutorModelOrchestrator(
        llmWorker: llmWorker,
        voiceWorker: voiceWorker,
        embeddingModel: embedding,
      );
      engine = LightEdgeEngineImpl(
        llmWorker: llmWorker,
        voiceWorker: voiceWorker,
        modelOrchestrator: modelOrchestrator,
        modelConfig: llmConfig,
        microphonePcmStream: dependencies.microphonePcmStream,
        snapshotProvider: dependencies.snapshotProvider,
        curriculumContextProvider: dependencies.curriculumRagService?.groundedContext,
      );
      break;
  }

  ref.onDispose(() => unawaited(engine.dispose()));
  return engine;
});

RealTimeVoiceWorker _createVoiceWorker(
  TutorModelPaths paths,
  NativeWorkerDriver driver,
  TutorStepPlaybackSink playbackSink,
) =>
    RealTimeVoiceWorker.fromConfigs(
      vadConfig: _voiceModelConfig(
        modelId: 'silero-vad',
        path: paths.sileroVad,
        grammarPath: paths.grammar,
        contextTokens: 512,
      ),
      asrConfig: _voiceModelConfig(
        modelId: 'moonshine-whisper-ar-en',
        path: paths.moonshineWhisperAsr,
        grammarPath: paths.grammar,
        contextTokens: 2048,
      ),
      ttsConfig: _voiceModelConfig(
        modelId: 'kokoro-82m',
        path: paths.kokoro82m,
        grammarPath: paths.grammar,
        contextTokens: 1024,
      ),
      playbackSink: playbackSink,
      driver: driver,
    );

NativeRuntimeConfig _voiceModelConfig({
  required String modelId,
  required String path,
  required String grammarPath,
  required int contextTokens,
}) =>
    NativeRuntimeConfig(
      modelId: modelId,
      modelPath: path,
      backend: NativeModelBackend.liteRtLm,
      quantization: 'INT8',
      accelerator: NativeAccelerator.automatic,
      contextTokens: contextTokens,
      grammarPath: grammarPath,
    );

NativeEmbeddingModelResource _createEmbeddingModel(
  TutorModelPaths paths,
  NativeWorkerDriver driver,
) =>
    NativeEmbeddingModelResource(
      config: NativeRuntimeConfig(
        modelId: 'bge-m3-multilingual-e5',
        modelPath: paths.multilingualEmbedding,
        backend: NativeModelBackend.liteRtLm,
        quantization: 'INT8',
        accelerator: NativeAccelerator.cpu,
        contextTokens: 512,
        grammarPath: paths.grammar,
      ),
      driver: driver,
    );
