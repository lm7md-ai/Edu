import 'package:meta/meta.dart';

/// Normalized pen/touch event emitted by the local whiteboard.
enum StudentStylusPhase { down, move, up, cancel }

@immutable
final class StudentStylusEvent {
  StudentStylusEvent({
    required this.pointerId,
    required this.phase,
    required this.x,
    required this.y,
    required this.pressure,
    required this.timestampUs,
  }) {
    if (pointerId < 0) throw RangeError.value(pointerId, 'pointerId');
    if (timestampUs < 0) throw RangeError.value(timestampUs, 'timestampUs');
    _validateNormalized(x, 'x');
    _validateNormalized(y, 'y');
    _validateNormalized(pressure, 'pressure');
  }

  final int pointerId;
  final StudentStylusPhase phase;
  final double x;
  final double y;
  final double pressure;
  final int timestampUs;

  Map<String, Object> toJson() => <String, Object>{
        'type': 'stylus',
        'pointerId': pointerId,
        'phase': phase.name,
        'x': x,
        'y': y,
        'pressure': pressure,
        'timestampUs': timestampUs,
      };

  factory StudentStylusEvent.fromJson(Map<String, dynamic> json) {
    final rawPointerId = json['pointerId'];
    final rawPhase = json['phase'];
    final rawTimestamp = json['timestampUs'];
    if (rawPointerId is! int || rawPhase is! String || rawTimestamp is! int) {
      throw const FormatException('Stylus event has invalid id, phase, or timestamp.');
    }
    final phase = StudentStylusPhase.values.where((value) => value.name == rawPhase);
    if (phase.isEmpty) throw FormatException('Unknown stylus phase: $rawPhase');

    double number(String key) {
      final value = json[key];
      if (value is! num) throw FormatException('Stylus field "$key" must be numeric.');
      return value.toDouble();
    }

    try {
      return StudentStylusEvent(
        pointerId: rawPointerId,
        phase: phase.first,
        x: number('x'),
        y: number('y'),
        pressure: number('pressure'),
        timestampUs: rawTimestamp,
      );
    } on ArgumentError catch (error) {
      throw FormatException('Invalid stylus event: ${error.message}');
    }
  }
}

void _validateNormalized(double value, String name) {
  if (!value.isFinite || value < 0 || value > 1) {
    throw ArgumentError.value(value, name, 'Expected a finite value in [0, 1].');
  }
}
