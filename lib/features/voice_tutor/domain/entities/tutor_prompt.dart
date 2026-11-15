import 'package:meta/meta.dart';

/// A user request passed to a tutor engine.
///
/// Identifiers are assigned by the application layer. This value object does
/// not generate random IDs, which keeps deterministic testing and replay easy.
@immutable
final class TutorPrompt {
  TutorPrompt({
    required this.requestId,
    required this.text,
    required this.createdAt,
  }) {
    if (requestId.trim().isEmpty || requestId.length > 128) {
      throw ArgumentError.value(requestId, 'requestId', 'Invalid request identifier.');
    }
    if (text.trim().isEmpty || text.length > maxTextLength) {
      throw ArgumentError.value(text.length, 'text.length', 'Invalid prompt text length.');
    }
  }

  static const int maxTextLength = 16000;

  final String requestId;
  final String text;
  final DateTime createdAt;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TutorPrompt &&
          requestId == other.requestId &&
          text == other.text &&
          createdAt == other.createdAt;

  @override
  int get hashCode => Object.hash(requestId, text, createdAt);
}
