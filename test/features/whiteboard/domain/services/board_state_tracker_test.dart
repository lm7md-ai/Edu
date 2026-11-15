import 'package:edu/features/whiteboard/domain/services/board_state_tracker.dart';
import 'package:edu/features/whiteboard/domain/entities/whiteboard_sync_step.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BoardStateTracker', () {
    late BoardStateTracker tracker;

    setUp(() {
      tracker = BoardStateTracker();
    });

    test('adds and replaces target-addressable elements', () {
      final first = WhiteboardAction(
        operation: WhiteboardOperation.drawNode,
        targetId: 'n1',
        x: 0.2,
        y: 0.3,
        content: 'Initial',
      );
      tracker.applyAction(first);
      expect(tracker.elementCount, 1);
      expect(tracker.elementFor('n1')?.action.content, 'Initial');

      tracker.applyAction(
        WhiteboardAction(
          operation: WhiteboardOperation.drawNode,
          targetId: 'n1',
          x: 0.4,
          y: 0.5,
          content: 'Updated',
          style: WhiteboardStyle.accent,
        ),
      );

      expect(tracker.elementCount, 1);
      expect(tracker.elementFor('n1')?.action.content, 'Updated');
      expect(tracker.toJson()['version'], 1);
      expect(tracker.toCanonicalJson(), contains('"target_id":"n1"'));
    });

    test('highlight mutates the existing element and preserves its identity', () {
      tracker.applyAction(
        WhiteboardAction(
          operation: WhiteboardOperation.drawNode,
          targetId: 'n1',
          x: 0.2,
          y: 0.3,
          content: 'Key idea',
        ),
      );

      tracker.applyAction(
        WhiteboardAction(
          operation: WhiteboardOperation.highlight,
          targetId: 'n1',
          x: 0.1,
          y: 0.2,
          endX: 0.5,
          endY: 0.4,
          style: WhiteboardStyle.warning,
        ),
      );

      final highlighted = tracker.elementFor('n1');
      expect(highlighted?.highlighted, isTrue);
      expect(highlighted?.highlightAction?.style, WhiteboardStyle.warning);
      expect(highlighted?.action.content, 'Key idea');
    });

    test('clear removes a target or resets the whole board', () {
      tracker.applyStep(
        WhiteboardSyncStep(
          stepId: 1,
          speechText: '',
          actions: <WhiteboardAction>[
            WhiteboardAction(
              operation: WhiteboardOperation.drawNode,
              targetId: 'n1',
              x: 0.2,
              y: 0.3,
              content: 'A',
            ),
            WhiteboardAction(
              operation: WhiteboardOperation.drawNode,
              targetId: 'n2',
              x: 0.7,
              y: 0.3,
              content: 'B',
            ),
          ],
        ),
      );

      tracker.applyAction(WhiteboardAction.clear(targetId: 'n1'));
      expect(tracker.elementFor('n1'), isNull);
      expect(tracker.elementCount, 1);

      tracker.applyAction(WhiteboardAction.clear());
      expect(tracker.elementCount, 0);
    });

    test('invalid multi-action step leaves prior canonical state untouched', () {
      tracker.applyAction(
        WhiteboardAction(
          operation: WhiteboardOperation.drawNode,
          targetId: 'stable',
          x: 0.5,
          y: 0.5,
          content: 'Keep',
        ),
      );
      final invalidStep = WhiteboardSyncStep(
        stepId: 2,
        speechText: '',
        actions: <WhiteboardAction>[
          WhiteboardAction(
            operation: WhiteboardOperation.drawNode,
            targetId: 'temporary',
            x: 0.2,
            y: 0.2,
            content: 'Must roll back',
          ),
          WhiteboardAction(
            operation: WhiteboardOperation.highlight,
            targetId: 'missing',
            x: 0.1,
            y: 0.1,
            endX: 0.3,
            endY: 0.3,
          ),
        ],
      );

      expect(() => tracker.applyStep(invalidStep), throwsStateError);
      expect(tracker.elementCount, 1);
      expect(tracker.elementFor('stable')?.action.content, 'Keep');
      expect(tracker.elementFor('temporary'), isNull);
    });
  });
}
