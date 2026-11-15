import 'dart:typed_data';

import 'package:edu/features/voice_tutor/data/native/native_runtime_config.dart';

/// Inputs to native token/audio generation. Audio and WebP stay binary until
/// the native boundary; isolate transports use [TransferableTypedData].
final class NativeGenerationRequest {
  const NativeGenerationRequest({
    required this.requestId,
    required this.prompt,
    this.audioContext,
    this.webpSnapshot,
    this.task = 'generate',
    this.stepId,
  });

  final String requestId;
  final String prompt;
  final Uint8List? audioContext;
  final Uint8List? webpSnapshot;
  final String task;
  final int? stepId;
}

/// Typed event returned from a native runtime session.
final class NativeRuntimeEvent {
  const NativeRuntimeEvent({
    required this.requestId,
    required this.type,
    this.text,
    this.pcmS16le,
    this.embedding,
    this.stepId,
    this.error,
  });

  final String requestId;
  final String type;
  final String? text;
  final Uint8List? pcmS16le;
  final Float32List? embedding;
  final int? stepId;
  final String? error;

  factory NativeRuntimeEvent.fromJson(Map<String, dynamic> json) {
    final requestId = json['request_id'];
    final type = json['type'];
    final text = json['text'];
    final stepId = json['step_id'];
    final error = json['error'];
    if (requestId is! String || type is! String ||
        (text != null && text is! String) ||
        (stepId != null && stepId is! int) ||
        (error != null && error is! String)) {
      throw const FormatException('Native runtime event has invalid fields.');
    }
    final rawPcm = json['pcm_s16le'];
    Uint8List? pcm;
    if (rawPcm != null) {
      if (rawPcm is! List<int>) {
        throw const FormatException('Native runtime PCM event is invalid.');
      }
      pcm = Uint8List.fromList(rawPcm);
    }
    final rawEmbedding = json['embedding'];
    Float32List? embedding;
    if (rawEmbedding != null) {
      if (rawEmbedding is! List<dynamic> || rawEmbedding.any((value) => value is! num)) {
        throw const FormatException('Native runtime embedding event is invalid.');
      }
      embedding = Float32List.fromList(
        rawEmbedding.map((value) => (value as num).toDouble()).toList(growable: false),
      );
    }
    return NativeRuntimeEvent(
      requestId: requestId,
      type: type,
      text: text as String?,
      pcmS16le: pcm,
      embedding: embedding,
      stepId: stepId as int?,
      error: error as String?,
    );
  }
}

/// A loaded model handle. Implementations own KV-cache state and all native
/// memory until [close] completes.
abstract interface class NativeModelSession {
  NativeRuntimeConfig get config;

  Stream<NativeRuntimeEvent> generate(NativeGenerationRequest request);

  Future<void> cancel(String requestId);

  Future<void> close();
}

/// Runtime boundary implemented by FFI and Android platform-channel drivers.
abstract interface class NativeRuntimeBridge {
  Future<NativeModelSession> open(NativeRuntimeConfig config);

  Future<bool> isBackendAvailable(NativeModelBackend backend);
}
