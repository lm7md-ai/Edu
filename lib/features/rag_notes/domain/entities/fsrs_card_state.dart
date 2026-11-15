import 'package:meta/meta.dart';

@immutable
final class FsrsCardState {
  const FsrsCardState({
    this.stability = 0,
    this.difficulty = 0,
    this.lastReviewedAt,
    required this.dueAt,
    this.repetitions = 0,
    this.lapses = 0,
  });

  final double stability;
  final double difficulty;
  final DateTime? lastReviewedAt;
  final DateTime dueAt;
  final int repetitions;
  final int lapses;

  bool get isNew => repetitions == 0 && lastReviewedAt == null;

  FsrsCardState copyWith({
    double? stability,
    double? difficulty,
    DateTime? lastReviewedAt,
    DateTime? dueAt,
    int? repetitions,
    int? lapses,
  }) =>
      FsrsCardState(
        stability: stability ?? this.stability,
        difficulty: difficulty ?? this.difficulty,
        lastReviewedAt: lastReviewedAt ?? this.lastReviewedAt,
        dueAt: dueAt ?? this.dueAt,
        repetitions: repetitions ?? this.repetitions,
        lapses: lapses ?? this.lapses,
      );
}
