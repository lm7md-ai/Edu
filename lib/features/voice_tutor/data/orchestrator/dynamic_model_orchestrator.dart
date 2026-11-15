import 'dart:async';
import 'dart:typed_data';

/// The models that remain resident while a tutoring session is active.
enum WarmModelRole { sileroVad, asr, kokoroTts, primaryGemma }

/// Lifecycle adapter for one heavyweight model. Concrete implementations may
/// proxy to native handles owned by a worker isolate.
abstract interface class ManagedModelResource {
  String get modelId;
  bool get isLoaded;
  Future<void> load();
  Future<void> unload();
}

/// Lifecycle adapter for a document embedding model. Unlike warm resources it
/// must only be acquired for [indexDocuments] and released in its `finally`.
abstract interface class EmbeddingModelResource implements ManagedModelResource {
  Future<Float32List> embed(String document);
}

/// Keeps latency-sensitive tutoring models warm and bounds embedding-model
/// residency to the exact document indexing operation.
final class DynamicModelOrchestrator {
  DynamicModelOrchestrator({
    required Map<WarmModelRole, ManagedModelResource> warmModels,
    required this.embeddingModel,
  }) : warmModels = Map<WarmModelRole, ManagedModelResource>.unmodifiable(warmModels) {
    for (final role in WarmModelRole.values) {
      if (!this.warmModels.containsKey(role)) {
        throw ArgumentError.value(warmModels, 'warmModels', 'Missing warm model role $role.');
      }
    }
    if (embeddingModel.isLoaded) {
      throw ArgumentError.value(
        embeddingModel.modelId,
        'embeddingModel',
        'Embedding model must start unloaded.',
      );
    }
    if (this.warmModels.values.any((model) => identical(model, embeddingModel))) {
      throw ArgumentError('Embedding model cannot also be a warm session model.');
    }
  }

  final Map<WarmModelRole, ManagedModelResource> warmModels;
  final EmbeddingModelResource embeddingModel;
  Future<void> _operationTail = Future<void>.value();
  bool _sessionActive = false;
  bool _disposed = false;

  bool get isSessionActive => _sessionActive;

  Future<void> startSession() => _serialized<void>(() async {
        _ensureUsable();
        if (_sessionActive) return;
        final loadedHere = <ManagedModelResource>[];
        try {
          for (final role in WarmModelRole.values) {
            final model = warmModels[role]!;
            if (!model.isLoaded) {
              await model.load();
              loadedHere.add(model);
            }
          }
          _sessionActive = true;
        } on Object {
          for (final model in loadedHere.reversed) {
            await model.unload();
          }
          rethrow;
        }
      });

  /// Runs indexing with the multilingual embedding model loaded only for the
  /// duration of this operation, unloading even if inference throws.
  Future<List<Float32List>> indexDocuments(List<String> documents) =>
      _serialized<List<Float32List>>(() async {
        _ensureUsable();
        try {
          if (!embeddingModel.isLoaded) await embeddingModel.load();
          final embeddings = <Float32List>[];
          for (final document in documents) {
            embeddings.add(await embeddingModel.embed(document));
          }
          return List<Float32List>.unmodifiable(embeddings);
        } finally {
          if (embeddingModel.isLoaded) await embeddingModel.unload();
        }
      });

  Future<void> stopSession() => _serialized<void>(() async {
        if (_disposed || !_sessionActive) return;
        Object? firstError;
        for (final role in WarmModelRole.values.reversed) {
          final model = warmModels[role]!;
          if (!model.isLoaded) continue;
          try {
            await model.unload();
          } on Object catch (error) {
            firstError ??= error;
          }
        }
        _sessionActive = false;
        if (firstError != null) throw StateError('One or more warm models failed to unload: $firstError');
      });

  Future<void> dispose() => _serialized<void>(() async {
        if (_disposed) return;
        Object? firstError;
        for (final role in WarmModelRole.values.reversed) {
          final model = warmModels[role]!;
          if (!model.isLoaded) continue;
          try {
            await model.unload();
          } on Object catch (error) {
            firstError ??= error;
          }
        }
        if (embeddingModel.isLoaded) {
          try {
            await embeddingModel.unload();
          } on Object catch (error) {
            firstError ??= error;
          }
        }
        _sessionActive = false;
        _disposed = true;
        if (firstError != null) throw StateError('Model teardown failed: $firstError');
      });

  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _operationTail.then((_) => action());
    _operationTail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  void _ensureUsable() {
    if (_disposed) throw StateError('Dynamic model orchestrator is disposed.');
  }
}
