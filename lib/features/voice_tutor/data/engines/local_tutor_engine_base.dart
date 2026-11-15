import 'dart:async';
import 'dart:typed_data';

import 'package:edu/core/errors/app_failure.dart';
import 'package:edu/features/companion_sync/data/server/local_host_server.dart';
import 'package:edu/features/voice_tutor/data/orchestrator/dynamic_model_orchestrator.dart';
import 'package:edu/features/voice_tutor/data/workers/multimodal_llm_worker.dart';
import 'package:edu/features/voice_tutor/data/workers/realtime_voice_worker.dart';
import 'package:edu/features/voice_tutor/domain/entities/tutor_engine_event.dart';
import 'package:edu/features/voice_tutor/domain/entities/tutor_prompt.dart';
import 'package:edu/features/voice_tutor/domain/repositories/tutor_engine_repository.dart';
import 'package:edu/features/whiteboard/domain/entities/student_stylus_event.dart';

/// Shared local-inference lifecycle for standalone host and Light Edge modes.
abstract class LocalTutorEngineBase implements TutorEngineRepository {
  LocalTutorEngineBase({
    required this.llmWorker,
    required this.voiceWorker,
    required this.modelOrchestrator,
    this.microphonePcmStream,
    this.snapshotProvider,
    this.onRemoteStylusEvent,
    this.curriculumContextProvider,
  }) {
    voiceWorker.addBargeInListener(_handleVoiceBargeIn);
  }

  final MultimodalLlmWorker llmWorker;
  final RealTimeVoiceWorker voiceWorker;
  final DynamicModelOrchestrator modelOrchestrator;
  final Stream<Uint8List> Function()? microphonePcmStream;
  final Future<Uint8List?> Function()? snapshotProvider;
  final FutureOr<void> Function(StudentStylusEvent event)? onRemoteStylusEvent;
  final Future<String> Function(String question)? curriculumContextProvider;
  final StreamController<TutorEngineEvent> _events =
      StreamController<TutorEngineEvent>.broadcast(sync: true);
  final Map<String, Uint8List> _audioContextByRequest = <String, Uint8List>{};
  final Set<Future<void>> _playbackJobs = <Future<void>>{};
  final List<StreamSubscription<dynamic>> _companionSubscriptions =
      <StreamSubscription<dynamic>>[];
  Future<void> _requestTail = Future<void>.value();
  LocalHostServer? _companionServer;
  Uint8List? _latestBoardSnapshot;
  int _voiceRequestNumber = 1;
  String? _activeRequestId;
  bool _initialized = false;
  bool _disposed = false;

  Stream<TutorEngineEvent> get events => _events.stream;
  bool get isInitialized => _initialized;
  Uint8List? get latestBoardSnapshot =>
      _latestBoardSnapshot == null ? null : Uint8List.fromList(_latestBoardSnapshot!);

  Future<void> initialize() async {
    if (_disposed) throw StateError('Tutor engine has been disposed.');
    if (_initialized) return;
    await modelOrchestrator.startSession();
    try {
      await llmWorker.initialize();
      await voiceWorker.initialize();
      final pcmStream = microphonePcmStream?.call();
      if (pcmStream != null) {
        voiceWorker.listenToMicrophone(
          pcmStream,
          onTranscript: (transcript) =>
              _submitTranscription(transcript, prefix: 'voice'),
        );
      }
      _initialized = true;
    } on Object {
      await voiceWorker.dispose();
      await llmWorker.dispose();
      await modelOrchestrator.stopSession();
      rethrow;
    }
  }

  void _handleVoiceBargeIn() {
    final activeRequest = _activeRequestId;
    if (activeRequest != null) unawaited(llmWorker.interrupt(activeRequest));
    final server = _companionServer;
    if (server != null) unawaited(server.broadcastInterrupt(requestId: activeRequest));
  }

  Future<void> submit(TutorPrompt prompt) {
    if (_disposed) return Future<void>.error(StateError('Tutor engine has been disposed.'));
    final prior = _requestTail;
    final run = prior.then((_) => _generate(prompt));
    _requestTail = run.catchError((Object _) {});
    return run;
  }

  void _submitTranscription(String text, {required String prefix}) {
    final requestId = '$prefix-${_voiceRequestNumber++}';
    final audioContext = voiceWorker.lastRecognizedAudioContext;
    if (audioContext != null) _audioContextByRequest[requestId] = audioContext;
    unawaited(submit(TutorPrompt(
      requestId: requestId,
      text: text,
      createdAt: DateTime.now().toUtc(),
    )).catchError((Object _) {}));
  }

  Future<void> _generate(TutorPrompt prompt) async {
    if (!_initialized) await initialize();
    _activeRequestId = prompt.requestId;
    try {
      final snapshot = await snapshotProvider?.call() ?? _latestBoardSnapshot;
      final audioContext = _audioContextByRequest.remove(prompt.requestId);
      final contextBuilder = curriculumContextProvider;
      final context = contextBuilder == null ? null : await contextBuilder(prompt.text);
      final tutorPrompt = context == null
          ? prompt
          : TutorPrompt(
              requestId: prompt.requestId,
              text: '${prompt.text}\n\n$context',
              createdAt: prompt.createdAt,
            );
      await for (final event in llmWorker.generate(
        tutorPrompt,
        audioContext: audioContext,
        webpSnapshot: snapshot,
      )) {
        if (event is TutorWhiteboardStepEvent) {
          final synthesized = await voiceWorker.synthesizeStep(event.step);
          final server = _companionServer;
          if (server != null) {
            await server.sendSynchronizedStep(
              event.step,
              synthesized.pcmChunks,
              requestId: prompt.requestId,
            );
          }
          _watchPlayback(synthesized.playback, prompt.requestId);
        } else {
          final server = _companionServer;
          if (server != null) {
            switch (event) {
              case TutorTextDelta(:final text):
                await server.sendJsonToPeers(<String, Object?>{
                  'type': 'text_delta',
                  'request_id': event.requestId,
                  'text': text,
                });
                break;
              case TutorTurnCompleted():
                await server.sendJsonToPeers(<String, Object?>{
                  'type': 'turn_completed',
                  'request_id': event.requestId,
                });
                break;
              case TutorTurnFailed(:final failure):
                await server.sendJsonToPeers(<String, Object?>{
                  'type': 'turn_failed',
                  'request_id': event.requestId,
                  'message': failure.message,
                });
                break;
              case TutorWhiteboardStepEvent():
                break;
            }
          }
        }
        if (!_events.isClosed) _events.add(event);
      }
    } on VoiceStepCancelled {
      return;
    } on Object catch (error) {
      final server = _companionServer;
      if (server != null) {
        unawaited(server.sendJsonToPeers(<String, Object?>{
          'type': 'turn_failed',
          'request_id': prompt.requestId,
          'message': error.toString(),
        }).catchError((Object _) {}));
      }
      if (!_events.isClosed) {
        _events.add(TutorTurnFailed(
          requestId: prompt.requestId,
          failure: EngineFailure(error.toString()),
        ));
      }
      rethrow;
    } finally {
      if (_activeRequestId == prompt.requestId) _activeRequestId = null;
    }
  }

  void _watchPlayback(Future<StepPlaybackResult> playback, String requestId) {
    late final Future<void> tracked;
    tracked = _observePlayback(playback, requestId).whenComplete(() {
      _playbackJobs.remove(tracked);
    });
    _playbackJobs.add(tracked);
  }

  Future<void> _observePlayback(
    Future<StepPlaybackResult> playback,
    String requestId,
  ) async {
    try {
      await playback;
    } on Object catch (error) {
      if (!_events.isClosed) {
        _events.add(TutorTurnFailed(
          requestId: requestId,
          failure: EngineFailure('Tutor audio playback failed.', cause: error),
        ));
      }
    }
  }

  Future<void> interrupt({String? requestId}) async {
    final activeRequest = requestId ?? _activeRequestId;
    await Future.wait<void>(<Future<void>>[
      if (activeRequest != null) llmWorker.interrupt(activeRequest),
      voiceWorker.bargeIn(activeRequest ?? 'engine-interrupt'),
    ]);
    final server = _companionServer;
    if (server != null) await server.broadcastInterrupt(requestId: activeRequest);
  }

  void updateBoardSnapshot(Uint8List? snapshot) {
    _latestBoardSnapshot = snapshot == null ? null : Uint8List.fromList(snapshot);
  }

  Future<void> receiveHostPcm(Uint8List pcm) => voiceWorker.processMicrophoneFrame(
        pcm,
        onTranscript: (transcript) =>
            _submitTranscription(transcript, prefix: 'companion-voice'),
      );

  void receiveBoardSnapshot(Uint8List snapshot) => updateBoardSnapshot(snapshot);

  Future<void> receiveRemoteStylusEvent(StudentStylusEvent event) async {
    await onRemoteStylusEvent?.call(event);
  }

  Future<void> attachCompanionServer(
    LocalHostServer server, {
    bool start = true,
    FutureOr<void> Function(Map<String, dynamic> prompt)? onPrompt,
    FutureOr<void> Function(StudentStylusEvent event)? onStylusEvent,
  }) async {
    if (_disposed) throw StateError('Tutor engine has been disposed.');
    await detachCompanionServer();
    _companionServer = server;
    _companionSubscriptions
      ..add(server.companionPcmAudio.listen((chunk) {
        if (chunk.sampleRateHz != RealTimeVoiceWorker.sampleRateHz) {
          _emitCompanionFailure('Unsupported companion PCM sample rate.');
          return;
        }
        unawaited(_routeCompanionPcm(chunk));
      }))
      ..add(server.studentStylusEvents.listen((event) {
        unawaited(_routeCompanionStylus(event, onStylusEvent));
      }))
      ..add(server.boardSnapshots.listen(receiveBoardSnapshot))
      ..add(server.bargeInInterrupts.listen((message) {
        unawaited(_handleRemoteInterrupt(message).catchError((Object error) {
          _emitCompanionFailure('Companion interruption failed: $error');
        }));
      }));
    if (onPrompt != null) {
      _companionSubscriptions.add(server.companionPrompts.listen((prompt) {
        unawaited(Future<void>.sync(() => onPrompt(prompt)).catchError((Object error) {
          _emitCompanionFailure('Companion request could not be processed: $error');
        }));
      }));
    }
    if (start) {
      try {
        await server.start();
      } on Object {
        await detachCompanionServer();
        rethrow;
      }
    }
  }

  Future<void> _routeCompanionPcm(CompanionPcmAudioChunk chunk) async {
    try {
      await receiveHostPcm(chunk.pcm);
    } on Object catch (error) {
      _emitCompanionFailure('Companion audio processing failed: $error');
    }
  }

  Future<void> _routeCompanionStylus(
    StudentStylusEvent event,
    FutureOr<void> Function(StudentStylusEvent event)? handler,
  ) async {
    try {
      await (handler ?? onRemoteStylusEvent)?.call(event);
    } on Object catch (error) {
      _emitCompanionFailure('Companion stylus event failed: $error');
    }
  }

  Future<void> _handleRemoteInterrupt(Map<String, dynamic> message) async {
    final requestId = message['request_id'];
    if (requestId is String) await llmWorker.interrupt(requestId);
    await voiceWorker.bargeIn(requestId is String ? requestId : 'companion-interrupt');
  }

  void _emitCompanionFailure(String message) {
    if (!_events.isClosed) {
      _events.add(TutorTurnFailed(
        requestId: 'companion',
        failure: EngineFailure(message),
      ));
    }
  }

  Future<void> detachCompanionServer() async {
    for (final subscription in _companionSubscriptions) {
      await subscription.cancel();
    }
    _companionSubscriptions.clear();
    final server = _companionServer;
    _companionServer = null;
    await server?.dispose();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await interrupt();
    } on Object {
      // Continue releasing native resources even when cancellation fails.
    }
    await detachCompanionServer();
    voiceWorker.removeBargeInListener(_handleVoiceBargeIn);
    await voiceWorker.dispose();
    await Future.wait<void>(_playbackJobs.toList());
    await llmWorker.dispose();
    await modelOrchestrator.stopSession();
    _latestBoardSnapshot = null;
    _audioContextByRequest.clear();
    await _events.close();
    _initialized = false;
  }
}
