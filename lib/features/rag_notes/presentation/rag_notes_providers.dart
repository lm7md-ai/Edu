import 'dart:io';
import 'dart:typed_data';

import 'package:edu/features/rag_notes/data/curriculum_rag_service.dart';
import 'package:edu/features/rag_notes/data/document_ingestion_service.dart';
import 'package:edu/features/rag_notes/data/flashcard_generator.dart';
import 'package:edu/features/rag_notes/data/fsrs_scheduler.dart';
import 'package:edu/features/rag_notes/data/sqlite_vec_store.dart';
import 'package:edu/features/voice_tutor/data/native/native_runtime_config.dart';
import 'package:edu/features/voice_tutor/data/orchestrator/dynamic_model_orchestrator.dart';
import 'package:edu/features/voice_tutor/data/orchestrator/native_model_resources.dart';
import 'package:edu/features/voice_tutor/data/workers/native_model_isolate_worker.dart';
import 'package:edu/app/providers/engine_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

final Provider<int> ragEmbeddingDimensionsProvider = Provider<int>((ref) => 1024);
final Provider<String?> sqliteVecExtensionPathProvider = Provider<String?>((ref) => null);

final FutureProvider<SqliteVecStore> sqliteVecStoreProvider =
    FutureProvider<SqliteVecStore>((ref) async {
  final directory = await getApplicationSupportDirectory();
  final databasePath = '${directory.path}${Platform.pathSeparator}curriculum_rag.sqlite';
  final extensionPath = ref.watch(sqliteVecExtensionPathProvider);
  final store = SqliteVecStore(
    database: sqlite.sqlite3.open(databasePath),
    dimensions: ref.watch(ragEmbeddingDimensionsProvider),
    sqliteVecExtensionPath: extensionPath,
    requireSqliteVec: extensionPath != null,
    ownsDatabase: true,
  );
  ref.onDispose(store.close);
  return store;
});

final Provider<DynamicModelOrchestrator> ragModelOrchestratorProvider =
    Provider<DynamicModelOrchestrator>((ref) {
  final paths = ref.watch(tutorEngineRuntimeDependenciesProvider).modelPaths;
  final dimensions = ref.watch(ragEmbeddingDimensionsProvider);
  final model = NativeEmbeddingModelResource(
    config: NativeRuntimeConfig(
      modelId: 'bge-m3-or-multilingual-e5',
      modelPath: paths.multilingualEmbedding,
      backend: NativeModelBackend.liteRtLm,
      quantization: 'INT8',
      accelerator: NativeAccelerator.cpu,
      contextTokens: 512,
      grammarPath: paths.grammar,
    ),
    driver: ref.watch(tutorEngineRuntimeDependenciesProvider).workerDriver,
  );
  return DynamicModelOrchestrator(
    warmModels: <WarmModelRole, ManagedModelResource>{
      for (final role in WarmModelRole.values) role: _IdleWarmResource(role.name),
    },
    embeddingModel: _DimensionCheckingEmbeddingResource(model, dimensions),
  );
});

final class RagWorkspaceDependencies {
  const RagWorkspaceDependencies({
    required this.store,
    required this.ingestion,
    required this.ragService,
    required this.flashcardGenerator,
    required this.fsrsScheduler,
  });

  final SqliteVecStore store;
  final DocumentIngestionService ingestion;
  final CurriculumRagService ragService;
  final FlashcardGenerator flashcardGenerator;
  final FsrsScheduler fsrsScheduler;
}

final FutureProvider<RagWorkspaceDependencies> ragWorkspaceDependenciesProvider =
    FutureProvider<RagWorkspaceDependencies>((ref) async {
  final store = await ref.watch(sqliteVecStoreProvider.future);
  final orchestrator = ref.watch(ragModelOrchestratorProvider);
  return RagWorkspaceDependencies(
    store: store,
    ingestion: DocumentIngestionService(
      modelOrchestrator: orchestrator,
      vectorStore: store,
    ),
    ragService: CurriculumRagService(
      modelOrchestrator: orchestrator,
      vectorStore: store,
    ),
    flashcardGenerator: FlashcardGenerator(),
    fsrsScheduler: FsrsScheduler(),
  );
});

final class _IdleWarmResource implements ManagedModelResource {
  _IdleWarmResource(this.modelId);

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

final class _DimensionCheckingEmbeddingResource implements EmbeddingModelResource {
  const _DimensionCheckingEmbeddingResource(this.delegate, this.expectedDimensions);

  final NativeEmbeddingModelResource delegate;
  final int expectedDimensions;

  @override
  String get modelId => delegate.modelId;

  @override
  bool get isLoaded => delegate.isLoaded;

  @override
  Future<void> load() => delegate.load();

  @override
  Future<void> unload() => delegate.unload();

  @override
  Future<Float32List> embed(String document) async {
    final embedding = await delegate.embed(document);
    if (embedding.length != expectedDimensions) {
      throw StateError('Configured vector dimension $expectedDimensions does not match model output ${embedding.length}.');
    }
    return embedding;
  }
}
