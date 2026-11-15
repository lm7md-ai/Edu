import 'dart:typed_data';

import 'package:edu/features/voice_tutor/data/native/native_runtime_bridge.dart';
import 'package:edu/features/voice_tutor/domain/entities/tutor_engine_event.dart';
import 'package:edu/features/voice_tutor/domain/entities/tutor_prompt.dart';

/// Isolate-owned inference operations exposed to engines and voice control.
abstract interface class InferenceWorkerPort {
  bool get isInitialized;

  Future<void> initialize();

  Stream<TutorEngineEvent> runTutorPrompt(
    TutorPrompt prompt, {
    Uint8List? audioContext,
    Uint8List? webpSnapshot,
  });

  Stream<NativeRuntimeEvent> runNativeTask({
    required String requestId,
    required String task,
    String prompt = '',
    Uint8List? audioContext,
    int? stepId,
  });

  Future<void> interrupt(String requestId);

  Future<void> unload();

  Future<void> dispose();
}
