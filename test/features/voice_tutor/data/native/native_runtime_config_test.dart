import 'package:edu/features/voice_tutor/data/native/native_runtime_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const grammar = 'assets/grammar/whiteboard.gbnf';

  test('host selects Gemma 4 E4B Q4_K_M and retains a GGUF fallback path', () {
    final host = NativeRuntimeConfig.gemma4Host(
      modelPath: '/models/gemma-4-e4b.litertlm',
      grammarPath: grammar,
      llamaFallbackModelPath: '/models/gemma-4-e4b-q4_k_m.gguf',
    );

    expect(host.modelId, 'gemma-4-e4b-q4_k_m');
    expect(host.backend, NativeModelBackend.liteRtLm);
    expect(host.quantization, 'Q4_K_M');
    expect(host.accelerator, NativeAccelerator.automatic);
    expect(host.preferNpu, isTrue);
    expect(host.contextTokens, greaterThan(2048));
    expect(host.llamaFallbackModelPath, '/models/gemma-4-e4b-q4_k_m.gguf');
    expect(
      NativeRuntimeConfig.fromJson(Map<String, dynamic>.from(host.toJson())).modelId,
      host.modelId,
    );
  });

  test('Light Edge uses Gemma 4 E2B with q4_0 KV cache and smaller context', () {
    final edge = NativeRuntimeConfig.gemma4LightEdge(
      modelPath: '/models/gemma-4-e2b.litertlm',
      grammarPath: grammar,
    );

    expect(edge.modelId, 'gemma-4-e2b-q4_0');
    expect(edge.quantization, 'q4_0');
    expect(edge.kvCacheQuantization, KvCacheQuantization.q4_0);
    expect(edge.contextTokens, 2048);
    expect(edge.contextTokens, lessThan(NativeRuntimeConfig.gemma4Host(
      modelPath: '/models/host.litertlm',
      grammarPath: grammar,
    ).contextTokens));
  });
}
