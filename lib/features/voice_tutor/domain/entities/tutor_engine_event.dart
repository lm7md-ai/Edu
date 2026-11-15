import 'package:edu/core/errors/app_failure.dart';
import 'package:edu/features/whiteboard/domain/entities/whiteboard_sync_step.dart';
import 'package:meta/meta.dart';

/// Events emitted by a tutor engine while it handles a prompt.
sealed class TutorEngineEvent {
  const TutorEngineEvent({required this.requestId});

  final String requestId;
}

@immutable
final class TutorTextDelta extends TutorEngineEvent {
  const TutorTextDelta({required super.requestId, required this.text});

  final String text;
}

@immutable
final class TutorWhiteboardStepEvent extends TutorEngineEvent {
  const TutorWhiteboardStepEvent({
    required super.requestId,
    required this.step,
  });

  final WhiteboardSyncStep step;
}

@immutable
final class TutorTurnCompleted extends TutorEngineEvent {
  const TutorTurnCompleted({required super.requestId});
}

@immutable
final class TutorTurnFailed extends TutorEngineEvent {
  const TutorTurnFailed({required super.requestId, required this.failure});

  final AppFailure failure;
}
