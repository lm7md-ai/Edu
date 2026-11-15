import 'package:edu/features/rag_notes/data/fsrs_scheduler.dart';
import 'package:edu/features/rag_notes/domain/entities/flashcard.dart';
import 'package:edu/features/rag_notes/domain/entities/fsrs_card_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FsrsScheduler', () {
    final scheduler = FsrsScheduler();
    final now = DateTime.utc(2026, 1, 1);

    test('retrievability follows the FSRS forgetting curve', () {
      expect(
        scheduler.retrievability(stabilityDays: 2, elapsedDays: 0),
        closeTo(1, 1e-12),
      );
      final elapsedForHalfRetention = 3 * 2 / (19 / 81);
      expect(
        scheduler.retrievability(
          stabilityDays: 2,
          elapsedDays: elapsedForHalfRetention,
        ),
        closeTo(0.5, 1e-12),
      );
      expect(
        scheduler.retrievability(stabilityDays: 2, elapsedDays: 90),
        lessThan(0.5),
      );
    });

    test('first review initializes stability from each rating and schedules due date', () {
      final expectedStability = <FsrsRating, double>{
        FsrsRating.again: 0.4,
        FsrsRating.hard: 0.6,
        FsrsRating.good: 2.4,
        FsrsRating.easy: 5.8,
      };
      final intervals = <FsrsRating, int>{};
      for (final rating in FsrsRating.values) {
        final reviewed = scheduler.review(_card(now), rating, reviewedAt: now);
        expect(reviewed.state.stability, expectedStability[rating]);
        expect(reviewed.state.difficulty, allOf(greaterThanOrEqualTo(1), lessThanOrEqualTo(10)));
        expect(reviewed.state.lastReviewedAt, now);
        expect(reviewed.state.repetitions, 1);
        expect(reviewed.state.lapses, rating == FsrsRating.again ? 1 : 0);
        final interval = reviewed.state.dueAt.difference(now).inDays;
        expect(interval, greaterThanOrEqualTo(1));
        intervals[rating] = interval;
      }
      expect(intervals[FsrsRating.again], 1);
      expect(intervals[FsrsRating.hard], 1);
      expect(intervals[FsrsRating.good], 2);
      expect(intervals[FsrsRating.easy], 6);
    });

    test('review updates stability, difficulty, retrievability and counters', () {
      final first = scheduler.review(_card(now), FsrsRating.good, reviewedAt: now);
      final dueLater = now.add(const Duration(days: 5));
      final hard = scheduler.review(first, FsrsRating.hard, reviewedAt: dueLater);
      final good = scheduler.review(first, FsrsRating.good, reviewedAt: dueLater);
      final easy = scheduler.review(first, FsrsRating.easy, reviewedAt: dueLater);
      final again = scheduler.review(first, FsrsRating.again, reviewedAt: dueLater);

      expect(hard.state.stability, lessThan(good.state.stability));
      expect(easy.state.stability, greaterThan(good.state.stability));
      expect(again.state.stability, lessThan(first.state.stability));
      expect(again.state.difficulty, greaterThan(good.state.difficulty));
      expect(easy.state.difficulty, lessThan(good.state.difficulty));
      expect(hard.state.repetitions, 2);
      expect(again.state.lapses, 1);
      expect(good.state.lastReviewedAt, dueLater);
      expect(good.state.dueAt.isAfter(dueLater), isTrue);
    });

    test('intervals obey the desired-retention formula and configured cap', () {
      final desired = FsrsScheduler(desiredRetention: 0.8);
      final moreConservative = FsrsScheduler(desiredRetention: 0.95);
      final card = _card(now);
      final lowerRetention = desired.review(card, FsrsRating.easy, reviewedAt: now);
      final higherRetention = moreConservative.review(card, FsrsRating.easy, reviewedAt: now);
      expect(higherRetention.state.dueAt.isBefore(lowerRetention.state.dueAt), isTrue);

      final capped = FsrsScheduler(maximumIntervalDays: 3)
          .review(card, FsrsRating.easy, reviewedAt: now);
      expect(capped.state.dueAt.difference(now).inDays, lessThanOrEqualTo(3));
    });

    test('rejects invalid scheduler parameters and elapsed-time inputs', () {
      expect(() => FsrsScheduler(desiredRetention: 1), throwsArgumentError);
      expect(() => FsrsScheduler(maximumIntervalDays: 0), throwsArgumentError);
      expect(() => FsrsScheduler(weights: const <double>[1]), throwsArgumentError);
      expect(
        () => scheduler.retrievability(stabilityDays: 0, elapsedDays: 1),
        throwsArgumentError,
      );
      expect(
        () => scheduler.retrievability(stabilityDays: 1, elapsedDays: -1),
        throwsArgumentError,
      );
    });
  });
}

Flashcard _card(DateTime now) => Flashcard(
      id: 'card-1',
      question: 'What is FSRS?',
      answer: 'A spaced-repetition scheduler.',
      sourceId: 'source-1',
      documentTitle: 'Study notes',
      pageIndex: 0,
      sectionIndex: 0,
      state: FsrsCardState(dueAt: now),
    );
