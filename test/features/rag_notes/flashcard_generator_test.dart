import 'package:edu/features/rag_notes/data/flashcard_generator.dart';
import 'package:edu/features/rag_notes/domain/entities/document_chunk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final generator = FlashcardGenerator(cardsPerChunk: 2);

  test('creates cited cloze cards from prose chunks', () {
    final cards = generator.generate(
      <DocumentChunk>[_chunk(
        text: 'Photosynthesis converts sunlight into chemical energy. Chlorophyll absorbs light in leaves.',
      )],
      now: DateTime.utc(2026, 4, 1),
    );

    expect(cards, hasLength(2));
    expect(cards.first.question, contains('_____'));
    expect(cards.first.answer, isNotEmpty);
    expect(cards.first.sourceId, 'notes-7');
    expect(cards.first.documentTitle, 'Plant Biology');
    expect(cards.first.pageIndex, 3);
    expect(cards.first.sectionIndex, 2);
    expect(cards.first.state.isNew, isTrue);
    expect(cards.first.state.dueAt, DateTime.utc(2026, 4, 1));
  });

  test('honors explicit Markdown Q/A pairs and respects per-chunk limit', () {
    final cards = generator.generate(<DocumentChunk>[_chunk(
      text: 'Q: What is the nucleus?\nA: The organelle that stores DNA.\n'
          'Q: Where is DNA stored?\nA: In the nucleus.\n'
          'A prose line that should not become another card.',
    )]);

    expect(cards, hasLength(2));
    expect(cards.first.question, 'What is the nucleus?');
    expect(cards.first.answer, 'The organelle that stores DNA.');
    expect(cards.last.question, 'Where is DNA stored?');
    expect(cards.last.answer, 'In the nucleus.');
    expect(cards.map((card) => card.id).toSet(), hasLength(2));
  });

  test('skips short or non-recallable fragments and validates generation limits', () {
    expect(generator.generate(<DocumentChunk>[_chunk(text: 'Too short.')]), isEmpty);
    expect(() => FlashcardGenerator(cardsPerChunk: 0), throwsArgumentError);
    expect(() => FlashcardGenerator(cardsPerChunk: 11), throwsArgumentError);
  });
}

DocumentChunk _chunk({required String text}) => DocumentChunk(
      sourceId: 'notes-7',
      documentTitle: 'Plant Biology',
      sectionTitle: 'Energy conversion',
      pageIndex: 3,
      sectionIndex: 2,
      chunkIndex: 0,
      text: text,
    );
