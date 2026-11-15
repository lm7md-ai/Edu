import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A detached compressed board snapshot. This implementation exports PNG,
/// which Flutter's engine encodes directly without an additional full-size
/// Dart image buffer.
final class BoardSnapshot {
  BoardSnapshot({
    required Uint8List bytes,
    required this.width,
    required this.height,
    this.mimeType = 'image/png',
  }) : bytes = Uint8List.fromList(bytes);

  final Uint8List bytes;
  final int width;
  final int height;
  final String mimeType;
}

/// Captures a mounted [RepaintBoundary] only when explicitly invoked.
///
/// Call this exporter in response to a student grading/feedback request; it
/// performs no periodic or background screenshots. Pixel and encoded-byte
/// limits bound GPU readback and memory use on phones.
final class RepaintBoundarySnapshotExporter {
  RepaintBoundarySnapshotExporter({
    this.maxDimension = 4096,
    this.maxPixels = 16 * 1024 * 1024,
    this.maxEncodedBytes = 24 * 1024 * 1024,
  });

  final int maxDimension;
  final int maxPixels;
  final int maxEncodedBytes;

  Future<BoardSnapshot> exportPng({
    required GlobalKey repaintBoundaryKey,
    double pixelRatio = 1,
  }) async {
    if (!pixelRatio.isFinite || pixelRatio < 0.5 || pixelRatio > 3) {
      throw ArgumentError.value(pixelRatio, 'pixelRatio', 'Use a ratio from 0.5 to 3.0.');
    }

    final context = repaintBoundaryKey.currentContext;
    if (context == null) {
      throw StateError('The whiteboard RepaintBoundary is not mounted.');
    }
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderRepaintBoundary ||
        !renderObject.attached ||
        !renderObject.hasSize) {
      throw StateError('The supplied key does not identify a laid-out RepaintBoundary.');
    }

    final logicalSize = renderObject.size;
    final width = (logicalSize.width * pixelRatio).ceil();
    final height = (logicalSize.height * pixelRatio).ceil();
    if (width <= 0 || height <= 0 ||
        width > maxDimension || height > maxDimension ||
        width * height > maxPixels) {
      throw StateError('Board snapshot dimensions exceed configured limits.');
    }

    final ui.Image image = await renderObject.toImage(pixelRatio: pixelRatio);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('Flutter could not encode the board snapshot.');
      final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      if (bytes.length > maxEncodedBytes) {
        throw StateError('Encoded board snapshot exceeds the configured byte limit.');
      }
      return BoardSnapshot(
        bytes: bytes,
        width: image.width,
        height: image.height,
      );
    } finally {
      image.dispose();
    }
  }
}
