import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:edu/features/model_manager/data/on_device_model_catalog.dart';
import 'package:edu/features/model_manager/presentation/model_manager_providers.dart';
import 'package:edu/features/rag_notes/data/curriculum_rag_service.dart';
import 'package:edu/features/rag_notes/data/document_ingestion_service.dart';
import 'package:edu/features/rag_notes/data/flashcard_generator.dart';
import 'package:edu/features/rag_notes/data/fsrs_scheduler.dart';
import 'package:edu/features/rag_notes/data/sqlite_vec_store.dart';
import 'package:edu/features/voice_tutor/data/native/native_runtime_config.dart';
import 'package:edu/features/voice_tutor/data/orchestrator/dynamic_model_orchestrator.dart';
import 'package:edu/features/voice_tutor/data/orchestrator/native_model_resources.dart';
import 'package:edu/features/voice_tutor/data/workers/native_model_isolate_worker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

final Provider<int> ragEmbeddingDimensionsProvider = Provider<int>((ref) => 1024);
final Provider<String?> sqliteVecExtensionPathProvider = Provider<String?>((ref) => null);

/// Synchronous SQLite open from the already initialized app-support model
/// catalog keeps local notes/card management available without any model files.
final Provider<SqliteVecStore> sqliteVecStoreProvider = Provider<SqliteVecStore>((ref) {
  final directory = OnDeviceModelCatalog.instance.supportDirectory;
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

/// The BGE-M3/E5 resource is not loaded until an embed operation starts.
final Provider<DynamicModelOrchestrator> ragModelOrchestratorProvider =
    Provider<DynamicModelOrchestrator>((ref) {
  ref.watch(modelCatalogRevisionProvider);
  final catalog = OnDeviceModelCatalog.instance;
  final model = NativeEmbeddingModelResource(
    config: NativeRuntimeConfig(
      modelId: 'bge-m3-or-multilingual-e5',
      modelPath: catalog.pathFor(OnDeviceModelId.bgeM3),
      backend: NativeModelBackend.liteRtLm,
      quantization: 'INT8',
      accelerator: NativeAccelerator.cpu,
      contextTokens: 512,
      grammarPath: catalog.grammarPath,
    ),
    driver: Platform.isAndroid
        ? NativeWorkerDriver.androidMethodChannel
        : NativeWorkerDriver.ffi,
  );
  final orchestrator = DynamicModelOrchestrator(
    warmModels: <WarmModelRole, ManagedModelResource>{
      for (final role in WarmModelRole.values) role: _IdleWarmResource(role.name),
    },
    embeddingModel: _DimensionCheckingEmbeddingResource(
      model,
      ref.watch(ragEmbeddingDimensionsProvider),
    ),
  );
  ref.onDispose(() => unawaited(orchestrator.dispose()));
  return orchestrator;
});

/// Shared service injected into host and Light Edge tutor prompts as well as
/// the Curriculum workspace. It stays usable without preloaded embedding data.
final Provider<CurriculumRagService> curriculumRagServiceProvider =
    Provider<CurriculumRagService>((ref) => CurriculumRagService(
          modelOrchestrator: ref.watch(ragModelOrchestratorProvider),
          vectorStore: ref.watch(sqliteVecStoreProvider),
        ));

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
    FutureProvider<RagWorkspaceDependencies>((ref) => Future<RagWorkspaceDependencies>.value(
          RagWorkspaceDependencies(
            store: ref.watch(sqliteVecStoreProvider),
            ingestion: DocumentIngestionService(
              modelOrchestrator: ref.watch(ragModelOrchestratorProvider),
              vectorStore: ref.watch(sqliteVecStoreProvider),
            ),
            ragService: ref.watch(curriculumRagServiceProvider),
            flashcardGenerator: FlashcardGenerator(),
            fsrsScheduler: FsrsScheduler(),
          ),
        ));

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
      throw StateError(
        'Configured vector dimension $expectedDimensions does not match model output ${embedding.length}.',
      );
    }
    return embedding;
  }
}
