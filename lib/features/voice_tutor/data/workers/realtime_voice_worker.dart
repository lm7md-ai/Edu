import 'dart:async';
import 'dart:typed_data';

import 'package:edu/features/voice_tutor/data/native/native_runtime_config.dart';
import 'package:edu/features/voice_tutor/data/workers/inference_worker_port.dart';
import 'package:edu/features/voice_tutor/data/workers/native_model_isolate_worker.dart';
import 'package:edu/features/whiteboard/domain/entities/whiteboard_sync_step.dart';
import 'package:edu/features/whiteboard/presentation/controllers/audio_synced_whiteboard_step_controller.dart';
import 'package:edu/features/whiteboard/presentation/controllers/whiteboard_canvas_controller.dart';

/// Audio boundary that preserves audio/whiteboard synchronization and FIFO
/// cancellation through the existing scheduler-backed canvas controller.
final class SynthesizedTutorStep {
  SynthesizedTutorStep({
    required this.step,
    required List<Uint8List> pcmChunks,
    required this.playback,
  }) : pcmChunks = List<Uint8List>.unmodifiable(pcmChunks);

  final WhiteboardSyncStep step;
  final List<Uint8List> pcmChunks;
  final Future<StepPlaybackResult> playback;
}

abstract interface class TutorStepPlaybackSink {
  Future<StepPlaybackResult> enqueueStep(
    WhiteboardSyncStep step,
    List<Uint8List> pcmChunks,
  );

  Future<void> bargeIn();
}

final class AudioSyncedWhiteboardPlaybackSink implements TutorStepPlaybackSink {
  const AudioSyncedWhiteboardPlaybackSink(this.controller);

  final WhiteboardCanvasController controller;

  @override
  Future<StepPlaybackResult> enqueueStep(
    WhiteboardSyncStep step,
    List<Uint8List> pcmChunks,
  ) =>
      controller.enqueueStep(
        step: step,
        pcmChunks: pcmChunks,
        sampleRateHz: 16000,
        channels: 1,
      );

  @override
  Future<void> bargeIn() => controller.bargeIn();
}

/// Silero VAD / Moonshine-or-Whisper ASR / Kokoro TTS orchestration. Each
/// native model is isolated from the UI isolate; microphone data crosses the
/// boundary as [TransferableTypedData].
final class RealTimeVoiceWorker {
  RealTimeVoiceWorker({
    required this.vadWorker,
    required this.asrWorker,
    required this.ttsWorker,
    required this.playbackSink,
    this.maxUtteranceBytes = 4 * 1024 * 1024,
    this.maxPcmBytesPerStep = 16 * 1024 * 1024,
    this.preRollFrameCount = 6,
    this.onBargeIn,
    this.onWorkerError,
  }) {
    if (maxUtteranceBytes < 2 || maxPcmBytesPerStep < 2 || preRollFrameCount < 0) {
      throw ArgumentError('Voice worker limits are invalid.');
    }
  }

  factory RealTimeVoiceWorker.fromConfigs({
    required NativeRuntimeConfig vadConfig,
    required NativeRuntimeConfig asrConfig,
    required NativeRuntimeConfig ttsConfig,
    required TutorStepPlaybackSink playbackSink,
    NativeWorkerDriver driver = NativeWorkerDriver.ffi,
    int maxUtteranceBytes = 4 * 1024 * 1024,
    int maxPcmBytesPerStep = 16 * 1024 * 1024,
    int preRollFrameCount = 6,
    void Function()? onBargeIn,
    void Function(Object error)? onWorkerError,
  }) =>
      RealTimeVoiceWorker(
        vadWorker: NativeModelIsolateWorker(config: vadConfig, driver: driver),
        asrWorker: NativeModelIsolateWorker(config: asrConfig, driver: driver),
        ttsWorker: NativeModelIsolateWorker(config: ttsConfig, driver: driver),
        playbackSink: playbackSink,
        maxUtteranceBytes: maxUtteranceBytes,
        maxPcmBytesPerStep: maxPcmBytesPerStep,
        preRollFrameCount: preRollFrameCount,
        onBargeIn: onBargeIn,
        onWorkerError: onWorkerError,
      );

  static const int sampleRateHz = 16000;
  static const int channels = 1;
  final InferenceWorkerPort vadWorker;
  final InferenceWorkerPort asrWorker;
  final InferenceWorkerPort ttsWorker;
  final TutorStepPlaybackSink playbackSink;
  final int maxUtteranceBytes;
  final int maxPcmBytesPerStep;
  final int preRollFrameCount;
  final void Function()? onBargeIn;
  final void Function(Object error)? onWorkerError;
  final Set<void Function()> _bargeInListeners = <void Function()>{};

  void addBargeInListener(void Function() listener) {
    _bargeInListeners.add(listener);
  }

  void removeBargeInListener(void Function() listener) {
    _bargeInListeners.remove(listener);
  }

  Uint8List? get lastRecognizedAudioContext =>
      _lastRecognizedAudioContext == null
          ? null
          : Uint8List.fromList(_lastRecognizedAudioContext!);

  final List<Uint8List> _preRoll = <Uint8List>[];
  final List<Uint8List> _utterance = <Uint8List>[];
  StreamSubscription<Uint8List>? _microphoneSubscription;
  Future<void> _captureTail = Future<void>.value();
  Future<void> _speechTail = Future<void>.value();
  bool _speechActive = false;
  bool _disposed = false;
  String? _activeTtsRequest;
  Uint8List? _lastRecognizedAudioContext;
  int _playbackGeneration = 0;
  int _nextRequest = 1;

  Future<void> initialize() async {
    if (_disposed) throw StateError('Real-time voice worker is disposed.');
    await Future.wait<void>(<Future<void>>[
      vadWorker.initialize(),
      asrWorker.initialize(),
      ttsWorker.initialize(),
    ]);
  }

  void listenToMicrophone(
    Stream<Uint8List> microphonePcm, {
    required void Function(String transcript) onTranscript,
  }) {
    if (_disposed) throw StateError('Real-time voice worker is disposed.');
    unawaited(_microphoneSubscription?.cancel() ?? Future<void>.value());
    _microphoneSubscription = microphonePcm.listen(
      (frame) {
        _captureTail = _captureTail.then((_) => _processFrame(frame, onTranscript)).catchError(
          (Object error, StackTrace stackTrace) => onWorkerError?.call(error),
        );
      },
      onError: (Object error, StackTrace stackTrace) => onWorkerError?.call(error),
      cancelOnError: true,
    );
  }

  Future<void> processMicrophoneFrame(
    Uint8List pcmFrame, {
    required void Function(String transcript) onTranscript,
  }) {
    final result = _captureTail.then((_) => _processFrame(pcmFrame, onTranscript));
    _captureTail = result.catchError((Object _, StackTrace __) {});
    return result;
  }

  Future<void> _processFrame(
    Uint8List frame,
    void Function(String transcript) onTranscript,
  ) async {
    if (_disposed) return;
    if (frame.isEmpty || frame.length.isOdd) {
      throw const FormatException('Microphone frames must contain 16 kHz mono S16LE samples.');
    }
    if (_speechActive) _appendBounded(_utterance, frame);

    var detectedSpeech = false;
    var detectedSilence = false;
    final requestId = 'vad-${_nextRequest++}';
    await for (final event in vadWorker.runNativeTask(
      requestId: requestId,
      task: 'silero_vad_16khz',
      audioContext: frame,
    )) {
      if (event.type == 'vad_speech' || event.type == 'speech') detectedSpeech = true;
      if (event.type == 'vad_silence' || event.type == 'silence') detectedSilence = true;
      if (event.type == 'failed') {
        throw StateError(event.error ?? 'Silero VAD failed.');
      }
    }

    if (detectedSpeech && !_speechActive) {
      _playbackGeneration++;
      _speechActive = true;
      _utterance
        ..clear()
        ..addAll(_preRoll.map(Uint8List.fromList));
      _appendBounded(_utterance, frame);
      _preRoll.clear();
      await playbackSink.bargeIn();
      onBargeIn?.call();
      for (final listener in List<void Function()>.of(_bargeInListeners)) {
        listener();
      }
      final activeTts = _activeTtsRequest;
      if (activeTts != null) await ttsWorker.interrupt(activeTts);
    } else if (_speechActive && detectedSilence) {
      _speechActive = false;
      final utterance = _joinPcm(_utterance);
      _utterance.clear();
      final transcription = _speechTail.then((_) => _transcribe(utterance, onTranscript));
      _speechTail = transcription.catchError((Object _, StackTrace __) {});
      await transcription;
    } else if (!_speechActive && preRollFrameCount > 0) {
      _preRoll.add(Uint8List.fromList(frame));
      while (_preRoll.length > preRollFrameCount) {
        _preRoll.removeAt(0);
      }
    }
  }

  Future<void> _transcribe(
    Uint8List utterance,
    void Function(String transcript) onTranscript,
  ) async {
    if (utterance.isEmpty) return;
    final requestId = 'asr-${_nextRequest++}';
    await for (final event in asrWorker.runNativeTask(
      requestId: requestId,
      task: 'moonshine_whisper_ar_en_asr',
      prompt: 'Transcribe spoken Arabic or English.',
      audioContext: utterance,
    )) {
      if (event.type == 'transcript' && event.text != null && event.text!.trim().isNotEmpty) {
        _lastRecognizedAudioContext = Uint8List.fromList(utterance);
        onTranscript(event.text!.trim());
      } else if (event.type == 'failed') {
        throw StateError(event.error ?? 'Speech recognition failed.');
      }
    }
  }

  /// Synthesizes a whiteboard step and passes its PCM chunks directly to the
  /// audio-synchronized step queue. Barge-in cancels this work and the queue.
  Future<SynthesizedTutorStep> synthesizeStep(WhiteboardSyncStep step) async {
    if (_disposed) throw StateError('Real-time voice worker is disposed.');
    final generation = _playbackGeneration;
    final requestId = 'tts-${step.stepId}-${_nextRequest++}';
    _activeTtsRequest = requestId;
    final chunks = <Uint8List>[];
    var pcmBytes = 0;
    try {
      await for (final event in ttsWorker.runNativeTask(
        requestId: requestId,
        task: 'kokoro_82m_tts_s16le_16khz',
        prompt: step.speechText,
        stepId: step.stepId,
      )) {
        if (event.type == 'audio_chunk' || event.type == 'pcm_chunk') {
          final pcm = event.pcmS16le;
          if (pcm == null || pcm.isEmpty || pcm.length.isOdd) {
            throw const FormatException('Kokoro returned an invalid S16LE PCM chunk.');
          }
          if (pcm.length > maxPcmBytesPerStep - pcmBytes) {
            throw StateError('TTS output exceeded the configured per-step PCM memory bound.');
          }
          chunks.add(pcm);
          pcmBytes += pcm.length;
        } else if (event.type == 'failed') {
          throw StateError(event.error ?? 'Kokoro speech synthesis failed.');
        }
      }
      if (generation != _playbackGeneration) throw const VoiceStepCancelled();
      if (chunks.isEmpty) throw StateError('Kokoro returned no PCM audio for step ${step.stepId}.');
      final playback = playbackSink.enqueueStep(step, chunks);
      return SynthesizedTutorStep(
        step: step,
        pcmChunks: chunks,
        playback: playback,
      );
    } finally {
      if (_activeTtsRequest == requestId) _activeTtsRequest = null;
    }
  }

  void _appendBounded(List<Uint8List> target, Uint8List frame) {
    final existingBytes = target.fold<int>(0, (sum, chunk) => sum + chunk.length);
    if (frame.length > maxUtteranceBytes - existingBytes) {
      throw StateError('Voice utterance exceeded the configured memory bound.');
    }
    target.add(Uint8List.fromList(frame));
  }

  static Uint8List _joinPcm(List<Uint8List> chunks) {
    final size = chunks.fold<int>(0, (sum, chunk) => sum + chunk.length);
    final joined = Uint8List(size);
    var offset = 0;
    for (final chunk in chunks) {
      joined.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return joined;
  }

  Future<void> bargeIn(String requestId) async {
    _playbackGeneration++;
    await playbackSink.bargeIn();
    await Future.wait<void>(<Future<void>>[
      vadWorker.interrupt(requestId),
      asrWorker.interrupt(requestId),
      ttsWorker.interrupt(_activeTtsRequest ?? requestId),
    ]);
    _activeTtsRequest = null;
    _speechActive = false;
    _utterance.clear();
    _preRoll.clear();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _playbackGeneration++;
    await _microphoneSubscription?.cancel();
    await _captureTail;
    await _speechTail;
    await playbackSink.bargeIn();
    final activeTts = _activeTtsRequest;
    if (activeTts != null) await ttsWorker.interrupt(activeTts);
    await Future.wait<void>(<Future<void>>[
      vadWorker.dispose(),
      asrWorker.dispose(),
      ttsWorker.dispose(),
    ]);
    _preRoll.clear();
    _utterance.clear();
  }
}

/// Raised when barge-in invalidates a TTS result before it reaches the queue.
final class VoiceStepCancelled implements Exception {
  const VoiceStepCancelled();
}
