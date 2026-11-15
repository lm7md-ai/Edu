import 'package:flutter/foundation.dart';

/// Native inference implementation selected for a model profile.
enum NativeModelBackend { liteRtLm, llamaCpp }

enum NativeAccelerator { automatic, npu, gpu, cpu }

enum KvCacheQuantization { f16, q4_0 }

/// Fully validated model/runtime settings passed across the FFI or platform
/// channel boundary. Model files are installed separately from the application.
@immutable
final class NativeRuntimeConfig {
  const NativeRuntimeConfig({
    required this.modelId,
    required this.modelPath,
    required this.backend,
    required this.quantization,
    required this.accelerator,
    required this.contextTokens,
    required this.grammarPath,
    this.llamaFallbackModelPath,
    this.kvCacheQuantization = KvCacheQuantization.f16,
    this.preferNpu = true,
  })  : assert(modelId != ''),
        assert(modelPath != ''),
        assert(contextTokens > 0);

  /// Host uses Gemma 4 E4B Q4_K_M, allowing the runtime to select an NPU/GPU.
  factory NativeRuntimeConfig.gemma4Host({
    required String modelPath,
    required String grammarPath,
    String? llamaFallbackModelPath,
  }) =>
      NativeRuntimeConfig(
        modelId: 'gemma-4-e4b-q4_k_m',
        modelPath: modelPath,
        backend: NativeModelBackend.liteRtLm,
        quantization: 'Q4_K_M',
        accelerator: NativeAccelerator.automatic,
        contextTokens: 8192,
        grammarPath: grammarPath,
        llamaFallbackModelPath: llamaFallbackModelPath,
        kvCacheQuantization: KvCacheQuantization.f16,
        preferNpu: true,
      );

  /// Light Edge profile trades context length and KV precision for lower RAM.
  factory NativeRuntimeConfig.gemma4LightEdge({
    required String modelPath,
    required String grammarPath,
  }) =>
      NativeRuntimeConfig(
        modelId: 'gemma-4-e2b-q4_0',
        modelPath: modelPath,
        backend: NativeModelBackend.liteRtLm,
        quantization: 'q4_0',
        accelerator: NativeAccelerator.automatic,
        contextTokens: 2048,
        grammarPath: grammarPath,
        kvCacheQuantization: KvCacheQuantization.q4_0,
        preferNpu: true,
      );

  /// llama.cpp fallback for devices without a compatible LiteRT-LM backend.
  factory NativeRuntimeConfig.llamaFallback({
    required String modelPath,
    required String grammarPath,
    int contextTokens = 4096,
  }) =>
      NativeRuntimeConfig(
        modelId: 'gemma-4-gguf-fallback',
        modelPath: modelPath,
        backend: NativeModelBackend.llamaCpp,
        quantization: 'GGUF',
        accelerator: NativeAccelerator.automatic,
        contextTokens: contextTokens,
        grammarPath: grammarPath,
        kvCacheQuantization: KvCacheQuantization.q4_0,
        preferNpu: false,
      );

  final String modelId;
  final String modelPath;
  final NativeModelBackend backend;
  final String quantization;
  final NativeAccelerator accelerator;
  final int contextTokens;
  final String grammarPath;
  final String? llamaFallbackModelPath;
  final KvCacheQuantization kvCacheQuantization;
  final bool preferNpu;

  Map<String, Object?> toJson() => <String, Object?>{
        'model_id': modelId,
        'model_path': modelPath,
        'backend': backend.name,
        'quantization': quantization,
        'accelerator': accelerator.name,
        'context_tokens': contextTokens,
        'grammar_path': grammarPath,
        'llama_fallback_model_path': llamaFallbackModelPath,
        'kv_cache_quantization': kvCacheQuantization.name,
        'prefer_npu': preferNpu,
      };

  factory NativeRuntimeConfig.fromJson(Map<String, dynamic> json) {
    final modelId = json['model_id'];
    final modelPath = json['model_path'];
    final quantization = json['quantization'];
    final contextTokens = json['context_tokens'];
    final grammarPath = json['grammar_path'];
    final fallbackPath = json['llama_fallback_model_path'];
    if (modelId is! String || modelId.trim().isEmpty ||
        modelPath is! String || modelPath.trim().isEmpty ||
        quantization is! String || quantization.trim().isEmpty ||
        contextTokens is! int || contextTokens < 1 ||
        grammarPath is! String || grammarPath.trim().isEmpty ||
        (fallbackPath != null && (fallbackPath is! String || fallbackPath.trim().isEmpty))) {
      throw const FormatException('Native runtime configuration is invalid.');
    }
    return NativeRuntimeConfig(
      modelId: modelId,
      modelPath: modelPath,
      backend: _enumValue(NativeModelBackend.values, json['backend'], 'backend'),
      quantization: quantization,
      accelerator: _enumValue(
        NativeAccelerator.values,
        json['accelerator'],
        'accelerator',
      ),
      contextTokens: contextTokens,
      grammarPath: grammarPath,
      llamaFallbackModelPath: fallbackPath as String?,
      kvCacheQuantization: _enumValue(
        KvCacheQuantization.values,
        json['kv_cache_quantization'],
        'kv_cache_quantization',
      ),
      preferNpu: json['prefer_npu'] == true,
    );
  }
}

T _enumValue<T extends Enum>(List<T> values, Object? name, String field) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  throw FormatException('Native runtime field "$field" is invalid.');
}
