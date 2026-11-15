import 'dart:convert';

import 'package:edu/features/whiteboard/domain/entities/board_element.dart';
import 'package:edu/features/whiteboard/domain/entities/whiteboard_sync_step.dart';

/// Maintains the canonical, lightweight semantic state of the whiteboard.
///
/// State is keyed by `target_id`, so tutors can refer to existing elements
/// without requesting a raster snapshot. Mutations are transactional for a
/// complete step: invalid actions leave the prior state unchanged.
final class BoardStateTracker {
  Map<String, BoardElement> _elements = <String, BoardElement>{};

  int get elementCount => _elements.length;
  bool get hasHighlights => _elements.values.any((element) => element.highlighted);

  List<BoardElement> get elements {
    final values = _elements.values.toList(growable: false)
      ..sort((left, right) => left.targetId.compareTo(right.targetId));
    return List<BoardElement>.unmodifiable(values);
  }

  BoardElement? elementFor(String targetId) => _elements[targetId];

  void applyAction(WhiteboardAction action) {
    final candidate = Map<String, BoardElement>.of(_elements);
    _applyTo(candidate, action);
    _elements = candidate;
  }

  void applyStep(WhiteboardSyncStep step) {
    final candidate = Map<String, BoardElement>.of(_elements);
    for (final action in step.actions) {
      _applyTo(candidate, action);
    }
    _elements = candidate;
  }

  /// Removes all canonical elements.
  void reset() {
    _elements = <String, BoardElement>{};
  }

  /// Returns a deterministic JSON object suitable for model context or sync.
  Map<String, Object?> toJson() => <String, Object?>{
        'version': 1,
        'elements': elements.map((element) => element.toJson()).toList(growable: false),
      };

  String toCanonicalJson() => jsonEncode(toJson());

  static void _applyTo(
    Map<String, BoardElement> elements,
    WhiteboardAction action,
  ) {
    switch (action.operation) {
      case WhiteboardOperation.drawNode:
      case WhiteboardOperation.drawArrow:
      case WhiteboardOperation.writeMath:
        final element = BoardElement.fromAction(action);
        elements[element.targetId] = element;
        break;
      case WhiteboardOperation.highlight:
        final targetId = action.targetId!;
        final existing = elements[targetId];
        if (existing == null) {
          throw StateError('Cannot highlight missing board target "$targetId".');
        }
        elements[targetId] = existing.withHighlight(action);
        break;
      case WhiteboardOperation.clear:
        final targetId = action.targetId;
        if (targetId == null) {
          elements.clear();
        } else {
          elements.remove(targetId);
        }
        break;
    }
  }
}
