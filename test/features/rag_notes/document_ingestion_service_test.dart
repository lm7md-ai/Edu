import 'dart:typed_data';

import 'package:edu/features/rag_notes/data/curriculum_rag_service.dart';
import 'package:edu/features/rag_notes/data/document_ingestion_service.dart';
import 'package:edu/features/rag_notes/data/sqlite_vec_store.dart';
import 'package:edu/features/voice_tutor/data/orchestrator/dynamic_model_orchestrator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late SqliteVecStore store;
  late _FakeEmbeddingModel embedding;
  late DynamicModelOrchestrator orchestrator;

  setUp(() {
    store = SqliteVecStore(database: sqlite3.openInMemory(), dimensions: 3, ownsDatabase: true);
    embedding = _FakeEmbeddingModel();
    orchestrator = _orchestrator(embedding);
  });

  tearDown(() => store.close());

  test('indexes Markdown sections through lazy embeddings and unloads after persistence', () async {
    final ingestion = DocumentIngestionService(
      modelOrchestrator: orchestrator,
      vectorStore: store,
      maxChunkCharacters: 100,
      overlapWords: 1,
    );

    final chunks = await ingestion.ingest(
      sourceId: 'chemistry-1',
      documentTitle: 'Chemistry Basics',
      filename: 'lesson.md',
      bytes: Uint8List.fromList('''# Atoms
An atom contains protons and neutrons in a nucleus. Electrons occupy surrounding energy levels.
## Bonds
Covalent bonds share electron pairs between neighboring atoms.'''.codeUnits),
    );

    expect(chunks, isNotEmpty);
    expect(chunks.map((chunk) => chunk.sectionTitle).toSet(), <String>{'Atoms', 'Bonds'});
    expect(chunks.every((chunk) => chunk.documentTitle == 'Chemistry Basics'), isTrue);
    expect(embedding.lifecycle, <String>['load', 'unload']);
    expect(embedding.isLoaded, isFalse);
    expect(embedding.documents, hasLength(chunks.length));
    expect(store.search(Float32List.fromList(<double>[1, 0, 0]), topK: 10), hasLength(chunks.length));
  });

  test('unloads the embedding resource when inference throws', () async {
    final failing = _FakeEmbeddingModel(fail: true);
    final ingestion = DocumentIngestionService(
      modelOrchestrator: _orchestrator(failing),
      vectorStore: store,
    );

    await expectLater(
      ingestion.ingest(
        sourceId: 'broken',
        documentTitle: 'Broken',
        filename: 'broken.txt',
        bytes: Uint8List.fromList('Text that should be embedded.'.codeUnits),
      ),
      throwsStateError,
    );
    expect(failing.isLoaded, isFalse);
    expect(failing.lifecycle, <String>['load', 'unload']);
    expect(store.search(Float32List.fromList(<double>[1, 0, 0])), isEmpty);
  });

  test('splits plain text pages and extracts PDF text-layer source pages', () async {
    final ingestion = DocumentIngestionService(
      modelOrchestrator: orchestrator,
      vectorStore: store,
    );
    final textChunks = await ingestion.ingest(
      sourceId: 'pages',
      documentTitle: 'Page Notes',
      filename: 'pages.txt',
      bytes: Uint8List.fromList('first page content\fsecond page content'.codeUnits),
    );
    expect(textChunks.map((chunk) => chunk.pageIndex).toSet(), <int>{0, 1});

    final pdf = '%PDF-1.4\n1 0 obj << /Type /Page >> endobj\n'
        '2 0 obj << /Length 36 >> stream\n'
        'BT (PDF text extraction works.) Tj ET\nendstream endobj\n%%EOF';
    final pdfChunks = await ingestion.ingest(
      sourceId: 'pdf',
      documentTitle: 'PDF Notes',
      filename: 'notes.pdf',
      bytes: Uint8List.fromList(pdf.codeUnits),
    );
    expect(pdfChunks, hasLength(1));
    expect(pdfChunks.single.text, contains('PDF text extraction works.'));
    expect(pdfChunks.single.pageIndex, 0);
  });

  test('RAG retrieval formats exact numbered citations and a no-hit grounding rule', () async {
    final ingestion = DocumentIngestionService(
      modelOrchestrator: orchestrator,
      vectorStore: store,
    );
    final chunks = await ingestion.ingest(
      sourceId: 'physics',
      documentTitle: 'Physics Notes',
      filename: 'physics.txt',
      bytes: Uint8List.fromList('force and mass'.codeUnits),
    );
    expect(chunks, hasLength(1));
    final rag = CurriculumRagService(modelOrchestrator: orchestrator, vectorStore: store);

    final context = await rag.groundedContext('force and mass');
    expect(context, contains('[1] Physics Notes, page 1, Section 1'));
    expect(context, contains('force and mass'));
    expect(context, contains('Cite every such claim'));

    store.removeSource('physics');
    final empty = await rag.groundedContext('unknown topic');
    expect(empty, contains('Do not invent citations'));
  });

  test('rejects unsupported formats and empty source content', () async {
    final ingestion = DocumentIngestionService(
      modelOrchestrator: orchestrator,
      vectorStore: store,
    );
    await expectLater(
      ingestion.ingest(
        sourceId: 's', documentTitle: 'x', filename: 'x.docx',
        bytes: Uint8List.fromList(<int>[1]),
      ),
      throwsFormatException,
    );
    await expectLater(
      ingestion.ingest(
        sourceId: 's', documentTitle: 'x', filename: 'x.txt', bytes: Uint8List(0),
      ),
      throwsArgumentError,
    );
  });
}

DynamicModelOrchestrator _orchestrator(_FakeEmbeddingModel embedding) =>
    DynamicModelOrchestrator(
      warmModels: <WarmModelRole, ManagedModelResource>{
        for (final role in WarmModelRole.values) role: _AlwaysLoadedResource(role.name),
      },
      embeddingModel: embedding,
    );

final class _AlwaysLoadedResource implements ManagedModelResource {
  const _AlwaysLoadedResource(this.modelId);

  @override
  final String modelId;
  @override
  bool get isLoaded => true;
  @override
  Future<void> load() async {}
  @override
  Future<void> unload() async {}
}

final class _FakeEmbeddingModel implements EmbeddingModelResource {
  _FakeEmbeddingModel({this.fail = false});

  final bool fail;
  bool _loaded = false;
  final List<String> lifecycle = <String>[];
  final List<String> documents = <String>[];

  @override
  String get modelId => 'fake-multilingual';
  @override
  bool get isLoaded => _loaded;

  @override
  Future<void> load() async {
    lifecycle.add('load');
    _loaded = true;
  }

  @override
  Future<void> unload() async {
    lifecycle.add('unload');
    _loaded = false;
  }

  @override
  Future<Float32List> embed(String document) async {
    documents.add(document);
    if (fail) throw StateError('Embedding failure.');
    return Float32List.fromList(<double>[1, 0, 0]);
  }
}
