import 'dart:ui';

import 'package:edu/features/whiteboard/presentation/controllers/board_coordinate_mapper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalized coordinates map to and from varying board aspect ratios', () {
    const normalized = Offset(0.25, 0.8);
    final phoneMapper = BoardCoordinateMapper(const Size(360, 780));
    final tabletMapper = BoardCoordinateMapper(const Size(1200, 800));

    expect(phoneMapper.toNormalized(phoneMapper.toLocal(normalized)), normalized);
    expect(tabletMapper.toNormalized(tabletMapper.toLocal(normalized)), normalized);
    expect(phoneMapper.toLocal(normalized), const Offset(90, 624));
    expect(tabletMapper.toLocal(normalized), const Offset(300, 640));
  });

  test('pointer positions outside the board clamp to normalized bounds', () {
    final mapper = BoardCoordinateMapper(const Size(400, 200));
    expect(mapper.toNormalized(const Offset(-20, 230)), const Offset(0, 1));
  });
}
