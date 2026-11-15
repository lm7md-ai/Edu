import 'package:edu/features/voice_tutor/domain/entities/tutor_engine_event.dart';
import 'package:edu/features/voice_tutor/domain/entities/tutor_prompt.dart';

/// Domain boundary for any local or LAN-backed tutor execution engine.
///
/// Implementations emit ordered events on [events]. [submit] accepts a prompt
/// for processing; the result arrives as text/whiteboard events followed by a
/// terminal completion or failure event. [interrupt] must stop active
/// generation and speech promptly and prevent stale events for the interrupted
/// turn from being emitted afterward.
abstract interface class TutorEngineRepository {
  Stream<TutorEngineEvent> get events;

  /// Loads or connects the selected engine and becomes idempotently ready.
  Future<void> initialize();

  /// Starts handling [prompt]. Implementations must reject calls before
  /// initialization and must not block the caller's UI isolate with inference.
  Future<void> submit(TutorPrompt prompt);

  /// Cancels active generation and audio playback, if any.
  Future<void> interrupt();

  /// Releases native handles, streams, sockets, and other owned resources.
  Future<void> dispose();
}
