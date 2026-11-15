import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:edu/features/voice_tutor/data/native/native_runtime_bridge.dart';
import 'package:edu/features/voice_tutor/data/native/native_runtime_config.dart';

/// Flutter MethodChannel bridge used by Android's JNI-backed runtime host.
/// Native generation events are polled with bounded timeouts so multiple model
/// isolates can share one Android engine without competing EventChannel sinks.
final class MethodChannelNativeRuntimeBridge implements NativeRuntimeBridge {
  MethodChannelNativeRuntimeBridge({MethodChannel? methods})
      : _methods = methods ?? const MethodChannel('edu/native_runtime');

  final MethodChannel _methods;
  int _nextRequest = 1;

  @override
  Future<bool> isBackendAvailable(NativeModelBackend backend) async {
    final available = await _methods.invokeMethod<bool>(
      'isBackendAvailable',
      <String, Object?>{'backend': backend.name},
    );
    return available ?? false;
  }

  @override
  Future<NativeModelSession> open(NativeRuntimeConfig config) async {
    final sessionId = await _methods.invokeMethod<String>(
      'openModel',
      config.toJson(),
    );
    if (sessionId == null || sessionId.isEmpty) {
      throw StateError('Android native runtime returned no model session id.');
    }
    return _MethodChannelModelSession(
      config: config,
      sessionId: sessionId,
      methods: _methods,
      nextRequestId: () => _nextRequest++,
    );
  }
}

final class _MethodChannelModelSession implements NativeModelSession {
  _MethodChannelModelSession({
    required this.config,
    required this.sessionId,
    required MethodChannel methods,
    required int Function() nextRequestId,
  })  : _methods = methods,
        _nextRequestId = nextRequestId;

  @override
  final NativeRuntimeConfig config;
  final String sessionId;
  final MethodChannel _methods;
  final int Function() _nextRequestId;
  final Set<String> _activeRequests = <String>{};
  bool _closed = false;

  @override
  Stream<NativeRuntimeEvent> generate(NativeGenerationRequest request) async* {
    if (_closed) throw StateError('Native model session is closed.');
    final generationId = '${request.requestId}-${_nextRequestId()}';
    final arguments = <String, Object?>{
      'session_id': sessionId,
      'generation_id': generationId,
      'request_id': request.requestId,
      'task': request.task,
      'prompt': request.prompt,
      'step_id': request.stepId,
      if (request.audioContext != null)
        'audio_context_base64': base64Encode(request.audioContext!),
      if (request.webpSnapshot != null)
        'webp_snapshot_base64': base64Encode(request.webpSnapshot!),
    };
    await _methods.invokeMethod<void>('startGeneration', arguments);
    _activeRequests.add(request.requestId);
    var terminal = false;
    try {
      while (!_closed && !terminal) {
        final raw = await _methods.invokeMethod<Object?>(
          'pollEvent',
          <String, Object?>{
            'session_id': sessionId,
            'request_id': request.requestId,
            'generation_id': generationId,
            'timeout_ms': 100,
          },
        );
        if (raw == null) continue;
        if (raw is! Map) {
          throw const FormatException('Android runtime returned a malformed generation event.');
        }
        final eventJson = Map<String, dynamic>.from(raw);
        eventJson['request_id'] = request.requestId;
        final event = NativeRuntimeEvent.fromJson(eventJson);
        terminal = event.type == 'completed' || event.type == 'failed';
        yield event;
      }
    } finally {
      _activeRequests.remove(request.requestId);
      if (!terminal && !_closed) await cancel(request.requestId);
    }
  }

  @override
  Future<void> cancel(String requestId) async {
    if (_closed || !_activeRequests.contains(requestId)) return;
    await _methods.invokeMethod<void>('cancelGeneration', <String, Object?>{
      'session_id': sessionId,
      'request_id': requestId,
    });
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _methods.invokeMethod<void>('closeModel', <String, Object?>{
      'session_id': sessionId,
    });
  }
}
