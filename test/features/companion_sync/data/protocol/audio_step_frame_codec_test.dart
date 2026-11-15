import 'dart:typed_data';

import 'package:edu/features/companion_sync/data/protocol/audio_step_frame_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('encodes and parses the step id as a four-byte big-endian header', () {
    const stepId = 0xf0123456;
    final pcm = Uint8List.fromList(<int>[0, 1, 254, 255]);

    final frame = AudioStepFrameCodec.encode(stepId, pcm);
    expect(frame.length, 8);
    expect(frame.take(4), <int>[0xf0, 0x12, 0x34, 0x56]);

    final decoded = AudioStepFrameCodec.decode(frame);
    expect(decoded.stepId, stepId);
    expect(decoded.pcmChunk, orderedEquals(pcm));
  });

  test('rejects invalid ids and truncated or odd-byte frames', () {
    expect(() => AudioStepFrameCodec.encode(-1, Uint8List.fromList(<int>[1, 2])),
        throwsRangeError);
    expect(() => AudioStepFrameCodec.encode(1, Uint8List.fromList(<int>[1])),
        throwsArgumentError);
    expect(() => AudioStepFrameCodec.decode(Uint8List(4)), throwsFormatException);
    expect(() => AudioStepFrameCodec.decode(Uint8List(5)), throwsFormatException);
  });
}
