import 'dart:convert';
import 'dart:typed_data';

import 'package:edu/features/rag_notes/data/curriculum_rag_service.dart';
import 'package:edu/features/rag_notes/data/document_ingestion_service.dart';
import 'package:edu/features/rag_notes/data/flashcard_generator.dart';
import 'package:edu/features/rag_notes/data/fsrs_scheduler.dart';
import 'package:edu/features/rag_notes/data/sqlite_vec_store.dart';
import 'package:edu/features/rag_notes/domain/entities/flashcard.dart';
import 'package:edu/features/rag_notes/presentation/flashcard_review_screen.dart';
import 'package:flutter/material.dart';

/// Curriculum notes, grounded local search and spaced-repetition workspace.
final class RagWorkspaceScreen extends StatefulWidget {
  const RagWorkspaceScreen({
    required this.ingestionService,
    required this.ragService,
    required this.vectorStore,
    required this.flashcardGenerator,
    required this.fsrsScheduler,
    super.key,
  });

  final DocumentIngestionService ingestionService;
  final CurriculumRagService ragService;
  final SqliteVecStore vectorStore;
  final FlashcardGenerator flashcardGenerator;
  final FsrsScheduler fsrsScheduler;

  @override
  State<RagWorkspaceScreen> createState() => _RagWorkspaceScreenState();
}

final class _RagWorkspaceScreenState extends State<RagWorkspaceScreen> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _notes = TextEditingController();
  final TextEditingController _question = TextEditingController();
  List<Flashcard> _dueCards = <Flashcard>[];
  String? _answer;
  String? _status;
  bool _busy = false;
  bool _reviewing = false;

  @override
  void initState() {
    super.initState();
    _refreshCards();
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    _question.dispose();
    super.dispose();
  }

  void _refreshCards() {
    try {
      _dueCards = widget.vectorStore.loadFlashcards(dueBefore: DateTime.now().toUtc());
    } on Object catch (error) {
      _status = 'Flashcard storage is unavailable: $error';
    }
  }

  Future<void> _indexNotes() async {
    final title = _title.text.trim();
    final source = _notes.text.trim();
    if (title.isEmpty || source.isEmpty) {
      setState(() => _status = 'Enter a title and notes before indexing.');
      return;
    }
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final sourceId = 'notes-${DateTime.now().toUtc().microsecondsSinceEpoch}';
      final chunks = await widget.ingestionService.ingest(
        sourceId: sourceId,
        documentTitle: title,
        filename: 'notes.md',
        bytes: Uint8List.fromList(utf8.encode(source)),
      );
      final cards = widget.flashcardGenerator.generate(chunks);
      widget.vectorStore.saveFlashcards(cards);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'Indexed ${chunks.length} grounded note chunks and saved ${cards.length} flashcards.';
        _refreshCards();
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'Could not index these notes: $error';
      });
    }
  }

  Future<void> _searchCurriculum() async {
    if (_question.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _answer = null;
    });
    try {
      final grounded = await widget.ragService.groundedContext(_question.text.trim());
      if (!mounted) return;
      setState(() {
        _busy = false;
        _answer = grounded;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _answer = 'Local curriculum retrieval failed: $error';
      });
    }
  }

  Future<void> _saveReviewedCard(Flashcard card) async {
    widget.vectorStore.saveFlashcards(<Flashcard>[card]);
    if (mounted) setState(_refreshCards);
  }

  @override
  Widget build(BuildContext context) {
    if (_reviewing) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Flashcard review'),
          leading: BackButton(onPressed: () => setState(() => _reviewing = false)),
        ),
        body: FlashcardReviewScreen(
          cards: _dueCards,
          scheduler: widget.fsrsScheduler,
          onCardReviewed: _saveReviewedCard,
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(20),
      children: <Widget>[
        Text('Curriculum workspace', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text('Notes stay on this device. Indexing temporarily loads and then unloads the embedding model.'),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text('Add curriculum notes', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                TextField(controller: _title, decoration: const InputDecoration(labelText: 'Document title')),
                const SizedBox(height: 8),
                TextField(
                  controller: _notes,
                  minLines: 5,
                  maxLines: 12,
                  decoration: const InputDecoration(
                    labelText: 'Paste Markdown or text notes',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _busy ? null : _indexNotes,
                  icon: const Icon(Icons.library_add),
                  label: const Text('Index notes and make flashcards'),
                ),
              ],
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text('Ask your curriculum', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                TextField(
                  controller: _question,
                  decoration: const InputDecoration(labelText: 'Question for grounded retrieval'),
                  onSubmitted: (_) => _searchCurriculum(),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _searchCurriculum,
                  icon: const Icon(Icons.search),
                  label: const Text('Retrieve cited source passages'),
                ),
                if (_answer != null) SelectableText(_answer!),
              ],
            ),
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.style),
            title: Text('${_dueCards.length} flashcards due'),
            subtitle: const Text('Review with Again, Hard, Good or Easy to schedule the next interval.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _dueCards.isEmpty ? null : () => setState(() => _reviewing = true),
          ),
        ),
        if (_busy) const Center(child: Padding(
          padding: EdgeInsets.all(16),
          child: CircularProgressIndicator(),
        )),
        if (_status != null) Padding(
          padding: const EdgeInsets.all(8),
          child: Text(_status!),
        ),
      ],
    );
  }
}
