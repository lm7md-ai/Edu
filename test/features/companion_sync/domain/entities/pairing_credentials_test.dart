import 'package:edu/features/companion_sync/domain/entities/pairing_credentials.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('generates a 256-bit bearer key and six-digit pairing PIN', () {
    final credentials = PairingCredentials.generate(
      endpoint: Uri.parse('ws://neural-tutor.local:4180/sync'),
    );

    expect(credentials.pairingKey, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(credentials.pin, matches(RegExp(r'^\d{6}$')));
    expect(PairingCredentials.fromQrPayload(credentials.toQrPayload()).endpoint,
        credentials.endpoint);
    expect(PairingCredentials.fromQrPayload(credentials.toQrPayload()).pairingKey,
        credentials.pairingKey);
  });

  test('rejects malformed pairing payloads and non-WebSocket endpoints', () {
    expect(
      () => PairingCredentials.generate(endpoint: Uri.parse('http://localhost/sync')),
      throwsArgumentError,
    );
    expect(() => PairingCredentials.fromQrPayload('not-json'), throwsFormatException);
  });
}
