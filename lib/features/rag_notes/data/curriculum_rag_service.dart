import 'package:edu/features/rag_notes/data/sqlite_vec_store.dart';
import 'package:edu/features/rag_notes/domain/entities/document_chunk.dart';
import 'package:edu/features/voice_tutor/data/orchestrator/dynamic_model_orchestrator.dart';

/// Retrieves locally indexed curriculum with explicit, stable source labels.
final class CurriculumRagService {
  CurriculumRagService({
    required this.modelOrchestrator,
    required this.vectorStore,
    this.defaultTopK = 5,
  }) {
    if (defaultTopK < 1) throw ArgumentError.value(defaultTopK, 'defaultTopK');
  }

  final DynamicModelOrchestrator modelOrchestrator;
  final SqliteVecStore vectorStore;
  final int defaultTopK;

  Future<List<RetrievedChunk>> retrieve(String question, {int? topK}) async {
    if (question.trim().isEmpty) throw ArgumentError.value(question, 'question');
    final count = topK ?? defaultTopK;
    if (count < 1) throw ArgumentError.value(count, 'topK');
    // Query embedding follows the same lazy-load / finally-unload lifecycle as
    // document indexing, so no embedding model remains resident after search.
    final vectors = await modelOrchestrator.indexDocuments(<String>[question]);
    if (vectors.length != 1) throw StateError('Query embedding returned no vector.');
    return vectorStore.search(vectors.single, topK: count);
  }

  /// Builds a grounded tutor context that directs the model to cite only the
  /// numbered local sources and to admit when the notes do not support a claim.
  Future<String> groundedContext(String question, {int? topK}) async {
    final hits = await retrieve(question, topK: topK);
    if (hits.isEmpty) {
      return '''LOCAL CURRICULUM SOURCES
No matching indexed curriculum passages were found. Do not invent citations. State that the local notes did not contain a grounded answer.''';
    }
    final buffer = StringBuffer('''LOCAL CURRICULUM SOURCES
Use only the passages below for curriculum-specific claims. Cite every such claim with its exact bracketed source label. If the passages do not answer the question, say so rather than guessing.
''');
    for (var index = 0; index < hits.length; index++) {
      final hit = hits[index];
      buffer
        ..writeln()
        ..writeln(hit.citation(index + 1))
        ..writeln(hit.chunk.text);
    }
    return buffer.toString();
  }

  Future<String> groundedTutorPrompt(String question, {int? topK}) async {
    final context = await groundedContext(question, topK: topK);
    return '''Student question:
$question

$context

Answer clearly and briefly. Cite curriculum facts using the exact source labels above.''';
  }
}
