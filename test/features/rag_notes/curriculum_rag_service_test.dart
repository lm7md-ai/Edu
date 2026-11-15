import 'dart:typed_data';

import 'package:edu/features/rag_notes/data/curriculum_rag_service.dart';
import 'package:edu/features/rag_notes/data/sqlite_vec_store.dart';
import 'package:edu/features/voice_tutor/data/orchestrator/dynamic_model_orchestrator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  test('tutor-safe retrieval degrades gracefully when embeddings are unavailable', () async {
    final embedding = _FailingEmbeddingResource();
    final orchestrator = DynamicModelOrchestrator(
      warmModels: <WarmModelRole, ManagedModelResource>{
        for (final role in WarmModelRole.values) role: _IdleResource(role.name),
      },
      embeddingModel: embedding,
    );
    final store = SqliteVecStore(
      database: sqlite.sqlite3.openInMemory(),
      dimensions: 2,
      ownsDatabase: true,
    );
    addTearDown(() async {
      await orchestrator.dispose();
      store.close();
    });
    final service = CurriculumRagService(
      modelOrchestrator: orchestrator,
      vectorStore: store,
    );

    final context = await service.groundedContextOrUnavailable('Explain photosynthesis.');

    expect(context, contains('embedding runtime is unavailable'));
    expect(context, contains('Do not invent citations'));
    expect(embedding.isLoaded, isFalse);
  });
}

final class _IdleResource implements ManagedModelResource {
  _IdleResource(this.modelId);

  @override
  final String modelId;
  bool _loaded = false;

  @override
  bool get isLoaded => _loaded;

  @override
  Future<void> load() async {
    _loaded = true;
  }

  @override
  Future<void> unload() async {
    _loaded = false;
  }
}

final class _FailingEmbeddingResource implements EmbeddingModelResource {
  bool _loaded = false;

  @override
  String get modelId => 'test-embedding';

  @override
  bool get isLoaded => _loaded;

  @override
  Future<void> load() async {
    _loaded = true;
  }

  @override
  Future<void> unload() async {
    _loaded = false;
  }

  @override
  Future<Float32List> embed(String document) async =>
      throw StateError('weights missing');
}
