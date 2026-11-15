import 'dart:convert';

import 'package:edu/features/voice_tutor/data/workers/streaming_whiteboard_json_parser.dart';
import 'package:edu/features/whiteboard/domain/entities/whiteboard_sync_step.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('StreamingWhiteboardJsonParser', () {
    test('parses validated steps across every token boundary', () {
      final step = WhiteboardSyncStep(
        stepId: 23,
        speechText: 'Consider {x}, the "quoted" value, \\frac{1}{2}, and 🧪.',
        actions: <WhiteboardAction>[
          WhiteboardAction(
            operation: WhiteboardOperation.drawNode,
            targetId: 'node-a',
            x: 0.2,
            y: 0.3,
            content: 'A {set} with a "quoted" label',
            style: WhiteboardStyle.primary,
          ),
          WhiteboardAction(
            operation: WhiteboardOperation.writeMath,
            targetId: 'equation',
            x: 1,
            y: 0,
            content: r'\\sqrt{x^{2} + y^{2}}',
            style: WhiteboardStyle.accent,
          ),
        ],
      );
      final json = jsonEncode(step.toJson());

      // Chunk size one exercises splits in escaped quotes, escape slashes,
      // Unicode surrogate pairs, number tokens, and nested JSON boundaries.
      final parser = StreamingWhiteboardJsonParser();
      final parsed = <WhiteboardSyncStep>[];
      for (var index = 0; index < json.length; index++) {
        parsed.addAll(parser.addChunk(json.substring(index, index + 1)));
      }
      parser.finish();

      expect(parsed, <WhiteboardSyncStep>[step]);
    });

    test('does not emit partial objects and emits each object once when completed', () {
      final first = _step(1, 'first { value }');
      final second = _step(2, r'second \\path and \\"quote\\"');
      final firstJson = jsonEncode(first.toJson());
      final secondJson = jsonEncode(second.toJson());
      final parser = StreamingWhiteboardJsonParser();

      expect(
        parser.addChunk('model preamble\n${firstJson.substring(0, firstJson.length - 1)}'),
        isEmpty,
      );
      expect(
        parser.addChunk('} ${secondJson.substring(0, secondJson.length - 2)}'),
        <WhiteboardSyncStep>[first],
      );
      expect(
        parser.addChunk(secondJson.substring(secondJson.length - 2)),
        <WhiteboardSyncStep>[second],
      );
      expect(parser.addChunk(' trailing explanation'), isEmpty);
      parser.finish();
    });

    test('accepts uint32 and normalized-coordinate boundary values', () {
      final step = WhiteboardSyncStep(
        stepId: WhiteboardSyncStep.maxStepId,
        speechText: 'Boundary values',
        actions: <WhiteboardAction>[
          WhiteboardAction(
            operation: WhiteboardOperation.drawArrow,
            targetId: 'edge-arrow',
            x: 0,
            y: 1,
            endX: 1,
            endY: 0,
            style: WhiteboardStyle.dashed,
          ),
          WhiteboardAction.clear(),
        ],
      );
      final parser = StreamingWhiteboardJsonParser();

      expect(parser.addChunk(jsonEncode(step.toJson())), <WhiteboardSyncStep>[step]);
      parser.finish();
    });

    test('extracts ordered objects from arrays, concatenated JSON, and noisy prefixes', () {
      final steps = <WhiteboardSyncStep>[
        _step(1, 'First'),
        _step(2, 'Second'),
        _step(3, 'Third'),
      ];
      final parser = StreamingWhiteboardJsonParser();
      final parsed = <WhiteboardSyncStep>[];
      parsed.addAll(parser.addChunk('Here is the answer: ['));
      parsed.addAll(parser.addChunk(jsonEncode(steps[0].toJson())));
      parsed.addAll(parser.addChunk(','));
      parsed.addAll(parser.addChunk(jsonEncode(steps[1].toJson())));
      parsed.addAll(parser.addChunk('] then another step '));
      parsed.addAll(parser.addChunk(jsonEncode(steps[2].toJson())));
      parser.finish();

      expect(parsed, steps);
    });

    test('accepts an empty stream and text containing unmatched braces outside JSON', () {
      final parser = StreamingWhiteboardJsonParser();
      expect(parser.addChunk('No step yet: } no JSON object follows'), isEmpty);
      expect(parser.addChunk(' and no closing object'), isEmpty);
      expect(() => parser.finish(), returnsNormally);
    });

    test('validates domain semantics and rejects malformed object members', () {
      final invalidSteps = <Map<String, Object?>>[
        <String, Object?>{'step_id': -1, 'speech_text': 'bad', 'actions': <Object?>[]},
        <String, Object?>{'step_id': 0x100000000, 'speech_text': 'bad', 'actions': <Object?>[]},
        <String, Object?>{'step_id': 1, 'speech_text': 7, 'actions': <Object?>[]},
        <String, Object?>{'step_id': 1, 'speech_text': 'bad', 'actions': <Object?>[null]},
        <String, Object?>{
          'step_id': 1,
          'speech_text': 'bad',
          'actions': <Object?>[
            <String, Object?>{
              'op': 'draw_node',
              'target_id': 'node',
              'x': 1.1,
              'y': 0.5,
              'content': 'out of range',
              'style': 'primary',
            },
          ],
        },
      ];

      for (final invalid in invalidSteps) {
        final parser = StreamingWhiteboardJsonParser();
        expect(
          () => parser.addChunk(jsonEncode(invalid)),
          throwsFormatException,
          reason: 'Invalid payload should not become a WhiteboardSyncStep: $invalid',
        );
      }
    });

    test('rejects domain collection limits before accepting a step', () {
      final tooManyActions = <String, Object?>{
        'step_id': 2,
        'speech_text': 'too many actions',
        'actions': List<Map<String, Object?>>.generate(
          WhiteboardSyncStep.maxActions + 1,
          (_) => <String, Object?>{
            'op': 'clear',
            'target_id': null,
            'x': null,
            'y': null,
            'end_x': null,
            'end_y': null,
            'content': null,
            'style': null,
          },
        ),
      };
      final tooMuchSpeech = <String, Object?>{
        'step_id': 2,
        'speech_text': 'x' * (WhiteboardSyncStep.maxSpeechTextLength + 1),
        'actions': <Object?>[],
      };

      for (final invalid in <Map<String, Object?>>[tooManyActions, tooMuchSpeech]) {
        expect(
          () => StreamingWhiteboardJsonParser().addChunk(jsonEncode(invalid)),
          throwsFormatException,
        );
      }
    });

    test('rejects malformed JSON and incomplete final objects', () {
      for (final invalid in <String>[
        '{"step_id":1,"speech_text":"bad",}',
        '{"step_id":1,"speech_text":"bad","actions":[] garbage}',
        '{"step_id":1,"speech_text":"bad\\q","actions":[]}',
      ]) {
        final parser = StreamingWhiteboardJsonParser();
        expect(() => parser.addChunk(invalid), throwsFormatException);
      }

      final incomplete = StreamingWhiteboardJsonParser();
      incomplete.addChunk('{"step_id":1');
      expect(() => incomplete.finish(), throwsFormatException);
    });

    test('enforces per-object and total-object resource limits', () {
      final oversized = StreamingWhiteboardJsonParser(maxObjectCharacters: 24);
      expect(
        () => oversized.addChunk(jsonEncode(_step(1, 'x' * 64).toJson())),
        throwsFormatException,
      );

      final limitedCount = StreamingWhiteboardJsonParser(maxObjects: 1);
      final twoSteps = '${jsonEncode(_step(1, 'one').toJson())}'
          '${jsonEncode(_step(2, 'two').toJson())}';
      expect(() => limitedCount.addChunk(twoSteps), throwsFormatException);
    });

    test('rejects non-positive parser limits', () {
      expect(() => StreamingWhiteboardJsonParser(maxObjectCharacters: 0), throwsArgumentError);
      expect(() => StreamingWhiteboardJsonParser(maxObjects: 0), throwsArgumentError);
    });
  });
}

WhiteboardSyncStep _step(int id, String speech) => WhiteboardSyncStep(
      stepId: id,
      speechText: speech,
      actions: const <WhiteboardAction>[],
    );
