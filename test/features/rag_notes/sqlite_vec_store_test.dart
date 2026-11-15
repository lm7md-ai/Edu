import 'dart:typed_data';

import 'package:edu/features/rag_notes/data/sqlite_vec_store.dart';
import 'package:edu/features/rag_notes/domain/entities/document_chunk.dart';
import 'package:edu/features/rag_notes/domain/entities/flashcard.dart';
import 'package:edu/features/rag_notes/domain/entities/fsrs_card_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late SqliteVecStore store;

  setUp(() {
    store = SqliteVecStore(database: sqlite3.openInMemory(), dimensions: 3, ownsDatabase: true);
  });

  tearDown(() => store.close());

  test('cosine retrieval returns top-K local chunks with source metadata citations', () {
    store.upsertChunks(<EmbeddedDocumentChunk>[
      _embedded(_chunk(
        sourceId: 'biology-1',
        title: 'Biology Notes',
        page: 2,
        section: 4,
        index: 0,
        text: 'Mitochondria generate cellular energy.',
      ), <double>[1, 0, 0]),
      _embedded(_chunk(
        sourceId: 'biology-1',
        title: 'Biology Notes',
        page: 3,
        section: 5,
        index: 0,
        text: 'Chloroplasts capture light energy.',
      ), <double>[0.8, 0.2, 0]),
      _embedded(_chunk(
        sourceId: 'history-1',
        title: 'History Notes',
        page: 0,
        section: 1,
        index: 0,
        text: 'The treaty ended the conflict.',
      ), <double>[0, 0, 1]),
    ]);

    final results = store.search(Float32List.fromList(<double>[1, 0, 0]), topK: 2);

    expect(results, hasLength(2));
    expect(results.first.chunk.text, 'Mitochondria generate cellular energy.');
    expect(results.first.distance, closeTo(0, 1e-6));
    expect(results.first.citation(1), '[1] Biology Notes, page 3, Section 5');
    expect(results[1].chunk.text, 'Chloroplasts capture light energy.');
    expect(results.every((result) => result.distance < 1), isTrue);
  });

  test('upsert replaces a source chunk and removeSource deletes chunks and cards', () {
    final original = _embedded(_chunk(
      sourceId: 'source', title: 'Title', page: 0, section: 0, index: 0, text: 'old passage',
    ), <double>[1, 0, 0]);
    store.upsertChunks(<EmbeddedDocumentChunk>[original]);
    store.upsertChunks(<EmbeddedDocumentChunk>[
      _embedded(original.chunk.copyWithForTest(text: 'replacement passage'), <double>[0, 1, 0]),
    ]);
    expect(store.search(Float32List.fromList(<double>[0, 1, 0])).single.chunk.text,
        'replacement passage');

    final card = Flashcard(
      id: 'flash-1',
      question: 'Question',
      answer: 'Answer',
      sourceId: 'source',
      documentTitle: 'Title',
      pageIndex: 0,
      sectionIndex: 0,
      state: FsrsCardState(dueAt: DateTime.utc(2026, 1, 2)),
    );
    store.saveFlashcards(<Flashcard>[card]);
    expect(store.loadFlashcards(), hasLength(1));

    store.removeSource('source');
    expect(store.search(Float32List.fromList(<double>[0, 1, 0])), isEmpty);
    expect(store.loadFlashcards(), isEmpty);
  });

  test('rejects wrong dimensions, non-finite vectors, and invalid search limits', () {
    final chunk = _chunk(
      sourceId: 's', title: 't', page: 0, section: 0, index: 0, text: 'chunk',
    );
    expect(
      () => store.upsertChunks(<EmbeddedDocumentChunk>[
        EmbeddedDocumentChunk(chunk: chunk, embedding: Float32List(2)),
      ]),
      throwsArgumentError,
    );
    expect(
      () => store.upsertChunks(<EmbeddedDocumentChunk>[
        _embedded(chunk, <double>[double.nan, 0, 0]),
      ]),
      throwsArgumentError,
    );
    expect(() => store.search(Float32List(3), topK: 0), throwsArgumentError);
  });

  test('stored cards preserve review state and due-date filtering', () {
    final now = DateTime.utc(2026, 3, 1);
    final due = Flashcard(
      id: 'due',
      question: 'Due now',
      answer: 'A',
      sourceId: 's',
      documentTitle: 'Doc',
      pageIndex: 1,
      sectionIndex: 2,
      state: FsrsCardState(
        stability: 4.25,
        difficulty: 5.5,
        lastReviewedAt: now.subtract(const Duration(days: 4)),
        dueAt: now,
        repetitions: 3,
        lapses: 1,
      ),
    );
    final future = due.copyWithForTest(
      id: 'future',
      state: FsrsCardState(dueAt: now.add(const Duration(days: 1))),
    );
    store.saveFlashcards(<Flashcard>[due, future]);

    final loaded = store.loadFlashcards(dueBefore: now);
    expect(loaded.map((card) => card.id), <String>['due']);
    expect(loaded.single.state.stability, 4.25);
    expect(loaded.single.state.difficulty, 5.5);
    expect(loaded.single.state.repetitions, 3);
    expect(loaded.single.state.lapses, 1);
    expect(loaded.single.state.lastReviewedAt, due.state.lastReviewedAt);
  });
}

DocumentChunk _chunk({
  required String sourceId,
  required String title,
  required int page,
  required int section,
  required int index,
  required String text,
}) => DocumentChunk(
      sourceId: sourceId,
      documentTitle: title,
      sectionTitle: 'Section ${section + 1}',
      pageIndex: page,
      sectionIndex: section,
      chunkIndex: index,
      text: text,
    );

EmbeddedDocumentChunk _embedded(DocumentChunk chunk, List<double> values) =>
    EmbeddedDocumentChunk(chunk: chunk, embedding: Float32List.fromList(values));

extension on DocumentChunk {
  DocumentChunk copyWithForTest({String? text}) => DocumentChunk(
        sourceId: sourceId,
        documentTitle: documentTitle,
        sectionTitle: sectionTitle,
        pageIndex: pageIndex,
        sectionIndex: sectionIndex,
        chunkIndex: chunkIndex,
        text: text ?? this.text,
      );
}

extension on Flashcard {
  Flashcard copyWithForTest({String? id, FsrsCardState? state}) => Flashcard(
        id: id ?? this.id,
        question: question,
        answer: answer,
        sourceId: sourceId,
        documentTitle: documentTitle,
        pageIndex: pageIndex,
        sectionIndex: sectionIndex,
        state: state ?? this.state,
      );
}
