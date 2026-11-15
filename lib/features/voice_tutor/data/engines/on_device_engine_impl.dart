import 'dart:async';

import 'package:edu/features/companion_sync/data/server/local_host_server.dart';
import 'package:edu/features/companion_sync/data/services/p2p_lan_database_sync_service.dart';
import 'package:edu/features/companion_sync/domain/entities/pairing_credentials.dart';
import 'package:edu/features/voice_tutor/data/engines/local_tutor_engine_base.dart';
import 'package:edu/features/voice_tutor/data/native/native_runtime_config.dart';
import 'package:edu/features/voice_tutor/data/orchestrator/dynamic_model_orchestrator.dart';
import 'package:edu/features/voice_tutor/data/workers/multimodal_llm_worker.dart';
import 'package:edu/features/voice_tutor/data/workers/realtime_voice_worker.dart';
import 'package:edu/features/voice_tutor/domain/entities/tutor_prompt.dart';
import 'package:edu/features/whiteboard/domain/entities/student_stylus_event.dart';

/// Standalone host-phone engine using Gemma 4 E4B and optionally serving a
/// paired tablet through the authenticated local WebSocket host.
final class OnDeviceEngineImpl extends LocalTutorEngineBase {
  OnDeviceEngineImpl({
    required MultimodalLlmWorker llmWorker,
    required RealTimeVoiceWorker voiceWorker,
    required DynamicModelOrchestrator modelOrchestrator,
    Stream<Uint8List> Function()? microphonePcmStream,
    Future<Uint8List?> Function()? snapshotProvider,
    FutureOr<void> Function(StudentStylusEvent event)? onRemoteStylusEvent,
    Future<String> Function(String question)? curriculumContextProvider,
    PairingCredentials? hostPairingCredentials,
    P2pLanDatabaseSyncService? databaseSyncService,
  })  : hostPairingCredentials = hostPairingCredentials,
        databaseSyncService = databaseSyncService,
        super(
          llmWorker: llmWorker,
          voiceWorker: voiceWorker,
          modelOrchestrator: modelOrchestrator,
          microphonePcmStream: microphonePcmStream,
          snapshotProvider: snapshotProvider,
          onRemoteStylusEvent: onRemoteStylusEvent,
          curriculumContextProvider: curriculumContextProvider,
        ) {
    if (llmWorker.modelConfig.modelId != 'gemma-4-e4b-q4_k_m' ||
        llmWorker.modelConfig.backend != NativeModelBackend.liteRtLm ||
        llmWorker.modelConfig.quantization != 'Q4_K_M' ||
        llmWorker.modelConfig.accelerator != NativeAccelerator.automatic ||
        !llmWorker.modelConfig.preferNpu) {
      throw ArgumentError('Standalone Host requires the Gemma 4 E4B LiteRT-LM Q4_K_M profile.');
    }
    if (hostPairingCredentials != null && hostPairingCredentials.endpoint.port < 1) {
      throw ArgumentError('Host pairing credentials must use the bound WebSocket port.');
    }
  }

  final PairingCredentials? hostPairingCredentials;
  final P2pLanDatabaseSyncService? databaseSyncService;
  bool _hostStartAttempted = false;

  @override
  Future<void> initialize() async {
    await super.initialize();
    final credentials = hostPairingCredentials;
    if (credentials != null && !_hostStartAttempted) {
      _hostStartAttempted = true;
      try {
        await startCompanionHost(
          pairingKey: credentials.pairingKey,
          databaseSyncService: databaseSyncService,
          port: credentials.endpoint.port,
        );
      } on Object {
        _hostStartAttempted = false;
        rethrow;
      }
    }
  }

  Future<int> startCompanionHost({
    required String pairingKey,
    P2pLanDatabaseSyncService? databaseSyncService,
    int port = 0,
    Future<void> Function(StudentStylusEvent event)? onRemoteStylusEvent,
  }) async {
    if (!isInitialized) await initialize();
    final server = LocalHostServer(
      pairingKey: pairingKey,
      onPcmChunk: (_, __) {},
      onStylusEvent: (_) {},
      onBoardSnapshot: (_) {},
      onPrompt: (_) {},
      onInterrupt: (_) {},
      databaseSyncService: databaseSyncService,
    );
    await attachCompanionServer(
      server,
      start: false,
      onPrompt: _handleCompanionPrompt,
      onStylusEvent: onRemoteStylusEvent,
    );
    try {
      return await server.start(port: port);
    } on Object {
      await detachCompanionServer();
      rethrow;
    }
  }

  void _handleCompanionPrompt(Map<String, dynamic> message) {
    final text = message['text'];
    if (text is! String || text.trim().isEmpty) {
      throw const FormatException('Companion prompt text is missing.');
    }
    final requestId = message['request_id'] is String
        ? message['request_id'] as String
        : 'companion-${DateTime.now().microsecondsSinceEpoch}';
    final rawDate = message['created_at'];
    final createdAt = rawDate is String
        ? DateTime.tryParse(rawDate)?.toUtc() ?? DateTime.now().toUtc()
        : DateTime.now().toUtc();
    unawaited(submit(TutorPrompt(
      requestId: requestId,
      text: text,
      createdAt: createdAt,
    )).catchError((Object _) {}));
  }

  @override
  Future<void> dispose() => super.dispose();
}
