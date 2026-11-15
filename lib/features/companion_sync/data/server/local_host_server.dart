import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:edu/features/companion_sync/data/protocol/audio_step_frame_codec.dart';
import 'package:edu/features/companion_sync/data/services/p2p_lan_database_sync_service.dart';
import 'package:edu/features/whiteboard/domain/entities/student_stylus_event.dart';
import 'package:edu/features/whiteboard/domain/entities/whiteboard_sync_step.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// PCM bytes received from a paired companion, with their wire sample rate.
final class CompanionPcmAudioChunk {
  const CompanionPcmAudioChunk({required this.pcm, required this.sampleRateHz});

  final Uint8List pcm;
  final int sampleRateHz;
}

/// Authenticated HTTP/WebSocket host for a paired study tablet.
///
/// Pairing keys are fixed-length 256-bit hex tokens. Authorization is checked
/// in the HTTP handler before the WebSocket upgrade handler is called.
final class LocalHostServer {
  LocalHostServer({
    required this.pairingKey,
    required this.onPcmChunk,
    required this.onStylusEvent,
    required this.onBoardSnapshot,
    this.onPrompt,
    this.onInterrupt,
    this.databaseSyncService,
    this.maxPcmChunkBytes = 2 * 1024 * 1024,
    this.maxSnapshotBytes = 24 * 1024 * 1024,
  }) {
    if (!_isValidPairingKey(pairingKey)) {
      throw ArgumentError.value(pairingKey, 'pairingKey', 'Expected a 256-bit hex key.');
    }
    if (maxPcmChunkBytes < 2 || maxSnapshotBytes < 20) {
      throw ArgumentError('Companion frame limits must permit valid PCM and WebP payloads.');
    }
    _webSocketHandler = webSocketHandler(_onConnection);
  }

  static const String servicePath = '/sync';
  static const int pcmSampleRateHz = 16000;
  static const int pcmChannels = 1;

  final String pairingKey;
  final FutureOr<void> Function(Uint8List pcm, int sampleRateHz) onPcmChunk;
  final FutureOr<void> Function(StudentStylusEvent event) onStylusEvent;
  final FutureOr<void> Function(Uint8List webpBytes) onBoardSnapshot;
  final FutureOr<void> Function(Map<String, dynamic> prompt)? onPrompt;
  final FutureOr<void> Function(Map<String, dynamic> message)? onInterrupt;
  final P2pLanDatabaseSyncService? databaseSyncService;
  final int maxPcmChunkBytes;
  final int maxSnapshotBytes;

  final Set<WebSocketChannel> _connections = <WebSocketChannel>{};
  final StreamController<Map<String, dynamic>> _databaseMessages =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final StreamController<CompanionPcmAudioChunk> _companionPcmAudio =
      StreamController<CompanionPcmAudioChunk>.broadcast(sync: true);
  final StreamController<StudentStylusEvent> _studentStylusEvents =
      StreamController<StudentStylusEvent>.broadcast(sync: true);
  final StreamController<Uint8List> _boardSnapshots =
      StreamController<Uint8List>.broadcast(sync: true);
  final StreamController<Map<String, dynamic>> _companionPrompts =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final StreamController<Map<String, dynamic>> _bargeInInterrupts =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final _PayloadIsolateWorker _payloadWorker = _PayloadIsolateWorker();
  late final Handler _webSocketHandler;
  HttpServer? _httpServer;
  Future<void> _sendTail = Future<void>.value();
  bool _disposed = false;

  Stream<Map<String, dynamic>> get databaseMessages => _databaseMessages.stream;
  Stream<CompanionPcmAudioChunk> get companionPcmAudio => _companionPcmAudio.stream;
  Stream<StudentStylusEvent> get studentStylusEvents => _studentStylusEvents.stream;
  Stream<Uint8List> get boardSnapshots => _boardSnapshots.stream;
  Stream<Map<String, dynamic>> get companionPrompts => _companionPrompts.stream;
  Stream<Map<String, dynamic>> get bargeInInterrupts => _bargeInInterrupts.stream;
  int get port => _httpServer?.port ?? (throw StateError('Host server is not started.'));
  bool get isRunning => _httpServer != null;

  /// Starts the server on all IPv4 interfaces by default and returns its port.
  Future<int> start({InternetAddress address = InternetAddress.anyIPv4, int port = 0}) async {
    if (_disposed) throw StateError('Host server is disposed.');
    if (_httpServer != null) return _httpServer!.port;
    await _payloadWorker.start();
    _httpServer = await shelf_io.serve(_handleRequest, address, port);
    final syncService = databaseSyncService;
    if (syncService != null) {
      await syncService.start(incoming: databaseMessages, send: sendDatabaseMessage);
    }
    return _httpServer!.port;
  }

  /// Exposed for unit tests and for callers composing a custom Shelf pipeline.
  Handler get handler => _handleRequest;

  Future<Response> _handleRequest(Request request) async {
    if (_disposed) return Response(503, body: 'Server is shutting down.');
    if (request.url.path != servicePath.substring(1)) {
      return Response.notFound('Not found.');
    }
    if (request.method != 'GET') {
      return Response(405, body: 'WebSocket upgrade requires GET.', headers: <String, String>{
        'allow': 'GET',
      });
    }

    final header = request.headers['authorization'];
    final candidate = _bearerToken(header);
    final tokenMatches = constantTimeTokenEquals(candidate ?? '', pairingKey);
    if (candidate == null || !tokenMatches) {
      return Response(401, body: 'Unauthorized.', headers: <String, String>{
        'www-authenticate': 'Bearer',
        'cache-control': 'no-store',
      });
    }

    return _webSocketHandler(request);
  }

  static String? _bearerToken(String? header) {
    if (header == null) return null;
    final separator = header.indexOf(' ');
    if (separator <= 0 || header.substring(0, separator).toLowerCase() != 'bearer') {
      return null;
    }
    final token = header.substring(separator + 1);
    if (token.isEmpty || token.contains(RegExp(r'\s'))) return null;
    return token;
  }

  /// Compares every expected token position and accumulates all differences;
  /// it never returns early for a prefix match or a mismatch.
  static bool constantTimeTokenEquals(String provided, String expected) {
    var mismatch = provided.length ^ expected.length;
    for (var index = 0; index < expected.length; index++) {
      final expectedUnit = expected.codeUnitAt(index);
      final providedUnit = index < provided.length ? provided.codeUnitAt(index) : 0;
      mismatch |= expectedUnit ^ providedUnit;
    }
    return mismatch == 0;
  }

  static bool _isValidPairingKey(String key) {
    if (key.length != 64) return false;
    for (final unit in key.codeUnits) {
      final valid = (unit >= 0x30 && unit <= 0x39) ||
          (unit >= 0x61 && unit <= 0x66) ||
          (unit >= 0x41 && unit <= 0x46);
      if (!valid) return false;
    }
    return true;
  }

  void _onConnection(WebSocketChannel channel) {
    if (_disposed) {
      unawaited(channel.sink.close(WebSocketStatus.goingAway));
      return;
    }
    _connections.add(channel);
    var processing = Future<void>.value();
    channel.stream.listen(
      (Object? data) {
        processing = processing.then((_) => _routeFrame(data)).catchError(
          (Object error, StackTrace stackTrace) {
            _sendProtocolError(channel, error);
          },
        );
      },
      onError: (Object error, StackTrace stackTrace) {
        _connections.remove(channel);
      },
      onDone: () {
        _connections.remove(channel);
      },
      cancelOnError: true,
    );
  }

  Future<void> _routeFrame(Object? frame) async {
    if (frame is String) {
      await processTextFrame(frame);
      return;
    }
    if (frame is Uint8List || frame is List<int>) {
      final bytes = frame is Uint8List ? frame : Uint8List.fromList(frame as List<int>);
      if (bytes.isEmpty || bytes.length > maxPcmChunkBytes || bytes.length.isOdd) {
        throw const FormatException('PCM chunk size must be even and within the configured limit.');
      }
      final transferred = await _payloadWorker.processPcm(bytes);
      _companionPcmAudio.add(CompanionPcmAudioChunk(
        pcm: transferred,
        sampleRateHz: pcmSampleRateHz,
      ));
      await onPcmChunk(transferred, pcmSampleRateHz);
      return;
    }
    throw const FormatException('Unsupported WebSocket frame type.');
  }

  /// Parses and routes one JSON frame. JSON parsing and WebP base64 decoding
  /// happen in a worker isolate rather than on Flutter's UI isolate.
  Future<void> processTextFrame(String text) async {
    if (text.length > maxSnapshotBytes * 3 ~/ 2) {
      throw const FormatException('JSON frame exceeds the configured size limit.');
    }
    final decoded = await _payloadWorker.parseJson(text);
    final message = Map<String, dynamic>.from(decoded);
    switch (message['type']) {
      case 'stylus':
      case 'student_stylus_event':
        final rawEvent = message['event'] ?? message;
        if (rawEvent is! Map<String, dynamic>) {
          throw const FormatException('Stylus event is missing or malformed.');
        }
        final event = StudentStylusEvent.fromJson(rawEvent);
        _studentStylusEvents.add(event);
        await onStylusEvent(event);
        break;
      case 'board_snapshot':
        if (message['format'] != 'webp' || message['data'] is! String) {
          throw const FormatException('Board snapshots must contain base64 WebP data.');
        }
        final webp = await _payloadWorker.decodeWebpBase64(
          message['data'] as String,
          maxBytes: maxSnapshotBytes,
        );
        if (webp.length > maxSnapshotBytes) {
          throw const FormatException('WebP snapshot exceeds the configured byte limit.');
        }
        _boardSnapshots.add(webp);
        await onBoardSnapshot(webp);
        break;
      case 'prompt':
        final callback = onPrompt;
        if (callback == null) throw const FormatException('Prompt handling is not configured.');
        _companionPrompts.add(Map<String, dynamic>.unmodifiable(message));
        await callback(message);
        break;
      case 'interrupt':
        _bargeInInterrupts.add(Map<String, dynamic>.unmodifiable(message));
        final callback = onInterrupt;
        if (callback != null) await callback(message);
        break;
      case 'database_sync':
        final raw = message['message'];
        if (raw is! Map<String, dynamic>) {
          throw const FormatException('Database sync message is missing or malformed.');
        }
        _databaseMessages.add(raw);
        break;
      default:
        throw FormatException('Unknown companion message type: ${message['type']}');
    }
  }

  void _sendProtocolError(WebSocketChannel channel, Object error) {
    try {
      channel.sink.add(jsonEncode(<String, Object>{
        'type': 'protocol_error',
        'message': error is FormatException ? error.message : 'Invalid companion frame.',
      }));
    } on Object {
      _connections.remove(channel);
    }
  }

  /// Sends one tutor step followed by four-byte step-id framed PCM chunks and
  /// an audio-end marker as one atomic ordered batch.
  Future<void> sendSynchronizedStep(
    WhiteboardSyncStep step,
    List<Uint8List> pcmChunks, {
    String? requestId,
  }) =>
      sendStepToPeers(step, pcmChunks, requestId: requestId);

  Future<void> sendStepToPeers(
    WhiteboardSyncStep step,
    List<Uint8List> pcmChunks, {
    String? requestId,
  }) {
    if (pcmChunks.isEmpty) {
      return Future<void>.error(ArgumentError.value(pcmChunks, 'pcmChunks'));
    }
    final messages = <Object>[
      jsonEncode(<String, Object?>{
        'type': 'whiteboard_step',
        'request_id': requestId,
        'step': step.toJson(),
      }),
      for (final chunk in pcmChunks) AudioStepFrameCodec.encode(step.stepId, chunk),
      jsonEncode(<String, Object>{'type': 'audio_end', 'step_id': step.stepId}),
    ];
    return _queueAtomicBatch(messages);
  }

  Future<void> sendJsonToPeers(Map<String, Object?> message) =>
      _queueAtomicBatch(<Object>[jsonEncode(message)]);

  Future<void> broadcastInterrupt({String? requestId}) => sendJsonToPeers(
        <String, Object?>{
          'type': 'interrupt',
          if (requestId != null) 'request_id': requestId,
        },
      );

  Future<void> sendDatabaseMessage(Map<String, Object?> message) =>
      sendJsonToPeers(<String, Object?>{'type': 'database_sync', 'message': message});

  Future<void> _queueAtomicBatch(List<Object> messages) {
    if (_disposed) return Future<void>.error(StateError('Host server is disposed.'));
    final operation = _sendTail.then((_) async {
      final peers = List<WebSocketChannel>.of(_connections);
      for (final peer in peers) {
        for (final message in messages) {
          peer.sink.add(message);
        }
      }
    });
    _sendTail = operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final server = _httpServer;
    _httpServer = null;
    for (final connection in List<WebSocketChannel>.of(_connections)) {
      await connection.sink.close(WebSocketStatus.goingAway);
    }
    _connections.clear();
    await server?.close(force: true);
    await _sendTail;
    await databaseSyncService?.dispose();
    await _payloadWorker.dispose();
    await Future.wait<void>(<Future<void>>[
      _databaseMessages.close(),
      _companionPcmAudio.close(),
      _studentStylusEvents.close(),
      _boardSnapshots.close(),
      _companionPrompts.close(),
      _bargeInInterrupts.close(),
    ]);
  }
}

final class _PayloadIsolateWorker {
  final ReceivePort _responses = ReceivePort();
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  StreamSubscription<Object?>? _responseSubscription;
  Isolate? _isolate;
  SendPort? _workerPort;
  Future<void>? _startFuture;
  int _nextId = 1;

  Future<void> start() => _startFuture ??= _start();

  Future<void> _start() async {
    final ready = Completer<SendPort>();
    _responseSubscription = _responses.listen((Object? message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      if (message is List<Object?> && message.length >= 3 && message[0] is int) {
        final id = message[0] as int;
        final completer = _pending.remove(id);
        if (completer == null) return;
        if (message[1] == true) {
          completer.complete(message[2]);
        } else {
          completer.completeError(FormatException('${message[2]}'));
        }
      }
    });
    _isolate = await Isolate.spawn<SendPort>(
      _payloadWorkerMain,
      _responses.sendPort,
      debugName: 'companion-payload-worker',
    );
    _workerPort = await ready.future;
  }

  Future<Uint8List> processPcm(Uint8List bytes) async {
    await start();
    final result = await _request(
      'pcm',
      TransferableTypedData.fromList(<Uint8List>[bytes]),
    );
    return (result as TransferableTypedData).materialize().asUint8List();
  }

  Future<Map<String, dynamic>> parseJson(String text) async {
    await start();
    final result = await _request('json', text);
    if (result is! Map<String, dynamic>) {
      throw const FormatException('JSON frame must be an object.');
    }
    return result;
  }

  Future<Uint8List> decodeWebpBase64(String encoded, {required int maxBytes}) async {
    await start();
    final result = await _request('webp', <Object?>[encoded, maxBytes]);
    return (result as TransferableTypedData).materialize().asUint8List();
  }

  Future<Object?> _request(String operation, Object payload) {
    final port = _workerPort;
    if (port == null) return Future<Object?>.error(StateError('Payload worker is not ready.'));
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    port.send(<Object?>[id, operation, payload]);
    return completer.future;
  }

  Future<void> dispose() async {
    _workerPort?.send(const <Object?>['close']);
    _workerPort = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Payload worker was disposed.'));
      }
    }
    _pending.clear();
    await _responseSubscription?.cancel();
    _responses.close();
  }
}

bool _isWebpContainer(Uint8List bytes) {
  if (bytes.length < 20 ||
      bytes[0] != 0x52 || bytes[1] != 0x49 ||
      bytes[2] != 0x46 || bytes[3] != 0x46 ||
      bytes[8] != 0x57 || bytes[9] != 0x45 ||
      bytes[10] != 0x42 || bytes[11] != 0x50) {
    return false;
  }
  final riffSize = ByteData.sublistView(bytes).getUint32(4, Endian.little);
  final chunkSize = ByteData.sublistView(bytes).getUint32(16, Endian.little);
  final chunkName = String.fromCharCodes(bytes.sublist(12, 16));
  return riffSize == bytes.length - 8 &&
      chunkSize <= bytes.length - 20 &&
      <String>{'VP8 ', 'VP8L', 'VP8X'}.contains(chunkName);
}

void _payloadWorkerMain(SendPort parentPort) {
  final workerPort = ReceivePort();
  parentPort.send(workerPort.sendPort);
  workerPort.listen((Object? message) {
    if (message is List<Object?> && message.isNotEmpty && message.first == 'close') {
      workerPort.close();
      return;
    }
    if (message is! List<Object?> || message.length < 3 || message[0] is! int) return;
    final id = message[0] as int;
    final operation = message[1];
    final payload = message[2];
    try {
      switch (operation) {
        case 'pcm':
          final transferable = payload as TransferableTypedData;
          final pcm = transferable.materialize().asUint8List();
          if (pcm.isEmpty || pcm.length.isOdd) {
            throw const FormatException('PCM payload must contain complete S16 samples.');
          }
          parentPort.send(<Object?>[
            id,
            true,
            TransferableTypedData.fromList(<Uint8List>[pcm]),
          ]);
          break;
        case 'json':
          final decoded = jsonDecode(payload as String);
          if (decoded is! Map<String, dynamic>) {
            throw const FormatException('JSON frame must be an object.');
          }
          parentPort.send(<Object?>[id, true, decoded]);
          break;
        case 'webp':
          final arguments = payload as List<Object?>;
          final encoded = arguments[0] as String;
          final maxBytes = arguments[1] as int;
          final bytes = base64Decode(encoded);
          if (!_isWebpContainer(bytes) || bytes.length > maxBytes) {
            throw const FormatException('Snapshot payload is not a bounded WebP image.');
          }
          parentPort.send(<Object?>[
            id,
            true,
            TransferableTypedData.fromList(<Uint8List>[bytes]),
          ]);
          break;
        default:
          throw FormatException('Unknown payload worker operation: $operation');
      }
    } on Object catch (error) {
      parentPort.send(<Object?>[id, false, error.toString()]);
    }
  });
}
