import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:edu/features/companion_sync/data/services/p2p_lan_database_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database firstDatabase;
  late Database secondDatabase;
  late P2pLanDatabaseSyncService first;
  late P2pLanDatabaseSyncService second;

  setUp(() {
    firstDatabase = sqlite3.openInMemory();
    secondDatabase = sqlite3.openInMemory();
    first = P2pLanDatabaseSyncService(database: firstDatabase, deviceId: 'device-a');
    second = P2pLanDatabaseSyncService(database: secondDatabase, deviceId: 'device-b');
  });

  tearDown(() async {
    await first.dispose();
    await second.dispose();
    firstDatabase.dispose();
    secondDatabase.dispose();
  });

  test('record wire payload encoding and decoding run through transferable bytes', () async {
    final record = LanSyncRecord(
      kind: 'sqlite_vec',
      recordId: 'vec-wire',
      revision: 42,
      deviceId: 'device-a',
      deleted: false,
      payload: Uint8List.fromList(<int>[0, 1, 127, 128, 255]),
    );

    final wire = await record.toWireJson();
    final decoded = await LanSyncRecord.decodeJson(
      Map<String, dynamic>.from(wire),
    );

    expect(decoded.kind, record.kind);
    expect(decoded.recordId, record.recordId);
    expect(decoded.revision, record.revision);
    expect(decoded.deviceId, record.deviceId);
    expect(decoded.payload, orderedEquals(record.payload));
  });

  test('concurrent note and sqlite-vec writes converge by revision and device id', () async {
    final sameRevision = DateTime.fromMicrosecondsSinceEpoch(9000, isUtc: true);
    await first.publishStudentNote(
      noteId: 'note-1',
      jsonPayload: jsonEncode(<String, Object>{'text': 'from A'}),
      modifiedAt: sameRevision,
    );
    await second.publishStudentNote(
      noteId: 'note-1',
      jsonPayload: jsonEncode(<String, Object>{'text': 'from B'}),
      modifiedAt: sameRevision,
    );
    await first.publishVectorRecord(
      recordId: 'embedding-1',
      vectorAndMetadata: Uint8List.fromList(<int>[1, 2, 3, 4]),
      modifiedAt: sameRevision,
    );
    await second.publishVectorRecord(
      recordId: 'embedding-1',
      vectorAndMetadata: Uint8List.fromList(<int>[5, 6, 7, 8]),
      modifiedAt: sameRevision,
    );

    final firstRecords = first.records();
    final secondRecords = second.records();
    for (final record in firstRecords) {
      await second.applyRemoteRecord(record.toJson());
    }
    for (final record in secondRecords) {
      await first.applyRemoteRecord(record.toJson());
    }

    String fingerprint(LanSyncRecord record) =>
        '${record.kind}|${record.recordId}|${record.revision}|${record.deviceId}|'
        '${record.deleted}|${base64Encode(record.payload)}';
    expect(first.records().map(fingerprint).toList(),
        second.records().map(fingerprint).toList());
    expect(first.records(kind: 'student_note').single.deviceId, 'device-b');
    expect(first.records(kind: 'sqlite_vec').single.payload, orderedEquals(<int>[5, 6, 7, 8]));
  });

  test('newer tombstone wins and prevents stale note resurrection', () async {
    await first.publishStudentNote(
      noteId: 'note-deleted',
      jsonPayload: '{"text":"old"}',
      modifiedAt: DateTime.fromMicrosecondsSinceEpoch(100, isUtc: true),
    );
    final oldRecord = first.records().single;
    await second.deleteRecord(kind: 'student_note', recordId: 'note-deleted');
    final tombstone = second.records().single;

    expect(await first.applyRemoteRecord(tombstone.toJson()), isTrue);
    expect(await second.applyRemoteRecord(oldRecord.toJson()), isFalse);
    expect(first.records().single.deleted, isTrue);
    expect(second.records().single.deleted, isTrue);
  });

  test('start requests reconciliation and local writes are sent to the peer', () async {
    final incoming = StreamController<Map<String, dynamic>>.broadcast();
    final sent = <Map<String, Object?>>[];
    await first.start(incoming: incoming.stream, send: (message) async => sent.add(message));
    expect(sent.single['type'], 'sync_request');

    await first.publishStudentNote(noteId: 'n2', jsonPayload: '{"text":"note"}');
    expect(sent.last['type'], 'sync_record');
    expect(sent.last['kind'], 'student_note');

    await incoming.close();
  });
}
