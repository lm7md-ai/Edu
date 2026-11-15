import 'dart:typed_data';

import 'package:edu/features/voice_tutor/data/workers/realtime_voice_worker.dart';
import 'package:edu/features/whiteboard/domain/entities/whiteboard_sync_step.dart';
import 'package:edu/features/whiteboard/presentation/controllers/audio_synced_whiteboard_step_controller.dart';

/// A deliberately idle clock for the pre-audio setup state. It never advances
/// from wall time and never claims that samples were played.
final class IdleAudioPlaybackClock implements AudioPlaybackClock {
  const IdleAudioPlaybackClock();

  @override
  int get playedFramePosition => 0;

  @override
  int get sampleRateHz => 16000;
}

/// Safe pre-install scheduler: drawing and navigation remain usable, but an
/// attempted tutor audio step fails clearly instead of using a fake timer.
final class UnavailablePcmStepScheduler implements PcmStepScheduler {
  const UnavailablePcmStepScheduler();

  @override
  AudioPlaybackClock get clock => const IdleAudioPlaybackClock();

  @override
  Future<AudioPlaybackWindow> scheduleStep({
    required int stepId,
    required List<Uint8List> pcmChunks,
    required int sampleRateHz,
    required int channels,
    required int notBeforeFrame,
  }) => Future<AudioPlaybackWindow>.error(
        StateError('Audio playback is not configured on this installation.'),
      );

  @override
  Future<void> flush() async {}
}

/// Sink used when the app is composed without an attached whiteboard. It does
/// not discard or pretend to play PCM: it reports an actionable setup error.
final class UnavailableTutorStepPlaybackSink implements TutorStepPlaybackSink {
  const UnavailableTutorStepPlaybackSink();

  @override
  Future<StepPlaybackResult> enqueueStep(
    WhiteboardSyncStep step,
    List<Uint8List> pcmChunks,
  ) =>
      Future<StepPlaybackResult>.error(
        StateError('Audio-synchronized whiteboard playback is not configured.'),
      );

  @override
  Future<void> bargeIn() async {}
}
