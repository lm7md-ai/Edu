import 'package:edu/features/rag_notes/data/fsrs_scheduler.dart';
import 'package:edu/features/rag_notes/domain/entities/flashcard.dart';
import 'package:flutter/material.dart';

/// Simple accessible review UI with source citation and all FSRS ratings.
final class FlashcardReviewScreen extends StatefulWidget {
  const FlashcardReviewScreen({
    required this.cards,
    required this.scheduler,
    required this.onCardReviewed,
    super.key,
  });

  final List<Flashcard> cards;
  final FsrsScheduler scheduler;
  final Future<void> Function(Flashcard updatedCard) onCardReviewed;

  @override
  State<FlashcardReviewScreen> createState() => _FlashcardReviewScreenState();
}

final class _FlashcardReviewScreenState extends State<FlashcardReviewScreen> {
  int _index = 0;
  bool _showAnswer = false;
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    if (widget.cards.isEmpty) {
      return const Center(child: Text('No cards are due. Add curriculum notes to create a review deck.'));
    }
    final card = widget.cards[_index.clamp(0, widget.cards.length - 1).toInt()];
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Card(
          margin: const EdgeInsets.all(24),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text('Review ${_index + 1} of ${widget.cards.length}',
                    style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 16),
                SelectableText(
                  _showAnswer ? card.answer : card.question,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 16),
                Text(card.citation(1), style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 20),
                if (!_showAnswer)
                  FilledButton.icon(
                    onPressed: () => setState(() => _showAnswer = true),
                    icon: const Icon(Icons.visibility),
                    label: const Text('Show answer'),
                  )
                else
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      for (final rating in FsrsRating.values)
                        FilledButton.tonal(
                          onPressed: _saving ? null : () => _rate(card, rating),
                          child: Text(_ratingLabel(rating)),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _rate(Flashcard card, FsrsRating rating) async {
    setState(() => _saving = true);
    try {
      final updated = widget.scheduler.review(card, rating);
      await widget.onCardReviewed(updated);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _showAnswer = false;
        if (_index + 1 < widget.cards.length) _index++;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save this review: $error')),
      );
    }
  }

  static String _ratingLabel(FsrsRating rating) => switch (rating) {
        FsrsRating.again => 'Again',
        FsrsRating.hard => 'Hard',
        FsrsRating.good => 'Good',
        FsrsRating.easy => 'Easy',
      };
}
