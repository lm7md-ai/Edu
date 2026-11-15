import 'package:edu/features/rag_notes/presentation/rag_notes_providers.dart';
import 'package:edu/features/rag_notes/presentation/rag_workspace_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Riverpod composition boundary for the on-device curriculum workspace.
final class RagNotesScreen extends ConsumerWidget {
  const RagNotesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dependencies = ref.watch(ragWorkspaceDependenciesProvider);
    return dependencies.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => _RagSetupRequired(error: error),
      data: (services) => RagWorkspaceScreen(
        ingestionService: services.ingestion,
        ragService: services.ragService,
        vectorStore: services.store,
        flashcardGenerator: services.flashcardGenerator,
        fsrsScheduler: services.fsrsScheduler,
      ),
    );
  }
}

final class _RagSetupRequired extends StatelessWidget {
  const _RagSetupRequired({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Icon(Icons.library_books_outlined, size: 44),
                    const SizedBox(height: 12),
                    Text('Prepare local model paths to use Curriculum RAG',
                        style: Theme.of(context).textTheme.titleLarge,
                        textAlign: TextAlign.center),
                    const SizedBox(height: 8),
                    const Text('SQLite notes and review cards are stored on-device. Indexing and cited retrieval use the multilingual embedding model, which is loaded only for each operation.'),
                    const SizedBox(height: 12),
                    SelectableText('$error', style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}
