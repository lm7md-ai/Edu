import 'dart:typed_data';

import 'package:edu/features/whiteboard/data/services/webp_snapshot_encoder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

void main() {
  test('converts a PNG snapshot to WebP outside the caller isolate', () async {
    final png = Uint8List.fromList(image.encodePng(image.Image(width: 2, height: 2)));
    final webp = await const WebpSnapshotEncoder(quality: 80).encodePng(png);

    expect(webp.length, greaterThan(20));
    expect(webp.sublist(0, 4), <int>[0x52, 0x49, 0x46, 0x46]);
    expect(webp.sublist(8, 12), <int>[0x57, 0x45, 0x42, 0x50]);
  });
}
