import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

/// Durable row replicated between paired peers.
final class LanSyncRecord {
  LanSyncRecord({
    required this.kind,
    required this.recordId,
    required this.revision,
    required this.deviceId,
    required this.deleted,
    required Uint8List payload,
  }) : payload = Uint8List.fromList(payload);

  final String kind;
  final String recordId;
  final int revision;
  final String deviceId;
  final bool deleted;
  final Uint8List payload;

  Map<String, Object?> toJson() => <String, Object?>{
        'type': 'sync_record',
        'kind': kind,
        'id': recordId,
        'revision': revision,
        'device_id': deviceId,
        'deleted': deleted,
        'payload': base64Encode(payload),
      };

  static Future<LanSyncRecord> decodeJson(
    Map<String, dynamic> json, {
    int maxPayloadBytes = 8 * 1024 * 1024,
  }) async {
    final kind = json['kind'];
    final recordId = json['id'];
    final revision = json['revision'];
    final deviceId = json['device_id'];
    final deleted = json['deleted'];
    final encodedPayload = json['payload'];
    if ((kind != 'student_note' && kind != 'sqlite_vec') ||
        recordId is! String || recordId.isEmpty || recordId.length > 512 ||
        revision is! int || revision < 0 ||
        deviceId is! String || deviceId.isEmpty || deviceId.length > 128 ||
        deleted is! bool || encodedPayload is! String) {
      throw const FormatException('LAN sync record has invalid fields.');
    }
    final maxBase64Characters = ((maxPayloadBytes + 2) ~/ 3) * 4;
    if (encodedPayload.length > maxBase64Characters) {
      throw const FormatException('LAN sync record payload is too large.');
    }
    final payload = await Isolate.run<Uint8List>(
      () => Uint8List.fromList(base64Decode(encodedPayload)),
    );
    if (payload.length > maxPayloadBytes || (!deleted && payload.isEmpty)) {
      throw const FormatException('LAN sync record payload is empty or too large.');
    }
    return LanSyncRecord(
      kind: kind as String,
      recordId: recordId,
      revision: revision,
      deviceId: deviceId,
      deleted: deleted,
      payload: payload,
    );
  }

  Future<Map<String, Object?>> toWireJson() async {
    final transferable = TransferableTypedData.fromList(<Uint8List>[payload]);
    final encodedPayload = await Isolate.run<String>(
      () => base64Encode(transferable.materialize().asUint8List()),
    );
    return <String, Object?>{
      'type': 'sync_record',
      'kind': kind,
      'id': recordId,
      'revision': revision,
      'device_id': deviceId,
      'deleted': deleted,
      'payload': encodedPayload,
    };
  }
}

/// Synchronizes note JSON and SQLite-vec row payloads using per-record
/// revisions, durable tombstones, and deterministic last-writer conflict rules.
///
/// Vector payloads are opaque serialized SQLite-vec row data. The local app
/// can rebuild its vec0 index from these synchronized records without copying
/// a live SQLite database file over the network.
final class P2pLanDatabaseSyncService {
  P2pLanDatabaseSyncService({
    required this.database,
    required this.deviceId,
    this.maxPayloadBytes = 8 * 1024 * 1024,
    this.onProtocolError,
  }) {
    if (deviceId.trim().isEmpty || deviceId.length > 128) {
      throw ArgumentError.value(deviceId, 'deviceId');
    }
    if (maxPayloadBytes < 1) throw ArgumentError.value(maxPayloadBytes, 'maxPayloadBytes');
  }

  final Database database;
  final String deviceId;
  final int maxPayloadBytes;
  final void Function(Object error)? onProtocolError;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  Future<void> Function(Map<String, Object?> message)? _send;
  bool _initialized = false;
  bool _disposed = false;
  int _lastLocalRevision = 0;

  Future<void> initialize() async {
    if (_disposed) throw StateError('Database sync service is disposed.');
    if (_initialized) return;
    database.execute('''
      CREATE TABLE IF NOT EXISTS p2p_lan_sync_records (
        kind TEXT NOT NULL CHECK (kind IN ('student_note', 'sqlite_vec')),
        record_id TEXT NOT NULL,
        revision INTEGER NOT NULL,
        device_id TEXT NOT NULL,
        deleted INTEGER NOT NULL CHECK (deleted IN (0, 1)),
        payload BLOB NOT NULL,
        PRIMARY KEY (kind, record_id)
      )
    ''');
    final latest = database.select(
      'SELECT MAX(revision) AS revision FROM p2p_lan_sync_records',
    ).first['revision'];
    if (latest is int && latest > _lastLocalRevision) _lastLocalRevision = latest;
    _initialized = true;
  }

  /// Connects the service to a peer transport and reconciles all durable rows.
  Future<void> start({
    required Stream<Map<String, dynamic>> incoming,
    required Future<void> Function(Map<String, Object?> message) send,
  }) async {
    await initialize();
    await _subscription?.cancel();
    _send = send;
    _subscription = incoming.listen(
      (message) => unawaited(_handleMessage(message).catchError(
        (Object error, StackTrace stackTrace) => onProtocolError?.call(error),
      )),
      onError: (Object error, StackTrace stackTrace) => onProtocolError?.call(error),
    );
    await send(<String, Object?>{'type': 'sync_request'});
    await sendAllRecords();
  }

  Future<void> publishStudentNote({
    required String noteId,
    required String jsonPayload,
    DateTime? modifiedAt,
  }) => _publish(
        kind: 'student_note',
        recordId: noteId,
        payload: Uint8List.fromList(utf8.encode(jsonPayload)),
        modifiedAt: modifiedAt,
      );

  /// Stores the serialized vector row or embedding bytes under the SQLite-vec
  /// record namespace and replicates them to the paired device.
  Future<void> publishVectorRecord({
    required String recordId,
    required Uint8List vectorAndMetadata,
    DateTime? modifiedAt,
  }) =>
      _publish(
        kind: 'sqlite_vec',
        recordId: recordId,
        payload: vectorAndMetadata,
        modifiedAt: modifiedAt,
      );

  Future<void> deleteRecord({required String kind, required String recordId}) =>
      _publish(
        kind: kind,
        recordId: recordId,
        payload: Uint8List(0),
        deleted: true,
      );

  Future<void> _publish({
    required String kind,
    required String recordId,
    required Uint8List payload,
    DateTime? modifiedAt,
    bool deleted = false,
  }) async {
    await initialize();
    if (kind != 'student_note' && kind != 'sqlite_vec') {
      throw ArgumentError.value(kind, 'kind');
    }
    if (recordId.trim().isEmpty || recordId.length > 512) {
      throw ArgumentError.value(recordId, 'recordId');
    }
    if (payload.length > maxPayloadBytes || (!deleted && payload.isEmpty)) {
      throw ArgumentError.value(payload.length, 'payload.length');
    }
    final revision = _nextRevision(modifiedAt);
    final record = LanSyncRecord(
      kind: kind,
      recordId: recordId,
      revision: revision,
      deviceId: deviceId,
      deleted: deleted,
      payload: payload,
    );
    _write(record);
    final send = _send;
    if (send != null) await send(await record.toWireJson());
  }

  int _nextRevision(DateTime? modifiedAt) {
    final candidate = modifiedAt?.toUtc().microsecondsSinceEpoch ??
        DateTime.now().toUtc().microsecondsSinceEpoch;
    _lastLocalRevision = candidate > _lastLocalRevision
        ? candidate
        : _lastLocalRevision + 1;
    return _lastLocalRevision;
  }

  /// Applies an incoming record only if it wins the deterministic version
  /// comparison. Returns true if this peer's durable copy changed.
  Future<bool> applyRemoteRecord(Map<String, dynamic> json) async {
    await initialize();
    final incoming = await LanSyncRecord.decodeJson(json, maxPayloadBytes: maxPayloadBytes);
    if (incoming.revision > _lastLocalRevision) _lastLocalRevision = incoming.revision;
    final existing = _read(incoming.kind, incoming.recordId);
    if (existing != null && !_isIncomingNewer(incoming, existing)) return false;
    _write(incoming);
    return true;
  }

  Future<void> sendAllRecords() async {
    await initialize();
    final send = _send;
    if (send == null) return;
    final rows = database.select(
      'SELECT kind, record_id, revision, device_id, deleted, payload '
      'FROM p2p_lan_sync_records ORDER BY kind, record_id',
    );
    for (final row in rows) {
      await send(await _recordFromRow(row).toWireJson());
    }
  }

  List<LanSyncRecord> records({String? kind}) {
    if (!_initialized) throw StateError('Database sync service is not initialized.');
    final ResultSet rows = kind == null
        ? database.select(
            'SELECT kind, record_id, revision, device_id, deleted, payload '
            'FROM p2p_lan_sync_records ORDER BY kind, record_id',
          )
        : database.select(
            'SELECT kind, record_id, revision, device_id, deleted, payload '
            'FROM p2p_lan_sync_records WHERE kind = ? ORDER BY record_id',
            <Object?>[kind],
          );
    return rows.map(_recordFromRow).toList(growable: false);
  }

  Future<void> _handleMessage(Map<String, dynamic> message) async {
    switch (message['type']) {
      case 'sync_request':
        await sendAllRecords();
        break;
      case 'sync_record':
        await applyRemoteRecord(message);
        break;
      default:
        throw FormatException('Unknown LAN database sync message: ${message['type']}');
    }
  }

  LanSyncRecord? _read(String kind, String id) {
    final rows = database.select(
      'SELECT kind, record_id, revision, device_id, deleted, payload '
      'FROM p2p_lan_sync_records WHERE kind = ? AND record_id = ?',
      <Object?>[kind, id],
    );
    return rows.isEmpty ? null : _recordFromRow(rows.first);
  }

  void _write(LanSyncRecord record) {
    database.execute(
      'INSERT INTO p2p_lan_sync_records '
      '(kind, record_id, revision, device_id, deleted, payload) '
      'VALUES (?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(kind, record_id) DO UPDATE SET '
      'revision = excluded.revision, device_id = excluded.device_id, '
      'deleted = excluded.deleted, payload = excluded.payload',
      <Object?>[
        record.kind,
        record.recordId,
        record.revision,
        record.deviceId,
        record.deleted ? 1 : 0,
        record.payload,
      ],
    );
  }

  static LanSyncRecord _recordFromRow(Row row) => LanSyncRecord(
        kind: row['kind'] as String,
        recordId: row['record_id'] as String,
        revision: row['revision'] as int,
        deviceId: row['device_id'] as String,
        deleted: row['deleted'] == 1,
        payload: row['payload'] as Uint8List,
      );

  static bool _isIncomingNewer(LanSyncRecord incoming, LanSyncRecord existing) {
    if (incoming.revision != existing.revision) {
      return incoming.revision > existing.revision;
    }
    final deviceOrder = incoming.deviceId.compareTo(existing.deviceId);
    if (deviceOrder != 0) return deviceOrder > 0;
    if (incoming.deleted != existing.deleted) return incoming.deleted;
    final length = incoming.payload.length.compareTo(existing.payload.length);
    if (length != 0) return length > 0;
    for (var index = 0; index < incoming.payload.length; index++) {
      final order = incoming.payload[index].compareTo(existing.payload[index]);
      if (order != 0) return order > 0;
    }
    return false;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription?.cancel();
    _subscription = null;
    _send = null;
  }
}
