import 'dart:typed_data';

import 'package:meta/meta.dart';

@immutable
final class DocumentChunk {
  const DocumentChunk({
    required this.sourceId,
    required this.documentTitle,
    required this.sectionTitle,
    required this.pageIndex,
    required this.sectionIndex,
    required this.chunkIndex,
    required this.text,
  });

  final String sourceId;
  final String documentTitle;
  final String sectionTitle;
  final int pageIndex;
  final int sectionIndex;
  final int chunkIndex;
  final String text;

  String get identity => '$sourceId:$pageIndex:$sectionIndex:$chunkIndex';
}

@immutable
final class RetrievedChunk {
  const RetrievedChunk({required this.chunk, required this.distance});

  final DocumentChunk chunk;
  final double distance;

  String citation(int index) =>
      '[$index] ${chunk.documentTitle}, page ${chunk.pageIndex + 1}, '
      '${chunk.sectionTitle.isEmpty ? 'section ${chunk.sectionIndex + 1}' : chunk.sectionTitle}';
}

@immutable
final class EmbeddedDocumentChunk {
  const EmbeddedDocumentChunk({required this.chunk, required this.embedding});

  final DocumentChunk chunk;
  final Float32List embedding;
}
