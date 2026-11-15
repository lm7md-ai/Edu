import 'package:edu/features/rag_notes/domain/entities/document_chunk.dart';
import 'package:edu/features/rag_notes/domain/entities/flashcard.dart';
import 'package:edu/features/rag_notes/domain/entities/fsrs_card_state.dart';

/// Generates source-linked recall cards from indexed note chunks.
/// Explicit Markdown `Q:` / `A:` pairs are honored; other prose becomes a
/// deterministic cloze card using a content word from its source sentence.
final class FlashcardGenerator {
  FlashcardGenerator({this.cardsPerChunk = 2}) {
    if (cardsPerChunk < 1 || cardsPerChunk > 10) {
      throw ArgumentError.value(cardsPerChunk, 'cardsPerChunk');
    }
  }

  final int cardsPerChunk;

  List<Flashcard> generate(Iterable<DocumentChunk> chunks, {DateTime? now}) {
    final dueAt = (now ?? DateTime.now()).toUtc();
    final result = <Flashcard>[];
    for (final chunk in chunks) {
      final explicit = _explicitQuestionAnswerCards(chunk, dueAt);
      if (explicit.isNotEmpty) {
        result.addAll(explicit.take(cardsPerChunk));
        continue;
      }
      final sentences = chunk.text
          .split(RegExp(r'(?<=[.!?؟])\s+'))
          .map((sentence) => sentence.trim())
          .where((sentence) => sentence.length >= 24);
      var localIndex = 0;
      for (final sentence in sentences) {
        if (localIndex >= cardsPerChunk) break;
        final answerWord = _selectRecallTerm(sentence);
        if (answerWord == null) continue;
        final cloze = sentence.replaceFirst(answerWord, '_____');
        result.add(Flashcard(
          id: '${chunk.identity}:$localIndex',
          question: 'Complete the key statement from ${chunk.sectionTitle}:\n$cloze',
          answer: answerWord,
          sourceId: chunk.sourceId,
          documentTitle: chunk.documentTitle,
          pageIndex: chunk.pageIndex,
          sectionIndex: chunk.sectionIndex,
          state: FsrsCardState(dueAt: dueAt),
        ));
        localIndex++;
      }
    }
    return List<Flashcard>.unmodifiable(result);
  }

  List<Flashcard> _explicitQuestionAnswerCards(DocumentChunk chunk, DateTime dueAt) {
    final lines = chunk.text.split('\n');
    final cards = <Flashcard>[];
    String? question;
    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.toLowerCase().startsWith('q:')) {
        question = line.substring(2).trim();
      } else if (line.toLowerCase().startsWith('a:') && question != null) {
        final answer = line.substring(2).trim();
        if (question.isNotEmpty && answer.isNotEmpty) {
          cards.add(Flashcard(
            id: '${chunk.identity}:qa:${cards.length}',
            question: question,
            answer: answer,
            sourceId: chunk.sourceId,
            documentTitle: chunk.documentTitle,
            pageIndex: chunk.pageIndex,
            sectionIndex: chunk.sectionIndex,
            state: FsrsCardState(dueAt: dueAt),
          ));
        }
        question = null;
      }
    }
    return cards;
  }

  static String? _selectRecallTerm(String sentence) {
    const stopWords = <String>{
      'about', 'after', 'also', 'because', 'been', 'being', 'between', 'could',
      'first', 'from', 'have', 'into', 'more', 'most', 'other', 'should',
      'their', 'there', 'these', 'those', 'through', 'under', 'using', 'very',
      'what', 'when', 'where', 'which', 'while', 'with', 'would',
      'هذا', 'هذه', 'ذلك', 'التي', 'الذي', 'على', 'إلى', 'من', 'في', 'عن',
    };
    final candidates = sentence.split(RegExp(r'\s+')).map((word) => word
        .replaceAll(RegExp(r'^[.,!?؟،؛:(){}\[\]"“”]+|[.,!?؟،؛:(){}\[\]"“”]+$'), '')
        .trim()).where((word) => word.length >= 4 && !stopWords.contains(word.toLowerCase()));
    final words = candidates.toList(growable: false);
    if (words.isEmpty) return null;
    words.sort((left, right) => right.length.compareTo(left.length));
    return words.first;
  }
}
