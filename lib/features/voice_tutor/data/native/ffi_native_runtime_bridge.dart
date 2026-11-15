import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:edu/features/voice_tutor/data/native/native_runtime_bridge.dart';
import 'package:edu/features/voice_tutor/data/native/native_runtime_config.dart';

/// C-ABI driver for `libedu_tutor_runtime.so`.
///
/// The companion native runtime library must export the `edu_runtime_*` ABI
/// declared in `android/app/src/main/cpp/edu_tutor_runtime_abi.h`. Calls are intended
/// to run from an inference worker isolate because open, generation polling,
/// and model teardown may block while the native runtime manages NPU/GPU state.
final class FfiNativeRuntimeBridge implements NativeRuntimeBridge {
  FfiNativeRuntimeBridge({String? libraryPath})
      : _library = DynamicLibrary.open(
          libraryPath ?? _defaultLibraryName,
        ) {
    _open = _library.lookupFunction<_OpenNative, _OpenDart>('edu_runtime_open');
    _close = _library.lookupFunction<_CloseNative, _CloseDart>('edu_runtime_close');
    _startGeneration = _library.lookupFunction<_StartNative, _StartDart>(
      'edu_runtime_start_generation',
    );
    _nextEvent = _library.lookupFunction<_NextEventNative, _NextEventDart>(
      'edu_runtime_next_event',
    );
    _cancelGeneration = _library.lookupFunction<_CancelNative, _CancelDart>(
      'edu_runtime_cancel_generation',
    );
    _freeEvent = _library.lookupFunction<_FreeEventNative, _FreeEventDart>(
      'edu_runtime_free_event',
    );
    _backendAvailable = _library.lookupFunction<
        _BackendAvailableNative,
        _BackendAvailableDart>('edu_runtime_backend_available');
  }

  static String get _defaultLibraryName => Platform.isAndroid
      ? 'libedu_tutor_runtime.so'
      : Platform.isMacOS
          ? 'libedu_tutor_runtime.dylib'
          : Platform.isWindows
              ? 'edu_tutor_runtime.dll'
              : 'libedu_tutor_runtime.so';

  final DynamicLibrary _library;
  late final _OpenDart _open;
  late final _CloseDart _close;
  late final _StartDart _startGeneration;
  late final _NextEventDart _nextEvent;
  late final _CancelDart _cancelGeneration;
  late final _FreeEventDart _freeEvent;
  late final _BackendAvailableDart _backendAvailable;

  @override
  Future<bool> isBackendAvailable(NativeModelBackend backend) async =>
      _backendAvailable(backend.index) != 0;

  @override
  Future<NativeModelSession> open(NativeRuntimeConfig config) async {
    final nativeJson = jsonEncode(config.toJson()).toNativeUtf8();
    try {
      final handle = _open(nativeJson);
      if (handle.address == 0) {
        throw StateError('Native runtime rejected model profile ${config.modelId}.');
      }
      return _FfiNativeModelSession(
        config: config,
        handle: handle,
        startGeneration: _startGeneration,
        nextEvent: _nextEvent,
        cancelGeneration: _cancelGeneration,
        freeEvent: _freeEvent,
        closeNative: _close,
      );
    } finally {
      malloc.free(nativeJson);
    }
  }
}

final class _FfiNativeModelSession implements NativeModelSession {
  _FfiNativeModelSession({
    required this.config,
    required Pointer<Void> handle,
    required _StartDart startGeneration,
    required _NextEventDart nextEvent,
    required _CancelDart cancelGeneration,
    required _FreeEventDart freeEvent,
    required _CloseDart closeNative,
  })  : _handle = handle,
        _startGeneration = startGeneration,
        _nextEvent = nextEvent,
        _cancelGeneration = cancelGeneration,
        _freeEvent = freeEvent,
        _closeNative = closeNative;

  @override
  final NativeRuntimeConfig config;
  Pointer<Void> _handle;
  final _StartDart _startGeneration;
  final _NextEventDart _nextEvent;
  final _CancelDart _cancelGeneration;
  final _FreeEventDart _freeEvent;
  final _CloseDart _closeNative;
  final Map<String, int> _activeJobs = <String, int>{};
  bool _closed = false;

  @override
  Stream<NativeRuntimeEvent> generate(NativeGenerationRequest request) async* {
    final handle = _requireHandle();
    final requestJson = jsonEncode(<String, Object?>{
      'request_id': request.requestId,
      'task': request.task,
      'prompt': request.prompt,
      'step_id': request.stepId,
      if (request.audioContext != null)
        'audio_context_base64': base64Encode(request.audioContext!),
      if (request.webpSnapshot != null)
        'webp_snapshot_base64': base64Encode(request.webpSnapshot!),
    }).toNativeUtf8();
    late final int jobId;
    try {
      jobId = _startGeneration(handle, requestJson);
    } finally {
      malloc.free(requestJson);
    }
    if (jobId < 0) throw StateError('Native runtime could not start generation.');
    _activeJobs[request.requestId] = jobId;
    var terminal = false;
    try {
      while (!_closed && !terminal) {
        final eventPointer = _nextEvent(handle, jobId, 50);
        if (eventPointer.address == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
          continue;
        }
        late final String eventJson;
        try {
          eventJson = eventPointer.toDartString();
        } finally {
          _freeEvent(eventPointer);
        }
        final decoded = jsonDecode(eventJson);
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('Native runtime returned a malformed event.');
        }
        final event = NativeRuntimeEvent.fromJson(decoded);
        terminal = event.type == 'completed' || event.type == 'failed';
        yield event;
      }
    } finally {
      _activeJobs.remove(request.requestId);
      if (!terminal && !_closed && _handle.address != 0) {
        _cancelGeneration(_handle, jobId);
      }
    }
  }

  @override
  Future<void> cancel(String requestId) async {
    if (_closed || _handle.address == 0) return;
    final jobId = _activeJobs[requestId];
    if (jobId != null) _cancelGeneration(_handle, jobId);
  }

  Pointer<Void> _requireHandle() {
    if (_closed || _handle.address == 0) throw StateError('Native model session is closed.');
    return _handle;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final handle = _handle;
    if (handle.address != 0) {
      for (final jobId in _activeJobs.values.toList(growable: false)) {
        _cancelGeneration(handle, jobId);
      }
      _closeNative(handle);
      _handle = Pointer<Void>.fromAddress(0);
    }
  }
}

typedef _OpenNative = Pointer<Void> Function(Pointer<Utf8>);
typedef _OpenDart = Pointer<Void> Function(Pointer<Utf8>);
typedef _CloseNative = Void Function(Pointer<Void>);
typedef _CloseDart = void Function(Pointer<Void>);
typedef _StartNative = Int64 Function(Pointer<Void>, Pointer<Utf8>);
typedef _StartDart = int Function(Pointer<Void>, Pointer<Utf8>);
typedef _NextEventNative = Pointer<Utf8> Function(Pointer<Void>, Int64, Int32);
typedef _NextEventDart = Pointer<Utf8> Function(Pointer<Void>, int, int);
typedef _CancelNative = Int32 Function(Pointer<Void>, Int64);
typedef _CancelDart = int Function(Pointer<Void>, int);
typedef _FreeEventNative = Void Function(Pointer<Utf8>);
typedef _FreeEventDart = void Function(Pointer<Utf8>);
typedef _BackendAvailableNative = Int32 Function(Int32);
typedef _BackendAvailableDart = int Function(int);
