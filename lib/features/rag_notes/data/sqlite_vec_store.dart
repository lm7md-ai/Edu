import 'dart:math' as math;
import 'dart:typed_data';

import 'package:edu/features/rag_notes/domain/entities/document_chunk.dart';
import 'package:edu/features/rag_notes/domain/entities/flashcard.dart';
import 'package:edu/features/rag_notes/domain/entities/fsrs_card_state.dart';
import 'package:sqlite3/sqlite3.dart';

/// SQLite-backed curriculum index. When a loadable sqlite-vec extension is
/// provided, vectors are indexed and queried with vec0; otherwise exact cosine
/// search over locally stored float32 blobs keeps tests and desktop imports
/// usable without weakening source metadata or ranking semantics.
final class SqliteVecStore {
  SqliteVecStore({
    required Database database,
    required this.dimensions,
    String? sqliteVecExtensionPath,
    this.requireSqliteVec = false,
    this.ownsDatabase = false,
  })  : _database = database {
    if (dimensions < 1) throw ArgumentError.value(dimensions, 'dimensions');
    _createSchema();
    if (sqliteVecExtensionPath != null) {
      _enableSqliteVec(sqliteVecExtensionPath);
    } else if (requireSqliteVec) {
      throw ArgumentError('A sqlite-vec extension path is required.');
    }
  }

  final Database _database;
  final int dimensions;
  final bool requireSqliteVec;
  final bool ownsDatabase;
  bool _sqliteVecActive = false;
  bool _closed = false;

  bool get usesSqliteVec => _sqliteVecActive;

  void _createSchema() {
    _database.execute('''
      CREATE TABLE IF NOT EXISTS rag_chunks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        source_id TEXT NOT NULL,
        document_title TEXT NOT NULL,
        section_title TEXT NOT NULL,
        page_index INTEGER NOT NULL,
        section_index INTEGER NOT NULL,
        chunk_index INTEGER NOT NULL,
        content TEXT NOT NULL,
        embedding BLOB NOT NULL,
        UNIQUE(source_id, page_index, section_index, chunk_index)
      )
    ''');
    _database.execute('''
      CREATE INDEX IF NOT EXISTS rag_chunks_source_idx
      ON rag_chunks(source_id, page_index, section_index)
    ''');
    _database.execute('''
      CREATE TABLE IF NOT EXISTS rag_flashcards (
        id TEXT PRIMARY KEY,
        question TEXT NOT NULL,
        answer TEXT NOT NULL,
        source_id TEXT NOT NULL,
        document_title TEXT NOT NULL,
        page_index INTEGER NOT NULL,
        section_index INTEGER NOT NULL,
        stability REAL NOT NULL,
        difficulty REAL NOT NULL,
        last_reviewed_ms INTEGER,
        due_ms INTEGER NOT NULL,
        repetitions INTEGER NOT NULL,
        lapses INTEGER NOT NULL
      )
    ''');
  }

  void _enableSqliteVec(String extensionPath) {
    try {
      _database.select('SELECT load_extension(?)', <Object?>[extensionPath]);
      _database.execute(
        'CREATE VIRTUAL TABLE IF NOT EXISTS rag_vec USING vec0(embedding float[$dimensions])',
      );
      _sqliteVecActive = true;
    } on Object catch (error) {
      _sqliteVecActive = false;
      if (requireSqliteVec) {
        throw StateError('Could not load sqlite-vec extension at $extensionPath: $error');
      }
    }
  }

  /// Transactionally inserts or replaces document chunks and their vectors.
  void upsertChunks(List<EmbeddedDocumentChunk> chunks) {
    _ensureOpen();
    if (chunks.isEmpty) return;
    for (final item in chunks) {
      _validateEmbedding(item.embedding);
      if (item.chunk.sourceId.trim().isEmpty || item.chunk.text.trim().isEmpty) {
        throw ArgumentError('A RAG chunk requires a source id and non-empty text.');
      }
    }

    _database.execute('BEGIN IMMEDIATE');
    try {
      for (final item in chunks) {
        final chunk = item.chunk;
        final blob = _encodeVector(item.embedding);
        final existing = _database.select(
          '''SELECT id FROM rag_chunks
             WHERE source_id = ? AND page_index = ? AND section_index = ? AND chunk_index = ?''',
          <Object?>[chunk.sourceId, chunk.pageIndex, chunk.sectionIndex, chunk.chunkIndex],
        );
        late final int id;
        if (existing.isNotEmpty) {
          id = existing.first['id'] as int;
          if (_sqliteVecActive) {
            _database.execute('DELETE FROM rag_vec WHERE rowid = ?', <Object?>[id]);
          }
          _database.execute(
            '''UPDATE rag_chunks SET document_title = ?, section_title = ?, content = ?, embedding = ?
               WHERE id = ?''',
            <Object?>[
              chunk.documentTitle,
              chunk.sectionTitle,
              chunk.text,
              blob,
              id,
            ],
          );
        } else {
          _database.execute(
            '''INSERT INTO rag_chunks
              (source_id, document_title, section_title, page_index, section_index,
               chunk_index, content, embedding)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
            <Object?>[
              chunk.sourceId,
              chunk.documentTitle,
              chunk.sectionTitle,
              chunk.pageIndex,
              chunk.sectionIndex,
              chunk.chunkIndex,
              chunk.text,
              blob,
            ],
          );
          id = _database.lastInsertRowId;
        }
        if (_sqliteVecActive) {
          _database.execute(
            'INSERT INTO rag_vec(rowid, embedding) VALUES (?, ?)',
            <Object?>[id, blob],
          );
        }
      }
      _database.execute('COMMIT');
    } on Object {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  List<RetrievedChunk> search(Float32List query, {int topK = 5}) {
    _ensureOpen();
    _validateEmbedding(query);
    if (topK < 1) throw ArgumentError.value(topK, 'topK');
    if (_sqliteVecActive) {
      try {
        return _searchWithSqliteVec(query, topK);
      } on Object {
        if (requireSqliteVec) rethrow;
      }
    }
    return _searchExact(query, topK);
  }

  List<RetrievedChunk> _searchWithSqliteVec(Float32List query, int topK) {
    final rows = _database.select(
      '''SELECT c.id, c.source_id, c.document_title, c.section_title,
                c.page_index, c.section_index, c.chunk_index, c.content, v.distance
         FROM rag_vec AS v
         JOIN rag_chunks AS c ON c.id = v.rowid
         WHERE v.embedding MATCH ? AND k = ?
         ORDER BY v.distance ASC''',
      <Object?>[_encodeVector(query), topK],
    );
    return rows.map((row) => RetrievedChunk(
      chunk: _chunkFromRow(row),
      distance: (row['distance'] as num).toDouble(),
    )).toList(growable: false);
  }

  List<RetrievedChunk> _searchExact(Float32List query, int topK) {
    final rows = _database.select(
      '''SELECT id, source_id, document_title, section_title, page_index,
                section_index, chunk_index, content, embedding FROM rag_chunks''',
    );
    final ranked = <RetrievedChunk>[];
    for (final row in rows) {
      final vector = _decodeVector(row['embedding'] as Uint8List);
      ranked.add(RetrievedChunk(
        chunk: _chunkFromRow(row),
        distance: _cosineDistance(query, vector),
      ));
    }
    ranked.sort((left, right) => left.distance.compareTo(right.distance));
    return List<RetrievedChunk>.unmodifiable(ranked.take(topK));
  }

  static double _cosineDistance(Float32List left, Float32List right) {
    var dot = 0.0;
    var leftNorm = 0.0;
    var rightNorm = 0.0;
    for (var index = 0; index < left.length; index++) {
      final l = left[index];
      final r = right[index];
      dot += l * r;
      leftNorm += l * l;
      rightNorm += r * r;
    }
    if (leftNorm == 0 || rightNorm == 0) return 1;
    return 1 - dot / (math.sqrt(leftNorm) * math.sqrt(rightNorm));
  }

  static DocumentChunk _chunkFromRow(Row row) => DocumentChunk(
        sourceId: row['source_id'] as String,
        documentTitle: row['document_title'] as String,
        sectionTitle: row['section_title'] as String,
        pageIndex: row['page_index'] as int,
        sectionIndex: row['section_index'] as int,
        chunkIndex: row['chunk_index'] as int,
        text: row['content'] as String,
      );

  void removeSource(String sourceId) {
    _ensureOpen();
    _database.execute('BEGIN IMMEDIATE');
    try {
      if (_sqliteVecActive) {
        _database.execute(
          'DELETE FROM rag_vec WHERE rowid IN (SELECT id FROM rag_chunks WHERE source_id = ?)',
          <Object?>[sourceId],
        );
      }
      _database.execute('DELETE FROM rag_chunks WHERE source_id = ?', <Object?>[sourceId]);
      _database.execute('DELETE FROM rag_flashcards WHERE source_id = ?', <Object?>[sourceId]);
      _database.execute('COMMIT');
    } on Object {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  void saveFlashcards(Iterable<Flashcard> flashcards) {
    _ensureOpen();
    for (final card in flashcards) {
      _database.execute(
        '''INSERT OR REPLACE INTO rag_flashcards
           (id, question, answer, source_id, document_title, page_index, section_index,
            stability, difficulty, last_reviewed_ms, due_ms, repetitions, lapses)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        <Object?>[
          card.id,
          card.question,
          card.answer,
          card.sourceId,
          card.documentTitle,
          card.pageIndex,
          card.sectionIndex,
          card.state.stability,
          card.state.difficulty,
          card.state.lastReviewedAt?.millisecondsSinceEpoch,
          card.state.dueAt.millisecondsSinceEpoch,
          card.state.repetitions,
          card.state.lapses,
        ],
      );
    }
  }

  List<Flashcard> loadFlashcards({DateTime? dueBefore, int limit = 100}) {
    _ensureOpen();
    if (limit < 1) throw ArgumentError.value(limit, 'limit');
    final rows = dueBefore == null
        ? _database.select(
            'SELECT * FROM rag_flashcards ORDER BY due_ms ASC LIMIT ?',
            <Object?>[limit],
          )
        : _database.select(
            'SELECT * FROM rag_flashcards WHERE due_ms <= ? ORDER BY due_ms ASC LIMIT ?',
            <Object?>[dueBefore.millisecondsSinceEpoch, limit],
          );
    return rows.map((row) {
      final lastReviewedMs = row['last_reviewed_ms'] as int?;
      return Flashcard(
        id: row['id'] as String,
        question: row['question'] as String,
        answer: row['answer'] as String,
        sourceId: row['source_id'] as String,
        documentTitle: row['document_title'] as String,
        pageIndex: row['page_index'] as int,
        sectionIndex: row['section_index'] as int,
        state: FsrsCardState(
          stability: (row['stability'] as num).toDouble(),
          difficulty: (row['difficulty'] as num).toDouble(),
          lastReviewedAt: lastReviewedMs == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(lastReviewedMs, isUtc: true),
          dueAt: DateTime.fromMillisecondsSinceEpoch(row['due_ms'] as int, isUtc: true),
          repetitions: row['repetitions'] as int,
          lapses: row['lapses'] as int,
        ),
      );
    }).toList(growable: false);
  }

  void _validateEmbedding(Float32List vector) {
    if (vector.length != dimensions || vector.any((value) => !value.isFinite)) {
      throw ArgumentError.value(vector.length, 'embedding', 'Expected $dimensions finite values.');
    }
  }

  Uint8List _encodeVector(Float32List vector) {
    final data = ByteData(dimensions * Float32List.bytesPerElement);
    for (var index = 0; index < dimensions; index++) {
      data.setFloat32(index * Float32List.bytesPerElement, vector[index], Endian.little);
    }
    return data.buffer.asUint8List();
  }

  Float32List _decodeVector(Uint8List bytes) {
    if (bytes.length != dimensions * Float32List.bytesPerElement) {
      throw StateError('Stored embedding has an incompatible dimension.');
    }
    final data = ByteData.sublistView(bytes);
    return Float32List.fromList(List<double>.generate(
      dimensions,
      (index) => data.getFloat32(index * Float32List.bytesPerElement, Endian.little),
      growable: false,
    ));
  }

  void _ensureOpen() {
    if (_closed) throw StateError('SQLite vector store is closed.');
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (ownsDatabase) _database.dispose();
  }
}
