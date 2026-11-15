import 'dart:ui';

/// Maps the canonical normalized board to the current phone/tablet viewport.
///
/// The same normalized state can be rendered at any aspect ratio. Input is
/// clamped to the board bounds so a captured pointer never produces an invalid
/// wire coordinate.
final class BoardCoordinateMapper {
  BoardCoordinateMapper(this.size) {
    if (!size.width.isFinite || !size.height.isFinite ||
        size.width <= 0 || size.height <= 0) {
      throw ArgumentError.value(size, 'size', 'Board size must be finite and positive.');
    }
  }

  final Size size;

  Offset toLocal(Offset normalized) =>
      Offset(normalized.dx * size.width, normalized.dy * size.height);

  Offset toNormalized(Offset local) => Offset(
        (local.dx / size.width).clamp(0.0, 1.0).toDouble(),
        (local.dy / size.height).clamp(0.0, 1.0).toDouble(),
      );
}
