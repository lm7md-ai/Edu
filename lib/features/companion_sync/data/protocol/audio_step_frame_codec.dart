import 'dart:typed_data';

/// A single 16-bit PCM payload associated with a tutor step.
final class AudioStepFrame {
  const AudioStepFrame({required this.stepId, required this.pcmChunk});

  final int stepId;
  final Uint8List pcmChunk;
}

/// Encodes the four-byte big-endian step id followed by a PCM chunk.
abstract final class AudioStepFrameCodec {
  static const int headerLength = 4;
  static const int maxStepId = 0xffffffff;

  static Uint8List encode(int stepId, Uint8List pcmChunk) {
    if (stepId < 0 || stepId > maxStepId) {
      throw RangeError.range(stepId, 0, maxStepId, 'stepId');
    }
    if (pcmChunk.isEmpty || pcmChunk.length.isOdd) {
      throw ArgumentError.value(pcmChunk.length, 'pcmChunk', 'PCM must contain complete S16 samples.');
    }
    final frame = Uint8List(headerLength + pcmChunk.length);
    ByteData.sublistView(frame).setUint32(0, stepId, Endian.big);
    frame.setRange(headerLength, frame.length, pcmChunk);
    return frame;
  }

  static AudioStepFrame decode(Uint8List frame) {
    if (frame.length <= headerLength || (frame.length - headerLength).isOdd) {
      throw const FormatException('Audio frame is truncated or contains incomplete S16 samples.');
    }
    final stepId = ByteData.sublistView(frame).getUint32(0, Endian.big);
    return AudioStepFrame(
      stepId: stepId,
      pcmChunk: Uint8List.sublistView(frame, headerLength),
    );
  }
}
