import 'package:edu/features/whiteboard/domain/entities/whiteboard_sync_step.dart';
import 'package:meta/meta.dart';

/// A persistent, target-addressable element on the canonical whiteboard.
@immutable
final class BoardElement {
  const BoardElement._({
    required this.targetId,
    required this.action,
    required this.highlighted,
    required this.highlightAction,
  });

  factory BoardElement.fromAction(WhiteboardAction action) {
    final targetId = action.targetId;
    if (targetId == null ||
        action.operation == WhiteboardOperation.highlight ||
        action.operation == WhiteboardOperation.clear) {
      throw ArgumentError.value(action, 'action', 'Action cannot create a board element.');
    }
    return BoardElement._(
      targetId: targetId,
      action: action,
      highlighted: false,
      highlightAction: null,
    );
  }

  final String targetId;
  final WhiteboardAction action;
  final bool highlighted;
  final WhiteboardAction? highlightAction;

  BoardElement withHighlight(WhiteboardAction highlight) => BoardElement._(
        targetId: targetId,
        action: action,
        highlighted: true,
        highlightAction: highlight,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'target_id': targetId,
        'element': action.toJson(),
        'highlighted': highlighted,
        'highlight': highlightAction?.toJson(),
      };
}
