import 'dart:convert';
import 'dart:math';

import 'package:meta/meta.dart';

/// One-time pairing material shared by QR code or short PIN entry.
@immutable
final class PairingCredentials {
  PairingCredentials({
    required this.endpoint,
    required this.pairingKey,
    required this.pin,
  }) {
    if (endpoint.scheme != 'ws' && endpoint.scheme != 'wss') {
      throw ArgumentError.value(endpoint, 'endpoint', 'Expected a WebSocket URI.');
    }
    if (!_isHexKey(pairingKey)) {
      throw ArgumentError.value(pairingKey, 'pairingKey', 'Expected a 256-bit hex key.');
    }
    if (!RegExp(r'^\d{6}$').hasMatch(pin)) {
      throw ArgumentError.value(pin, 'pin', 'Expected a six-digit PIN.');
    }
  }

  factory PairingCredentials.generate({required Uri endpoint}) {
    final random = Random.secure();
    final keyBytes = List<int>.generate(32, (_) => random.nextInt(256));
    final pairingKey = keyBytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    final pin = random.nextInt(1000000).toString().padLeft(6, '0');
    return PairingCredentials(endpoint: endpoint, pairingKey: pairingKey, pin: pin);
  }

  final Uri endpoint;
  final String pairingKey;
  final String pin;

  String toQrPayload() => jsonEncode(<String, Object>{
        'version': 1,
        'endpoint': endpoint.toString(),
        'key': pairingKey,
        'pin': pin,
      });

  factory PairingCredentials.fromQrPayload(String payload) {
    final decoded = jsonDecode(payload);
    if (decoded is! Map<String, dynamic> || decoded['version'] != 1 ||
        decoded['endpoint'] is! String || decoded['key'] is! String ||
        decoded['pin'] is! String) {
      throw const FormatException('Pairing QR payload is invalid.');
    }
    try {
      return PairingCredentials(
        endpoint: Uri.parse(decoded['endpoint'] as String),
        pairingKey: decoded['key'] as String,
        pin: decoded['pin'] as String,
      );
    } on ArgumentError catch (error) {
      throw FormatException('Invalid pairing payload: ${error.message}');
    }
  }

  static bool _isHexKey(String value) =>
      value.length == 64 && value.codeUnits.every((unit) =>
          (unit >= 0x30 && unit <= 0x39) ||
          (unit >= 0x61 && unit <= 0x66) ||
          (unit >= 0x41 && unit <= 0x46));
}
