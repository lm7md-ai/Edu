import 'package:edu/features/rag_notes/data/fsrs_scheduler.dart';
import 'package:edu/features/rag_notes/domain/entities/flashcard.dart';
import 'package:edu/features/rag_notes/domain/entities/fsrs_card_state.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _ScheduleExpectation = ({
  double difficulty,
  double stability,
  int intervalDays,
  int lapses,
});

void main() {
  group('FsrsScheduler', () {
    final scheduler = FsrsScheduler();
    final now = DateTime.utc(2026, 1, 1);

    test('retrievability follows the FSRS forgetting curve', () {
      expect(
        scheduler.retrievability(stabilityDays: 2, elapsedDays: 0),
        closeTo(1, 1e-12),
      );
      expect(
        scheduler.retrievability(stabilityDays: 2, elapsedDays: 5),
        closeTo(0.8195941821161696, 1e-12),
      );
      // With R(t) = (1 + (19/81) * t / S)^-0.5, this elapsed
      // interval gives exactly one-half retrievability.
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

    test(
      'first review initializes difficulty, stability, counters and due date by grade',
      () {
        const expected = <FsrsRating, _ScheduleExpectation>{
          FsrsRating.again: (
            difficulty: 4.93,
            stability: 0.4,
            intervalDays: 1,
            lapses: 1,
          ),
          FsrsRating.hard: (
            difficulty: 3.3700185816707284,
            stability: 0.6,
            intervalDays: 1,
            lapses: 0,
          ),
          FsrsRating.good: (
            difficulty: 1,
            stability: 2.4,
            intervalDays: 2,
            lapses: 0,
          ),
          FsrsRating.easy: (
            difficulty: 1,
            stability: 5.8,
            intervalDays: 6,
            lapses: 0,
          ),
        };

        for (final rating in FsrsRating.values) {
          final reviewed = scheduler.review(_card(now), rating, reviewedAt: now);
          final reference = expected[rating]!;
          expect(reviewed.state.difficulty, closeTo(reference.difficulty, 1e-12));
          expect(reviewed.state.stability, closeTo(reference.stability, 1e-12));
          expect(reviewed.state.lastReviewedAt, now);
          expect(
            reviewed.state.dueAt,
            now.add(Duration(days: reference.intervalDays)),
          );
          expect(reviewed.state.repetitions, 1);
          expect(reviewed.state.lapses, reference.lapses);
        }
      },
    );

    test('repeat-review difficulty, stability and intervals match FSRS-4.5 math', () {
      final firstGood = scheduler.review(_card(now), FsrsRating.good, reviewedAt: now);
      final reviewedAt = now.add(const Duration(days: 5));
      final retrievability = scheduler.retrievability(
        stabilityDays: firstGood.state.stability,
        elapsedDays: 5,
      );
      expect(retrievability, closeTo(0.8195941821161696, 1e-12));

      const expected = <FsrsRating, _ScheduleExpectation>{
        FsrsRating.again: (
          difficulty: 2.7028,
          stability: 1.3435264552538189,
          intervalDays: 1,
          lapses: 1,
        ),
        FsrsRating.hard: (
          difficulty: 1.8514,
          stability: 7.019084321820863,
          intervalDays: 7,
          lapses: 0,
        ),
        FsrsRating.good: (
          difficulty: 1,
          stability: 19.810179668797495,
          intervalDays: 20,
          lapses: 0,
        ),
        FsrsRating.easy: (
          difficulty: 1,
          stability: 47.840568935561464,
          intervalDays: 48,
          lapses: 0,
        ),
      };

      for (final rating in FsrsRating.values) {
        final reviewed = scheduler.review(firstGood, rating, reviewedAt: reviewedAt);
        final reference = expected[rating]!;
        expect(reviewed.state.difficulty, closeTo(reference.difficulty, 1e-10));
        expect(reviewed.state.stability, closeTo(reference.stability, 1e-10));
        expect(
          reviewed.state.dueAt,
          reviewedAt.add(Duration(days: reference.intervalDays)),
        );
        expect(reviewed.state.lastReviewedAt, reviewedAt);
        expect(reviewed.state.repetitions, 2);
        expect(reviewed.state.lapses, reference.lapses);
      }

      // Review branches are immutable and do not mutate the shared prior card.
      expect(firstGood.state.stability, 2.4);
      expect(firstGood.state.repetitions, 1);
      expect(firstGood.state.lapses, 0);
    });

    test('desired retention uses the stability-to-interval formula', () {
      final lowerRetention = FsrsScheduler(desiredRetention: 0.8)
          .review(_card(now), FsrsRating.good, reviewedAt: now);
      final higherRetention = FsrsScheduler(desiredRetention: 0.95)
          .review(_card(now), FsrsRating.easy, reviewedAt: now);

      // I = S / (19/81) * (R^(-2) - 1), rounded to whole days.
      expect(lowerRetention.state.dueAt, now.add(const Duration(days: 6)));
      expect(higherRetention.state.dueAt, now.add(const Duration(days: 3)));
      expect(higherRetention.state.dueAt.isBefore(lowerRetention.state.dueAt), isTrue);
    });

    test('review intervals are rounded to days, bounded below and capped above', () {
      final newAgain = scheduler.review(_card(now), FsrsRating.again, reviewedAt: now);
      expect(newAgain.state.dueAt, now.add(const Duration(days: 1)));

      final capped = FsrsScheduler(maximumIntervalDays: 3)
          .review(_card(now), FsrsRating.easy, reviewedAt: now);
      expect(capped.state.dueAt, now.add(const Duration(days: 3)));

      final longMemory = _card(now).copyWith(
        state: FsrsCardState(
          stability: 50000,
          difficulty: 5,
          lastReviewedAt: now,
          dueAt: now,
          repetitions: 8,
        ),
      );
      final stillCapped = scheduler.review(
        longMemory,
        FsrsRating.easy,
        reviewedAt: now.add(const Duration(days: 1)),
      );
      expect(stillCapped.state.dueAt, now.add(const Duration(days: 36501)));
    });

    test('difficulty stays clamped and lapse counters change only for Again', () {
      final initial = scheduler.review(_card(now), FsrsRating.again, reviewedAt: now);
      expect(initial.state.difficulty, inInclusiveRange(1, 10));

      final repeated = scheduler.review(
        initial,
        FsrsRating.easy,
        reviewedAt: now.add(const Duration(days: 2)),
      );
      expect(repeated.state.difficulty, inInclusiveRange(1, 10));
      expect(repeated.state.repetitions, 2);
      expect(repeated.state.lapses, 1);
    });

    test('rejects invalid scheduler parameters and elapsed-time inputs', () {
      expect(() => FsrsScheduler(desiredRetention: 1), throwsArgumentError);
      expect(() => FsrsScheduler(desiredRetention: double.nan), throwsArgumentError);
      expect(() => FsrsScheduler(maximumIntervalDays: 0), throwsArgumentError);
      expect(() => FsrsScheduler(weights: const <double>[1]), throwsArgumentError);
      expect(
        () => FsrsScheduler(
          weights: <double>[
            ...FsrsScheduler.defaultWeights.take(16),
            double.infinity,
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => scheduler.retrievability(stabilityDays: 0, elapsedDays: 1),
        throwsArgumentError,
      );
      expect(
        () => scheduler.retrievability(
          stabilityDays: double.infinity,
          elapsedDays: 1,
        ),
        throwsArgumentError,
      );
      expect(
        () => scheduler.retrievability(stabilityDays: 1, elapsedDays: -1),
        throwsArgumentError,
      );
      expect(
        () => scheduler.retrievability(stabilityDays: 1, elapsedDays: double.nan),
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
