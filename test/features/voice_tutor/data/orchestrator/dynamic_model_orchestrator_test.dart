import 'dart:typed_data';

import 'package:edu/features/voice_tutor/data/orchestrator/dynamic_model_orchestrator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> lifecycle;
  late Map<WarmModelRole, _FakeModel> warmModels;
  late _FakeEmbeddingModel embeddingModel;
  late DynamicModelOrchestrator orchestrator;

  setUp(() {
    lifecycle = <String>[];
    warmModels = <WarmModelRole, _FakeModel>{
      for (final role in WarmModelRole.values) role: _FakeModel(role.name, lifecycle),
    };
    embeddingModel = _FakeEmbeddingModel(lifecycle);
    orchestrator = DynamicModelOrchestrator(
      warmModels: warmModels,
      embeddingModel: embeddingModel,
    );
  });

  test('keeps VAD, ASR, TTS and Gemma warm but leaves embeddings unloaded', () async {
    await orchestrator.startSession();

    expect(orchestrator.isSessionActive, isTrue);
    expect(warmModels.values.every((model) => model.isLoaded), isTrue);
    expect(embeddingModel.isLoaded, isFalse);
    expect(lifecycle.take(4).toList(), <String>[
      'load:sileroVad',
      'load:asr',
      'load:kokoroTts',
      'load:primaryGemma',
    ]);
  });

  test('loads embeddings only for indexing and unloads immediately afterward', () async {
    await orchestrator.startSession();
    final result = await orchestrator.indexDocuments(<String>['hello', 'مرحبا']);

    expect(result, hasLength(2));
    expect(embeddingModel.isLoaded, isFalse);
    expect(lifecycle.where((entry) => entry.startsWith('load:embedding')).length, 1);
    expect(lifecycle.where((entry) => entry.startsWith('unload:embedding')).length, 1);
    expect(warmModels.values.every((model) => model.isLoaded), isTrue);
  });

  test('always unloads the lazy embedding model when indexing fails', () async {
    final failingEmbedding = _FakeEmbeddingModel(lifecycle, failEmbed: true);
    final service = DynamicModelOrchestrator(
      warmModels: warmModels,
      embeddingModel: failingEmbedding,
    );

    await expectLater(service.indexDocuments(<String>['broken']), throwsStateError);
    expect(failingEmbedding.isLoaded, isFalse);
    expect(lifecycle, contains('unload:embedding'));
  });

  test('unloads warm models on session end and rolls back a partial warmup', () async {
    await orchestrator.startSession();
    await orchestrator.stopSession();
    expect(orchestrator.isSessionActive, isFalse);
    expect(warmModels.values.every((model) => !model.isLoaded), isTrue);
    await orchestrator.startSession();
    expect(warmModels.values.every((model) => model.isLoaded), isTrue);

    final failingLifecycle = <String>[];
    final failingModels = <WarmModelRole, _FakeModel>{
      for (final role in WarmModelRole.values)
        role: _FakeModel(role.name, failingLifecycle,
            failLoad: role == WarmModelRole.kokoroTts),
    };
    final failing = DynamicModelOrchestrator(
      warmModels: failingModels,
      embeddingModel: _FakeEmbeddingModel(failingLifecycle),
    );
    await expectLater(failing.startSession(), throwsStateError);
    expect(failingModels.values.where((model) => model.isLoaded), isEmpty);
  });
}

class _FakeModel implements ManagedModelResource {
  _FakeModel(this.modelId, this.lifecycle, {this.failLoad = false});

  @override
  final String modelId;
  final List<String> lifecycle;
  final bool failLoad;
  @override
  bool isLoaded = false;

  @override
  Future<void> load() async {
    lifecycle.add('load:$modelId');
    if (failLoad) throw StateError('Could not load $modelId');
    isLoaded = true;
  }

  @override
  Future<void> unload() async {
    lifecycle.add('unload:$modelId');
    isLoaded = false;
  }
}

class _FakeEmbeddingModel extends _FakeModel implements EmbeddingModelResource {
  _FakeEmbeddingModel(List<String> lifecycle, {this.failEmbed = false})
      : super('embedding', lifecycle);

  final bool failEmbed;

  @override
  Future<Float32List> embed(String document) async {
    if (failEmbed) throw StateError('Embedding failed.');
    return Float32List.fromList(<double>[document.length.toDouble(), 0.5]);
  }
}
