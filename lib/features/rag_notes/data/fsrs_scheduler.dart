import 'dart:math' as math;

import 'package:edu/features/rag_notes/domain/entities/flashcard.dart';
import 'package:edu/features/rag_notes/domain/entities/fsrs_card_state.dart';

/// Four response grades used by FSRS spaced repetition.
enum FsrsRating { again, hard, good, easy }

/// FSRS-4.5 scheduler with the published 17-parameter default preset.
///
/// Stability is measured in days. Difficulty is clamped to [1, 10],
/// retrievability uses the FSRS forgetting curve, and intervals are rounded to
/// whole days at the configured desired retention.
final class FsrsScheduler {
  FsrsScheduler({
    this.desiredRetention = 0.9,
    this.maximumIntervalDays = 36500,
    List<double> weights = defaultWeights,
  }) : weights = List<double>.unmodifiable(weights) {
    if (!desiredRetention.isFinite || desiredRetention <= 0 || desiredRetention >= 1) {
      throw ArgumentError.value(desiredRetention, 'desiredRetention', 'Must be between 0 and 1.');
    }
    if (maximumIntervalDays < 1 || weights.length != 17 ||
        weights.any((weight) => !weight.isFinite)) {
      throw ArgumentError('FSRS maximum interval or parameter vector is invalid.');
    }
  }

  static const List<double> defaultWeights = <double>[
    0.4, 0.6, 2.4, 5.8, 4.93, 0.94, 0.86, 0.01, 1.49,
    0.14, 0.94, 2.18, 0.05, 0.34, 1.26, 0.29, 2.61,
  ];
  static const double _forgettingFactor = 19 / 81;
  static const double _decay = -0.5;

  final double desiredRetention;
  final int maximumIntervalDays;
  final List<double> weights;

  double retrievability({required double stabilityDays, required double elapsedDays}) {
    if (!stabilityDays.isFinite || stabilityDays <= 0 ||
        !elapsedDays.isFinite || elapsedDays < 0) {
      throw ArgumentError('Stability must be positive and elapsed time non-negative.');
    }
    return math.pow(1 + _forgettingFactor * elapsedDays / stabilityDays, _decay).toDouble();
  }

  /// Schedules a review at [reviewedAt], returning a new immutable card value.
  Flashcard review(Flashcard card, FsrsRating rating, {DateTime? reviewedAt}) {
    final now = (reviewedAt ?? DateTime.now()).toUtc();
    final prior = card.state;
    final grade = rating.index + 1;
    final elapsedDays = prior.lastReviewedAt == null
        ? 0.0
        : now.difference(prior.lastReviewedAt!).inMicroseconds /
            (Duration.microsecondsPerSecond * Duration.secondsPerMinute *
                Duration.minutesPerHour * Duration.hoursPerDay);
    final retrievability = prior.stability > 0
        ? this.retrievability(
            stabilityDays: prior.stability,
            elapsedDays: math.max(0.0, elapsedDays).toDouble(),
          )
        : 1.0;

    final difficulty = prior.isNew
        ? _initialDifficulty(grade)
        : _nextDifficulty(prior.difficulty, grade);
    final stability = prior.isNew
        ? weights[grade - 1]
        : _nextStability(
            prior.stability,
            difficulty: difficulty,
            grade: grade,
            retrievability: retrievability,
          );
    final intervalDays = _intervalForStability(stability);
    final nextState = FsrsCardState(
      stability: stability,
      difficulty: difficulty,
      lastReviewedAt: now,
      dueAt: now.add(Duration(days: intervalDays)),
      repetitions: prior.repetitions + 1,
      lapses: prior.lapses + (rating == FsrsRating.again ? 1 : 0),
    );
    return card.copyWith(state: nextState);
  }

  double _initialDifficulty(int grade) =>
      _clampDouble(weights[4] - math.exp(weights[5] * (grade - 1)) + 1, 1, 10);

  double _nextDifficulty(double current, int grade) {
    final delta = current - weights[6] * (grade - 3);
    final meanReverted = weights[7] * _initialDifficulty(3) + (1 - weights[7]) * delta;
    return _clampDouble(meanReverted, 1, 10);
  }

  double _nextStability(
    double current, {
    required double difficulty,
    required int grade,
    required double retrievability,
  }) {
    if (grade == FsrsRating.again.index + 1) {
      final updated = weights[11] * math.pow(difficulty, -weights[12]) *
          (math.pow(current + 1, weights[13]) - 1) *
          math.exp(weights[14] * (1 - retrievability));
      return _clampDouble(updated.toDouble(), 0.01, maximumIntervalDays.toDouble());
    }

    final hardPenalty = grade == FsrsRating.hard.index + 1 ? weights[15] : 1.0;
    final easyBonus = grade == FsrsRating.easy.index + 1 ? weights[16] : 1.0;
    final growth = math.exp(weights[8]) * (11 - difficulty) *
        math.pow(current, -weights[9]) *
        (math.exp(weights[10] * (1 - retrievability)) - 1) *
        hardPenalty * easyBonus;
    return _clampDouble(current * (1 + growth), 0.01, maximumIntervalDays.toDouble());
  }

  int _intervalForStability(double stability) {
    final interval = stability / _forgettingFactor *
        (math.pow(desiredRetention, 1 / _decay) - 1);
    return _clampInt(interval.round(), 1, maximumIntervalDays);
  }

  static double _clampDouble(double value, double min, double max) =>
      value.clamp(min, max).toDouble();

  static int _clampInt(int value, int min, int max) => value.clamp(min, max).toInt();
}
