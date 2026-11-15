import 'dart:convert';
import 'dart:typed_data';

import 'package:edu/features/companion_sync/data/server/local_host_server.dart';
import 'package:edu/features/whiteboard/domain/entities/student_stylus_event.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';

void main() {
  const pairingKey = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  LocalHostServer createServer({
    void Function(StudentStylusEvent event)? onStylus,
    void Function(Uint8List bytes)? onSnapshot,
  }) =>
      LocalHostServer(
        pairingKey: pairingKey,
        onPcmChunk: (pcm, sampleRateHz) {},
        onStylusEvent: (event) => onStylus?.call(event),
        onBoardSnapshot: (bytes) => onSnapshot?.call(bytes),
      );

  test('missing and invalid bearer tokens receive HTTP 401 before upgrade', () async {
    final server = createServer();
    final missing = await server.handler(
      Request('GET', Uri.parse('http://127.0.0.1/sync')),
    );
    final invalid = await server.handler(
      Request(
        'GET',
        Uri.parse('http://127.0.0.1/sync'),
        headers: const <String, String>{'authorization': 'Bearer $pairingKey-wrong'},
      ),
    );

    expect(missing.statusCode, 401);
    expect(missing.headers['www-authenticate'], 'Bearer');
    expect(invalid.statusCode, 401);
    await server.dispose();
  });

  test('bearer token comparison checks complete tokens without prefix acceptance', () {
    expect(LocalHostServer.constantTimeTokenEquals(pairingKey, pairingKey), isTrue);
    for (var index = 0; index < pairingKey.length; index++) {
      final changed = String.fromCharCode(pairingKey.codeUnitAt(index) ^ 1);
      final candidate = '${pairingKey.substring(0, index)}$changed${pairingKey.substring(index + 1)}';
      expect(LocalHostServer.constantTimeTokenEquals(candidate, pairingKey), isFalse);
    }
    expect(LocalHostServer.constantTimeTokenEquals(pairingKey.substring(0, 63), pairingKey), isFalse);
    expect(LocalHostServer.constantTimeTokenEquals('$pairingKey-x', pairingKey), isFalse);
  });

  test('routes base64 WebP JSON snapshots and normalized stylus events', () async {
    Uint8List? receivedSnapshot;
    StudentStylusEvent? receivedStylus;
    final server = createServer(
      onStylus: (event) => receivedStylus = event,
      onSnapshot: (bytes) => receivedSnapshot = bytes,
    );
    final webp = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x10, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20,
      0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]);

    await server.processTextFrame(jsonEncode(<String, Object>{
      'type': 'board_snapshot',
      'format': 'webp',
      'data': base64Encode(webp),
    }));
    await server.processTextFrame(jsonEncode(<String, Object>{
      'type': 'student_stylus_event',
      'event': <String, Object>{
        'type': 'stylus',
        'pointerId': 4,
        'phase': 'move',
        'x': 0.25,
        'y': 0.75,
        'pressure': 0.5,
        'timestampUs': 1200,
      },
    }));

    expect(receivedSnapshot, orderedEquals(webp));
    expect(receivedStylus?.phase, StudentStylusPhase.move);
    expect(receivedStylus?.x, 0.25);
    expect(receivedStylus?.y, 0.75);
    await server.dispose();
  });
}
