import 'package:meta/meta.dart';

@immutable
final class CurriculumNote {
  const CurriculumNote({
    required this.sourceId,
    required this.title,
    required this.filename,
    required this.content,
    required this.updatedAt,
  });

  final String sourceId;
  final String title;
  final String filename;
  final String content;
  final DateTime updatedAt;
}
