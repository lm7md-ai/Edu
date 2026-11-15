import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as image;

/// Converts an exported PNG board image into bounded, compressed WebP bytes.
/// Decode and encode are performed outside Flutter's UI isolate.
final class WebpSnapshotEncoder {
  const WebpSnapshotEncoder({this.quality = 82, this.maxInputBytes = 24 * 1024 * 1024});

  final int quality;
  final int maxInputBytes;

  Future<Uint8List> encodePng(Uint8List pngBytes) async {
    if (quality < 1 || quality > 100) {
      throw RangeError.range(quality, 1, 100, 'quality');
    }
    if (pngBytes.isEmpty || pngBytes.length > maxInputBytes) {
      throw ArgumentError.value(pngBytes.length, 'pngBytes.length', 'PNG exceeds the configured limit.');
    }
    final input = TransferableTypedData.fromList(<Uint8List>[pngBytes]);
    return Isolate.run<Uint8List>(() => _decodeAndEncodeWebp(input, quality));
  }
}

Uint8List _decodeAndEncodeWebp(TransferableTypedData transferable, int quality) {
  final source = transferable.materialize().asUint8List();
  final decoded = image.decodeImage(source);
  if (decoded == null) throw const FormatException('Snapshot bytes are not a supported image.');
  final encoder = image.WebPEncoder(lossless: false, quality: quality);
  return encoder.encode(decoded);
}
