import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:edu/features/rag_notes/data/curriculum_rag_service.dart';
import 'package:edu/features/rag_notes/data/document_ingestion_service.dart';
import 'package:edu/features/rag_notes/data/flashcard_generator.dart';
import 'package:edu/features/rag_notes/data/fsrs_scheduler.dart';
import 'package:edu/features/rag_notes/data/sqlite_vec_store.dart';
import 'package:edu/features/rag_notes/domain/entities/curriculum_note.dart';
import 'package:edu/features/rag_notes/domain/entities/flashcard.dart';
import 'package:edu/features/rag_notes/presentation/flashcard_review_screen.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

/// Curriculum notes, grounded local search and spaced-repetition workspace.
/// Notes/cards persist even if the optional embedding weights are not installed.
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
  static const int _maximumDocumentBytes = 48 * 1024 * 1024;

  final TextEditingController _title = TextEditingController();
  final TextEditingController _notes = TextEditingController();
  final TextEditingController _question = TextEditingController();
  List<Flashcard> _dueCards = <Flashcard>[];
  List<CurriculumNote> _savedNotes = <CurriculumNote>[];
  String? _answer;
  String? _status;
  bool _busy = false;
  bool _reviewing = false;

  @override
  void initState() {
    super.initState();
    _refreshLocalData();
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    _question.dispose();
    super.dispose();
  }

  void _refreshLocalData() {
    try {
      _dueCards = widget.vectorStore.loadFlashcards(dueBefore: DateTime.now().toUtc());
      _savedNotes = widget.vectorStore.loadNotes();
    } on Object catch (error) {
      _status = 'Local notes or review storage is unavailable: $error';
    }
  }

  Future<void> _pickDocument() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final selection = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: <String>['pdf', 'md', 'markdown', 'txt', 'text'],
        allowMultiple: false,
        withData: false,
        withReadStream: true,
      );
      if (selection == null || selection.files.isEmpty) return;
      final picked = selection.files.single;
      if (picked.size <= 0 || picked.size > _maximumDocumentBytes) {
        throw const FormatException('Choose a non-empty document smaller than 48 MB.');
      }
      final bytes = await _readPickedFile(picked);
      final extensionIndex = picked.name.lastIndexOf('.');
      _title.text = extensionIndex > 0
          ? picked.name.substring(0, extensionIndex)
          : picked.name;
      final extension = extensionIndex < 0
          ? ''
          : picked.name.substring(extensionIndex + 1).toLowerCase();
      if (extension != 'pdf') {
        _notes.text = utf8.decode(bytes, allowMalformed: true);
      }
      await _saveAndIndex(title: _title.text.trim(), filename: picked.name, bytes: bytes);
    } on Object catch (error) {
      if (mounted) setState(() => _status = 'Could not import this document: $error');
    } finally {
      if (mounted && _busy) setState(() => _busy = false);
    }
  }

  Future<Uint8List> _readPickedFile(PlatformFile file) async {
    final builder = BytesBuilder(copy: false);
    final stream = file.readStream;
    if (stream != null) {
      await for (final part in stream) {
        if (part.length > _maximumDocumentBytes - builder.length) {
          throw const FormatException('Selected document exceeds the 48 MB memory-safe limit.');
        }
        builder.add(part);
      }
      return builder.takeBytes();
    }
    final data = file.bytes;
    if (data != null) return data;
    final path = file.path;
    if (path != null) {
      final localFile = File(path);
      if (await localFile.exists()) {
        if (await localFile.length() > _maximumDocumentBytes) {
          throw const FormatException('Selected document exceeds the 48 MB memory-safe limit.');
        }
        return await localFile.readAsBytes();
      }
    }
    throw const FormatException('The document picker did not provide readable file data.');
  }

  Future<void> _indexPastedNotes() async {
    final title = _title.text.trim();
    final source = _notes.text.trim();
    if (title.isEmpty || source.isEmpty) {
      setState(() => _status = 'Enter a title and notes before saving.');
      return;
    }
    await _saveAndIndex(
      title: title,
      filename: 'notes.md',
      bytes: Uint8List.fromList(utf8.encode(source)),
    );
  }

  Future<void> _saveAndIndex({
    required String title,
    required String filename,
    required Uint8List bytes,
  }) async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    final sourceId = 'notes-${DateTime.now().toUtc().microsecondsSinceEpoch}';
    try {
      final chunks = widget.ingestionService.extractChunks(
        sourceId: sourceId,
        documentTitle: title,
        filename: filename,
        bytes: bytes,
      );
      final content = chunks.map((chunk) => chunk.text).join('\n\n');
      widget.vectorStore.saveNote(CurriculumNote(
        sourceId: sourceId,
        title: title,
        filename: filename,
        content: content,
        updatedAt: DateTime.now().toUtc(),
      ));
      final cards = widget.flashcardGenerator.generate(chunks);
      widget.vectorStore.saveFlashcards(cards);

      String indexingStatus;
      try {
        await widget.ingestionService.indexChunks(chunks);
        indexingStatus = 'Indexed ${chunks.length} cited chunks';
      } on Object catch (error) {
        indexingStatus = 'Embedding index deferred until a compatible model is installed ($error)';
      }
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'Saved the note and ${cards.length} review cards. $indexingStatus.';
        _refreshLocalData();
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'Could not save this note: $error';
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
        _answer = 'Local curriculum retrieval needs an installed embedding model: $error';
      });
    }
  }

  Future<void> _saveReviewedCard(Flashcard card) async {
    widget.vectorStore.saveFlashcards(<Flashcard>[card]);
    if (mounted) setState(_refreshLocalData);
  }

  Future<void> _deleteNote(CurriculumNote note) async {
    widget.vectorStore.removeSource(note.sourceId);
    if (mounted) {
      setState(() {
        _refreshLocalData();
        _status = 'Removed “${note.title}” and its associated cards.';
      });
    }
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
        const Text('Notes and FSRS cards are stored on this device, even before optional embedding weights are installed.'),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text('Add curriculum notes', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _pickDocument,
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Choose PDF / Markdown / Text from Downloads'),
                ),
                const SizedBox(height: 8),
                TextField(controller: _title, decoration: const InputDecoration(labelText: 'Document title')),
                const SizedBox(height: 8),
                TextField(
                  controller: _notes,
                  minLines: 4,
                  maxLines: 9,
                  decoration: const InputDecoration(
                    labelText: 'Or paste Markdown / text notes',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _busy ? null : _indexPastedNotes,
                  icon: const Icon(Icons.save_alt),
                  label: const Text('Save notes, generate cards and index if available'),
                ),
              ],
            ),
          ),
        ),
        if (_savedNotes.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Text('Saved notes', style: Theme.of(context).textTheme.titleLarge),
          for (final note in _savedNotes)
            Card(
              child: ListTile(
                leading: const Icon(Icons.description_outlined),
                title: Text(note.title),
                subtitle: Text('${note.filename} • ${note.content.length} characters'),
                onTap: () {
                  _title.text = note.title;
                  _notes.text = note.content;
                },
                trailing: IconButton(
                  tooltip: 'Delete note and its cards',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _deleteNote(note),
                ),
              ),
            ),
        ],
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
          child: SelectableText(_status!),
        ),
      ],
    );
  }
}
