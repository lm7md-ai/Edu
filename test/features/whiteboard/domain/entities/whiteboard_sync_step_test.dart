import 'package:edu/features/whiteboard/domain/entities/whiteboard_sync_step.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WhiteboardSyncStep', () {
    test('serializes the protocol schema and round-trips immutably', () {
      final step = WhiteboardSyncStep(
        stepId: 42,
        speechText: 'The result is two.',
        actions: <WhiteboardAction>[
          WhiteboardAction(
            operation: WhiteboardOperation.drawNode,
            targetId: 'node-a',
            x: 0.25,
            y: 0.5,
            content: '2',
          ),
          WhiteboardAction(
            operation: WhiteboardOperation.drawArrow,
            targetId: 'arrow-a',
            x: 0.25,
            y: 0.5,
            endX: 0.75,
            endY: 0.5,
            style: WhiteboardStyle.accent,
          ),
        ],
      );

      final json = step.toJson();
      expect(json['step_id'], 42);
      expect(json['speech_text'], 'The result is two.');
      expect((json['actions']! as List<Object?>).length, 2);

      final decoded = WhiteboardSyncStep.fromJson(json);
      expect(decoded.stepId, step.stepId);
      expect(decoded.speechText, step.speechText);
      expect(decoded.actions, hasLength(2));
      expect(decoded.actions.first.operation, WhiteboardOperation.drawNode);
      expect(decoded.actions.last.style, WhiteboardStyle.accent);
      expect(() => decoded.actions.add(step.actions.first), throwsUnsupportedError);
    });

    test('rejects coordinates outside normalized board space', () {
      expect(
        () => WhiteboardAction(
          operation: WhiteboardOperation.drawNode,
          targetId: 'node-a',
          x: 1.01,
          y: 0.5,
          content: 'outside',
        ),
        throwsArgumentError,
      );
    });

    test('rejects operation payloads missing required fields', () {
      expect(
        () => WhiteboardAction(
          operation: WhiteboardOperation.drawArrow,
          targetId: 'arrow-a',
          x: 0.1,
          y: 0.2,
        ),
        throwsArgumentError,
      );
    });

    test('rejects step ids that cannot fit the wire header', () {
      expect(
        () => WhiteboardSyncStep(
          stepId: 0x100000000,
          speechText: '',
          actions: const <WhiteboardAction>[],
        ),
        throwsRangeError,
      );
    });

    test('rejects malformed JSON field types', () {
      expect(
        () => WhiteboardSyncStep.fromJson(<String, dynamic>{
          'step_id': '42',
          'speech_text': 'hello',
          'actions': <Object?>[],
        }),
        throwsFormatException,
      );
    });
  });
}
