import 'package:meta/meta.dart';

import 'fsrs_card_state.dart';

@immutable
final class Flashcard {
  const Flashcard({
    required this.id,
    required this.question,
    required this.answer,
    required this.sourceId,
    required this.documentTitle,
    required this.pageIndex,
    required this.sectionIndex,
    required this.state,
  });

  final String id;
  final String question;
  final String answer;
  final String sourceId;
  final String documentTitle;
  final int pageIndex;
  final int sectionIndex;
  final FsrsCardState state;

  String citation(int index) =>
      '[$index] $documentTitle, page ${pageIndex + 1}, section ${sectionIndex + 1}';

  Flashcard copyWith({FsrsCardState? state}) => Flashcard(
        id: id,
        question: question,
        answer: answer,
        sourceId: sourceId,
        documentTitle: documentTitle,
        pageIndex: pageIndex,
        sectionIndex: sectionIndex,
        state: state ?? this.state,
      );
}
