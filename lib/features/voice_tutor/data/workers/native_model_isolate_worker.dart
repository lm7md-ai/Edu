import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:edu/core/errors/app_failure.dart';
import 'package:edu/features/voice_tutor/data/native/ffi_native_runtime_bridge.dart';
import 'package:edu/features/voice_tutor/data/native/method_channel_native_runtime_bridge.dart';
import 'package:edu/features/voice_tutor/data/native/native_runtime_bridge.dart';
import 'package:edu/features/voice_tutor/data/native/native_runtime_config.dart';
import 'package:edu/features/voice_tutor/data/workers/inference_worker_port.dart';
import 'package:edu/features/voice_tutor/domain/entities/tutor_engine_event.dart';
import 'package:edu/features/voice_tutor/domain/entities/tutor_prompt.dart';
import 'package:edu/features/voice_tutor/data/workers/streaming_whiteboard_json_parser.dart';
import 'package:edu/features/whiteboard/domain/entities/whiteboard_sync_step.dart';
import 'package:flutter/services.dart';

/// Selects the worker-isolate driver. Android uses its registered JNI channel;
/// other native platforms load the FFI C ABI directly.
enum NativeWorkerDriver { ffi, androidMethodChannel }

/// Owns one model session in a background isolate. No native model handle,
/// model loading call, inference polling, JSON step parsing, or KV-cache
/// teardown runs on the caller's isolate.
final class NativeModelIsolateWorker implements InferenceWorkerPort {
  NativeModelIsolateWorker({
    required this.config,
    this.driver = NativeWorkerDriver.ffi,
  });

  final NativeRuntimeConfig config;
  final NativeWorkerDriver driver;
  late ReceivePort _responses;
  late Completer<void> _ready;
  StreamSubscription<Object?>? _responseSubscription;
  Isolate? _isolate;
  SendPort? _commands;
  bool _disposed = false;
  bool _permanentlyDisposed = false;
  int _nextRequestId = 1;

  @override
  bool get isInitialized =>
      _isolate != null && _ready.isCompleted && !_disposed && !_permanentlyDisposed;

  @override
  Future<void> initialize() async {
    if (_permanentlyDisposed) throw StateError('Native inference worker is disposed.');
    if (_isolate != null) return _ready.future;
    _disposed = false;
    _responses = ReceivePort();
    _ready = Completer<void>();
    _responseSubscription = _responses.listen(_onWorkerMessage);
    final token = driver == NativeWorkerDriver.androidMethodChannel
        ? RootIsolateToken.instance
        : null;
    if (driver == NativeWorkerDriver.androidMethodChannel && token == null) {
      throw StateError('Android platform-channel worker requires a root isolate token.');
    }
    _isolate = await Isolate.spawn<List<Object?>>(
      _nativeModelWorkerMain,
      <Object?>[
        _responses.sendPort,
        config.toJson(),
        driver.name,
        token,
      ],
      debugName: 'native-model-${config.modelId}',
      onError: _responses.sendPort,
      onExit: _responses.sendPort,
    );
    try {
      await _ready.future;
    } on Object {
      _isolate?.kill(priority: Isolate.immediate);
      _isolate = null;
      _commands = null;
      await _responseSubscription?.cancel();
      _responses.close();
      rethrow;
    }
  }

  void _onWorkerMessage(Object? message) {
    if (message is SendPort) {
      _commands = message;
      return;
    }
    if (message == null) {
      if (!_ready.isCompleted) {
        _ready.completeError(StateError('Native inference worker exited unexpectedly.'));
      }
      return;
    }
    if (message is List<Object?> && message.isNotEmpty) {
      switch (message.first) {
        case 'ready':
          if (!_ready.isCompleted) _ready.complete();
          break;
        case 'init_error':
          if (!_ready.isCompleted) {
            _ready.completeError(StateError('${message.length > 1 ? message[1] : 'Worker initialization failed.'}'));
          }
          break;
        default:
          if (!_ready.isCompleted) {
            _ready.completeError(StateError('Native inference worker error: $message'));
          }
      }
      return;
    }
  }

  @override
  Stream<TutorEngineEvent> runTutorPrompt(
    TutorPrompt prompt, {
    Uint8List? audioContext,
    Uint8List? webpSnapshot,
  }) async* {
    await initialize();
    final commands = _commands;
    if (_disposed || _permanentlyDisposed || commands == null) {
      throw StateError('Native model worker is unavailable.');
    }
    final requestId = '${prompt.requestId}-${_nextRequestId++}';
    final events = ReceivePort();
    commands.send(<Object?>[
      'tutor',
      requestId,
      prompt.requestId,
      prompt.text,
      _transfer(audioContext),
      _transfer(webpSnapshot),
      events.sendPort,
    ]);
    try {
      await for (final message in events) {
        if (message is! List<Object?> || message.isEmpty) continue;
        switch (message[0]) {
          case 'tutor_event':
            final eventMap = message[1];
            if (eventMap is Map<String, dynamic>) {
              yield _tutorEventFromJson(eventMap);
            }
            break;
          case 'error':
            yield TutorTurnFailed(
              requestId: prompt.requestId,
              failure: EngineFailure('Native Gemma generation failed.', cause: message.length > 1 ? message[1] : null),
            );
            return;
          case 'done':
            return;
        }
      }
    } finally {
      events.close();
    }
  }

  @override
  Stream<NativeRuntimeEvent> runNativeTask({
    required String requestId,
    required String task,
    String prompt = '',
    Uint8List? audioContext,
    int? stepId,
  }) async* {
    await initialize();
    final commands = _commands;
    if (_disposed || _permanentlyDisposed || commands == null) {
      throw StateError('Native model worker is unavailable.');
    }
    final uniqueId = '$requestId-${_nextRequestId++}';
    final events = ReceivePort();
    commands.send(<Object?>[
      'native',
      uniqueId,
      requestId,
      task,
      prompt,
      _transfer(audioContext),
      stepId,
      events.sendPort,
    ]);
    try {
      await for (final message in events) {
        if (message is! List<Object?> || message.isEmpty) continue;
        switch (message[0]) {
          case 'native_event':
            final json = message[1];
            final pcm = message.length > 2 ? message[2] : null;
            if (json is Map<String, dynamic>) {
              if (pcm is TransferableTypedData) {
                json['pcm_s16le'] = pcm.materialize().asUint8List();
              }
              yield NativeRuntimeEvent.fromJson(json);
            }
            break;
          case 'error':
            throw StateError('${message.length > 1 ? message[1] : 'Native worker task failed.'}');
          case 'done':
            return;
        }
      }
    } finally {
      events.close();
    }
  }

  static TransferableTypedData? _transfer(Uint8List? bytes) =>
      bytes == null ? null : TransferableTypedData.fromList(<Uint8List>[bytes]);

  static TutorEngineEvent _tutorEventFromJson(Map<String, dynamic> json) {
    final type = json['type'];
    final requestId = json['request_id'];
    if (type is! String || requestId is! String) {
      throw const FormatException('Worker tutor event is malformed.');
    }
    switch (type) {
      case 'text_delta':
        final text = json['text'];
        if (text is! String) throw const FormatException('Worker text delta is malformed.');
        return TutorTextDelta(requestId: requestId, text: text);
      case 'whiteboard_step':
        final stepJson = json['step'];
        if (stepJson is! Map<String, dynamic>) {
          throw const FormatException('Worker whiteboard step is malformed.');
        }
        return TutorWhiteboardStepEvent(
          requestId: requestId,
          step: WhiteboardSyncStep.fromJson(stepJson),
        );
      case 'completed':
        return TutorTurnCompleted(requestId: requestId);
      case 'failed':
        return TutorTurnFailed(
          requestId: requestId,
          failure: EngineFailure(json['message'] is String ? json['message'] as String : 'Native generation failed.'),
        );
      default:
        throw FormatException('Unknown worker tutor event type: $type');
    }
  }

  @override
  Future<void> interrupt(String requestId) async {
    if (!_disposed && !_permanentlyDisposed) {
      _commands?.send(<Object?>['cancel', requestId]);
    }
  }

  @override
  Future<void> unload() async {
    if (_isolate == null) {
      _disposed = false;
      return;
    }
    _disposed = true;
    final commands = _commands;
    if (commands != null) {
      final exited = Completer<void>();
      final exitPort = ReceivePort();
      exitPort.listen((_) {
        if (!exited.isCompleted) exited.complete();
      });
      commands.send(<Object?>['close', exitPort.sendPort]);
      await exited.future.timeout(const Duration(seconds: 10), onTimeout: () {});
      exitPort.close();
    }
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _commands = null;
    await _responseSubscription?.cancel();
    _responseSubscription = null;
    _responses.close();
    _disposed = false;
  }

  @override
  Future<void> dispose() async {
    if (_permanentlyDisposed) return;
    await unload();
    _permanentlyDisposed = true;
  }
}

void _nativeModelWorkerMain(List<Object?> bootstrap) {
  final parent = bootstrap[0] as SendPort;
  final configJson = Map<String, dynamic>.from(bootstrap[1] as Map<dynamic, dynamic>);
  final driver = NativeWorkerDriver.values.byName(bootstrap[2] as String);
  final rootToken = bootstrap[3] as RootIsolateToken?;
  final commands = ReceivePort();
  parent.send(commands.sendPort);

  unawaited(_runNativeModelWorker(parent, commands, configJson, driver, rootToken));
}

Future<void> _runNativeModelWorker(
  SendPort parent,
  ReceivePort commands,
  Map<String, dynamic> configJson,
  NativeWorkerDriver driver,
  RootIsolateToken? rootToken,
) async {
  try {
    if (driver == NativeWorkerDriver.androidMethodChannel) {
      BackgroundIsolateBinaryMessenger.ensureInitialized(rootToken!);
    }
    final NativeRuntimeBridge bridge = driver == NativeWorkerDriver.androidMethodChannel
        ? MethodChannelNativeRuntimeBridge()
        : FfiNativeRuntimeBridge();
    final config = NativeRuntimeConfig.fromJson(configJson);
    final session = await bridge.open(config);
    parent.send(<Object?>['ready']);
    await for (final message in commands) {
      if (message is! List<Object?> || message.isEmpty) continue;
      switch (message[0]) {
        case 'tutor':
          unawaited(_runTutorCommand(session, message));
          break;
        case 'native':
          unawaited(_runNativeCommand(session, message));
          break;
        case 'cancel':
          if (message.length > 1 && message[1] is String) {
            await session.cancel(message[1] as String);
          }
          break;
        case 'close':
          await session.close();
          final exitPort = message.length > 1 ? message[1] as SendPort : null;
          exitPort?.send(true);
          commands.close();
          Isolate.exit();
      }
    }
  } on Object catch (error, stackTrace) {
    parent.send(<Object?>['init_error', '$error\n$stackTrace']);
    commands.close();
    Isolate.exit();
  }
}

Future<void> _runTutorCommand(NativeModelSession session, List<Object?> message) async {
  final workerResponse = message[6] as SendPort;
  final request = NativeGenerationRequest(
    requestId: message[2] as String,
    prompt: message[3] as String,
    audioContext: _materialize(message[4]),
    webpSnapshot: _materialize(message[5]),
    task: 'multimodal_gemma',
  );
  final parser = StreamingWhiteboardJsonParser();
  try {
    await for (final event in session.generate(request)) {
      if (event.type == 'token' || event.type == 'text_delta' || event.type == 'whiteboard_json') {
        final text = event.text ?? '';
        if (event.type != 'whiteboard_json' && text.isNotEmpty) {
          workerResponse.send(<Object?>[
            'tutor_event',
            <String, Object?>{
              'type': 'text_delta',
              'request_id': request.requestId,
              'text': text,
            },
          ]);
        }
        for (final step in parser.addChunk(text)) {
          workerResponse.send(<Object?>[
            'tutor_event',
            <String, Object?>{
              'type': 'whiteboard_step',
              'request_id': request.requestId,
              'step': step.toJson(),
            },
          ]);
        }
      } else if (event.type == 'failed') {
        workerResponse.send(<Object?>[
          'tutor_event',
          <String, Object?>{
            'type': 'failed',
            'request_id': request.requestId,
            'message': event.error ?? 'Native model generation failed.',
          },
        ]);
        workerResponse.send(const <Object?>['done']);
        return;
      } else if (event.type == 'completed') {
        parser.finish();
        workerResponse.send(<Object?>[
          'tutor_event',
          <String, Object?>{'type': 'completed', 'request_id': request.requestId},
        ]);
        workerResponse.send(const <Object?>['done']);
        return;
      }
    }
    parser.finish();
    workerResponse.send(<Object?>[
      'tutor_event',
      <String, Object?>{'type': 'completed', 'request_id': request.requestId},
    ]);
    workerResponse.send(const <Object?>['done']);
  } on Object catch (error) {
    workerResponse.send(<Object?>['error', error.toString()]);
  }
}

Future<void> _runNativeCommand(NativeModelSession session, List<Object?> message) async {
  final workerResponse = message[7] as SendPort;
  final request = NativeGenerationRequest(
    requestId: message[2] as String,
    task: message[3] as String,
    prompt: message[4] as String,
    audioContext: _materialize(message[5]),
    stepId: message[6] as int?,
  );
  try {
    await for (final event in session.generate(request)) {
      final json = <String, Object?>{
        'request_id': event.requestId,
        'type': event.type,
        'text': event.text,
        'step_id': event.stepId,
        'error': event.error,
        'embedding': event.embedding?.toList(growable: false),
      };
      final pcm = event.pcmS16le;
      workerResponse.send(<Object?>[
        'native_event',
        json,
        if (pcm != null) TransferableTypedData.fromList(<Uint8List>[pcm]),
      ]);
      if (event.type == 'completed' || event.type == 'failed') break;
    }
    workerResponse.send(const <Object?>['done']);
  } on Object catch (error) {
    workerResponse.send(<Object?>['error', error.toString()]);
  }
}

Uint8List? _materialize(Object? value) {
  if (value == null) return null;
  if (value is! TransferableTypedData) throw const FormatException('Worker binary request is invalid.');
  return value.materialize().asUint8List();
}
