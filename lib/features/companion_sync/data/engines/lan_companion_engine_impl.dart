import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:edu/core/errors/app_failure.dart';
import 'package:edu/features/companion_sync/data/protocol/audio_step_frame_codec.dart';
import 'package:edu/features/companion_sync/data/services/p2p_lan_database_sync_service.dart';
import 'package:edu/features/whiteboard/domain/entities/student_stylus_event.dart';
import 'package:edu/features/whiteboard/domain/entities/whiteboard_sync_step.dart';
import 'package:edu/features/whiteboard/presentation/controllers/whiteboard_canvas_controller.dart';
import 'package:edu/features/voice_tutor/domain/entities/tutor_engine_event.dart';
import 'package:edu/features/voice_tutor/domain/entities/tutor_prompt.dart';
import 'package:edu/features/voice_tutor/domain/repositories/tutor_engine_repository.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// WebSocket connector injection point used by the production engine and tests.
typedef LanSocketConnector = WebSocketChannel Function(
  Uri uri, {
  required Map<String, dynamic> headers,
});

WebSocketChannel _connectLanSocket(
  Uri uri, {
  required Map<String, dynamic> headers,
}) =>
    IOWebSocketChannel.connect(uri, headers: headers);

/// Tablet-side tutor engine for a paired phone running [LocalHostServer].
/// Microphone input is 16 kHz mono S16LE; received tutor PCM uses the same
/// framing contract and is scheduled against the output device frame clock.
final class LanCompanionEngineImpl implements TutorEngineRepository {
  LanCompanionEngineImpl({
    required this.endpoint,
    required this.pairingKey,
    required this.whiteboardController,
    required this.microphonePcmStream,
    this.snapshotProvider,
    this.databaseSyncService,
    LanSocketConnector connector = _connectLanSocket,
    this.maxSnapshotBytes = 24 * 1024 * 1024,
  }) : _connector = connector {
    if (endpoint.scheme != 'ws' && endpoint.scheme != 'wss') {
      throw ArgumentError.value(endpoint, 'endpoint', 'Expected a WebSocket URI.');
    }
    if (pairingKey.length != 64 ||
        !pairingKey.codeUnits.every((unit) =>
            (unit >= 0x30 && unit <= 0x39) ||
            (unit >= 0x61 && unit <= 0x66) ||
            (unit >= 0x41 && unit <= 0x46))) {
      throw ArgumentError.value(pairingKey, 'pairingKey', 'Expected a 256-bit hex key.');
    }
  }

  static const int pcmSampleRateHz = 16000;
  static const int pcmChannels = 1;

  final Uri endpoint;
  final String pairingKey;
  final WhiteboardCanvasController whiteboardController;
  final Stream<Uint8List> Function() microphonePcmStream;
  final Future<Uint8List?> Function()? snapshotProvider;
  final P2pLanDatabaseSyncService? databaseSyncService;
  final LanSocketConnector _connector;
  final int maxSnapshotBytes;

  final StreamController<TutorEngineEvent> _events =
      StreamController<TutorEngineEvent>.broadcast(sync: true);
  final StreamController<Map<String, dynamic>> _databaseMessages =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final Map<int, WhiteboardSyncStep> _stepsById = <int, WhiteboardSyncStep>{};
  final Map<int, List<Uint8List>> _audioByStepId = <int, List<Uint8List>>{};
  final Map<int, String> _requestIdByStepId = <int, String>{};

  WebSocketChannel? _channel;
  StreamSubscription<Object?>? _socketSubscription;
  StreamSubscription<Uint8List>? _microphoneSubscription;
  StreamSubscription<StudentStylusEvent>? _stylusSubscription;
  Future<void>? _initializeFuture;
  Future<void> _incomingTail = Future<void>.value();
  String? _activeRequestId;
  bool _initialized = false;
  bool _disposed = false;

  @override
  Stream<TutorEngineEvent> get events => _events.stream;

  Future<void> initialize() => _initializeFuture ??= _initialize();

  Future<void> _initialize() async {
    if (_disposed) throw StateError('LAN companion engine is disposed.');
    final channel = _connector(
      endpoint,
      headers: <String, dynamic>{'Authorization': 'Bearer $pairingKey'},
    );
    _channel = channel;
    try {
      await channel.ready;
    } on Object catch (error) {
      await channel.sink.close();
      _channel = null;
      throw TransportFailure('Could not connect to the paired tutor host.', cause: error);
    }
    if (_disposed) {
      await channel.sink.close();
      return;
    }
    _initialized = true;
    _socketSubscription = channel.stream.listen(
      (Object? frame) {
        _incomingTail = _incomingTail.then((_) => _handleIncoming(frame)).catchError(
          (Object error, StackTrace stackTrace) => _emitFailure(error),
        );
      },
      onError: (Object error, StackTrace stackTrace) => _emitFailure(error),
      onDone: () {
        _initialized = false;
        if (!_disposed) _emitFailure(StateError('Host connection closed.'));
      },
      cancelOnError: true,
    );
    _microphoneSubscription = microphonePcmStream().listen(
      _sendMicrophonePcm,
      onError: (Object error, StackTrace stackTrace) => _emitFailure(error),
      cancelOnError: true,
    );
    _stylusSubscription = whiteboardController.studentStylusEvents.listen(
      _sendStylusEvent,
      onError: (Object error, StackTrace stackTrace) => _emitFailure(error),
      cancelOnError: true,
    );
    final syncService = databaseSyncService;
    if (syncService != null) {
      await syncService.start(
        incoming: _databaseMessages.stream,
        send: (message) => _sendJson(<String, Object?>{
          'type': 'database_sync',
          'message': message,
        }),
      );
    }
  }

  @override
  Future<void> submit(TutorPrompt prompt) async {
    if (!_initialized || _disposed) {
      throw StateError('Initialize the LAN companion engine before submitting prompts.');
    }
    _activeRequestId = prompt.requestId;
    await _sendJson(<String, Object?>{
      'type': 'prompt',
      'request_id': prompt.requestId,
      'text': prompt.text,
      'created_at': prompt.createdAt.toUtc().toIso8601String(),
    });
  }

  @override
  Future<void> interrupt() async {
    if (_disposed) return;
    final requestId = _activeRequestId;
    _activeRequestId = null;
    await whiteboardController.bargeIn();
    if (_initialized) {
      await _sendJson(<String, Object?>{
        'type': 'interrupt',
        'request_id': requestId,
      });
    }
  }

  /// Sends a user-requested compressed board image for multimodal grading.
  /// This is never called on a timer or during ordinary tutor turns.
  Future<void> sendBoardSnapshot(Uint8List webpBytes, {String? requestId}) async {
    if (!_initialized || _disposed) throw StateError('LAN companion engine is not connected.');
    if (webpBytes.isEmpty || webpBytes.length > maxSnapshotBytes || !_hasWebpHeader(webpBytes)) {
      throw const FormatException('Board snapshot must be bounded WebP data.');
    }
    final transferable = TransferableTypedData.fromList(<Uint8List>[webpBytes]);
    final encoded = await Isolate.run<String>(
      () => base64Encode(transferable.materialize().asUint8List()),
    );
    await _sendJson(<String, Object?>{
      'type': 'board_snapshot',
      'format': 'webp',
      'request_id': requestId,
      'data': encoded,
    });
  }

  Future<void> _sendMicrophonePcm(Uint8List pcm) async {
    if (!_initialized || pcm.isEmpty || pcm.length.isOdd) {
      if (pcm.isNotEmpty && pcm.length.isOdd) {
        _emitFailure(const FormatException('Microphone PCM must contain complete S16 samples.'));
      }
      return;
    }
    _channel?.sink.add(pcm);
  }

  Future<void> _sendStylusEvent(StudentStylusEvent event) async {
    if (!_initialized) return;
    await _sendJson(<String, Object?>{
      'type': 'student_stylus_event',
      'event': event.toJson(),
    });
  }

  Future<void> _handleIncoming(Object? frame) async {
    if (frame is String) {
      await _handleJsonFrame(frame);
      return;
    }
    if (frame is Uint8List || frame is List<int>) {
      final bytes = frame is Uint8List ? frame : Uint8List.fromList(frame as List<int>);
      final decoded = AudioStepFrameCodec.decode(bytes);
      final chunks = _audioByStepId.putIfAbsent(decoded.stepId, () => <Uint8List>[]);
      chunks.add(decoded.pcmChunk);
      return;
    }
    throw const FormatException('Host sent an unsupported frame type.');
  }

  Future<void> _handleJsonFrame(String text) async {
    if (text.length > maxSnapshotBytes * 3 ~/ 2) {
      throw const FormatException('Host JSON frame exceeds the configured size limit.');
    }
    final decoded = await Isolate.run<Object?>(() => jsonDecode(text));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Host text frame must be a JSON object.');
    }
    switch (decoded['type']) {
      case 'whiteboard_step':
        final rawStep = decoded['step'];
        if (rawStep is! Map<String, dynamic>) {
          throw const FormatException('Whiteboard step frame is missing its step.');
        }
        final step = WhiteboardSyncStep.fromJson(rawStep);
        _stepsById[step.stepId] = step;
        final requestId = decoded['request_id'] is String
            ? decoded['request_id'] as String
            : (_activeRequestId ?? 'lan-session');
        _requestIdByStepId[step.stepId] = requestId;
        _events.add(TutorWhiteboardStepEvent(requestId: requestId, step: step));
        break;
      case 'audio_end':
        final rawStepId = decoded['step_id'];
        if (rawStepId is! int) throw const FormatException('Audio end frame has no step id.');
        _finishAudioStep(rawStepId);
        break;
      case 'interrupt':
        final requestId = decoded['request_id'];
        if (requestId is! String || requestId == _activeRequestId) {
          _activeRequestId = null;
          await whiteboardController.bargeIn();
        }
        break;
      case 'text_delta':
        if (decoded['text'] is! String) throw const FormatException('Text delta is invalid.');
        final requestId = _requestId(decoded);
        _events.add(TutorTextDelta(requestId: requestId, text: decoded['text'] as String));
        break;
      case 'turn_completed':
        final requestId = _requestId(decoded);
        _events.add(TutorTurnCompleted(requestId: requestId));
        if (_activeRequestId == requestId) _activeRequestId = null;
        break;
      case 'turn_failed':
        final requestId = _requestId(decoded);
        _events.add(TutorTurnFailed(
          requestId: requestId,
          failure: TransportFailure(
            decoded['message'] is String ? decoded['message'] as String : 'Tutor host failed.',
          ),
        ));
        if (_activeRequestId == requestId) _activeRequestId = null;
        break;
      case 'snapshot_request':
        unawaited(_sendSnapshot(decoded));
        break;
      case 'database_sync':
        final message = decoded['message'];
        if (message is! Map<String, dynamic>) {
          throw const FormatException('Database sync frame is invalid.');
        }
        _databaseMessages.add(message);
        break;
      case 'protocol_error':
        throw FormatException('${decoded['message'] ?? 'Host rejected a frame.'}');
      default:
        throw FormatException('Unknown host frame type: ${decoded['type']}');
    }
  }

  void _finishAudioStep(int stepId) {
    final step = _stepsById.remove(stepId);
    final chunks = _audioByStepId.remove(stepId);
    final requestId = _requestIdByStepId.remove(stepId) ?? _activeRequestId ?? 'lan-session';
    if (step == null || chunks == null || chunks.isEmpty) {
      throw FormatException('Step $stepId ended without a step frame and PCM audio.');
    }
    unawaited(_playStep(step, chunks, requestId));
  }

  Future<void> _playStep(
    WhiteboardSyncStep step,
    List<Uint8List> chunks,
    String requestId,
  ) async {
    try {
      await whiteboardController.enqueueStep(
        step: step,
        pcmChunks: chunks,
        sampleRateHz: pcmSampleRateHz,
        channels: pcmChannels,
      );
    } on Object catch (error) {
      _events.add(TutorTurnFailed(
        requestId: requestId,
        failure: TransportFailure('Could not schedule tutor audio.', cause: error),
      ));
    }
  }

  Future<void> _sendSnapshot(Map<String, dynamic> request) async {
    final provider = snapshotProvider;
    if (provider == null || !_initialized) return;
    try {
      final webp = await provider();
      if (webp == null) return;
      if (webp.length > maxSnapshotBytes || !_hasWebpHeader(webp)) {
        throw const FormatException('Snapshot provider must return bounded WebP bytes.');
      }
      final transferable = TransferableTypedData.fromList(<Uint8List>[webp]);
      final encoded = await Isolate.run<String>(
        () => base64Encode(transferable.materialize().asUint8List()),
      );
      await _sendJson(<String, Object?>{
        'type': 'board_snapshot',
        'format': 'webp',
        'request_id': request['request_id'],
        'data': encoded,
      });
    } on Object catch (error) {
      _emitFailure(error);
    }
  }

  static bool _hasWebpHeader(Uint8List bytes) =>
      bytes.length >= 12 &&
      bytes[0] == 0x52 && bytes[1] == 0x49 &&
      bytes[2] == 0x46 && bytes[3] == 0x46 &&
      bytes[8] == 0x57 && bytes[9] == 0x45 &&
      bytes[10] == 0x42 && bytes[11] == 0x50;

  String _requestId(Map<String, dynamic> frame) =>
      frame['request_id'] is String ? frame['request_id'] as String : (_activeRequestId ?? 'lan-session');

  Future<void> _sendJson(Map<String, Object?> message) async {
    if (!_initialized || _channel == null) {
      throw StateError('LAN companion WebSocket is not connected.');
    }
    _channel!.sink.add(jsonEncode(message));
  }

  void _emitFailure(Object error) {
    if (_disposed) return;
    _events.add(TutorTurnFailed(
      requestId: _activeRequestId ?? 'lan-session',
      failure: TransportFailure('LAN companion transport failed.', cause: error),
    ));
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _initialized = false;
    await _microphoneSubscription?.cancel();
    await _stylusSubscription?.cancel();
    await _socketSubscription?.cancel();
    await _incomingTail;
    _audioByStepId.clear();
    _stepsById.clear();
    _requestIdByStepId.clear();
    await databaseSyncService?.dispose();
    final channel = _channel;
    _channel = null;
    await channel?.sink.close();
    await _databaseMessages.close();
    await _events.close();
  }
}
