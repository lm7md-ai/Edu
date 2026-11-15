import 'package:edu/features/model_manager/data/on_device_model_catalog.dart';
import 'package:edu/features/model_manager/presentation/model_manager_providers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Imports supported model files from the Android document picker into the
/// app-private model directory and verifies their size and SHA-256 digest.
final class OnDeviceModelManagerScreen extends ConsumerStatefulWidget {
  const OnDeviceModelManagerScreen({super.key});

  @override
  ConsumerState<OnDeviceModelManagerScreen> createState() =>
      _OnDeviceModelManagerScreenState();
}

final class _OnDeviceModelManagerScreenState
    extends ConsumerState<OnDeviceModelManagerScreen> {
  final Set<OnDeviceModelId> _busy = <OnDeviceModelId>{};
  String? _status;

  OnDeviceModelCatalog get _catalog => OnDeviceModelCatalog.instance;

  Future<void> _import(OnDeviceModelSpec spec) async {
    setState(() {
      _busy.add(spec.id);
      _status = null;
    });
    try {
      final selection = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: spec.allowedExtensions,
        allowMultiple: false,
        withData: false,
        withReadStream: true,
      );
      if (selection == null || selection.files.isEmpty) return;
      final record = await _catalog.importModel(spec.id, selection.files.single);
      ref.read(modelCatalogRevisionProvider.notifier).state++;
      if (mounted) {
        setState(() => _status =
            '${spec.title} imported and verified (${_formatBytes(record.sizeBytes)}).');
      }
    } on Object catch (error) {
      if (mounted) setState(() => _status = 'Could not import ${spec.title}: $error');
    } finally {
      if (mounted) setState(() => _busy.remove(spec.id));
    }
  }

  Future<void> _verify(OnDeviceModelSpec spec) async {
    setState(() {
      _busy.add(spec.id);
      _status = null;
    });
    try {
      final record = await _catalog.verify(spec.id);
      if (mounted) {
        setState(() => _status =
            '${spec.title} checksum matches SHA-256 ${record.sha256.substring(0, 16)}…');
      }
    } on Object catch (error) {
      if (mounted) setState(() => _status = 'Verification failed for ${spec.title}: $error');
    } finally {
      if (mounted) setState(() => _busy.remove(spec.id));
    }
  }

  Future<void> _remove(OnDeviceModelSpec spec) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${spec.title}?'),
        content: const Text('The app-private copy will be deleted. The original file in Downloads is not changed.'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await _catalog.remove(spec.id);
      ref.read(modelCatalogRevisionProvider.notifier).state++;
      if (mounted) setState(() => _status = '${spec.title} removed from app storage.');
    } on Object catch (error) {
      if (mounted) setState(() => _status = 'Could not remove ${spec.title}: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(modelCatalogRevisionProvider);
    final records = _catalog.records;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: <Widget>[
        Text('On-device models', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        const Text(
          'Choose model files from Downloads. Imports are copied into app-private storage with streaming I/O; source files are left untouched. A checksum verifies file integrity, not model format or runtime compatibility.',
        ),
        const SizedBox(height: 16),
        for (final spec in OnDeviceModelSpec.all)
          _ModelCard(
            spec: spec,
            record: records[spec.id],
            busy: _busy.contains(spec.id),
            onImport: () => _import(spec),
            onVerify: records.containsKey(spec.id) ? () => _verify(spec) : null,
            onRemove: records.containsKey(spec.id) ? () => _remove(spec) : null,
          ),
        if (_status != null) ...<Widget>[
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: SelectableText(_status!),
            ),
          ),
        ],
        const SizedBox(height: 12),
        const Card(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Model weights and vendor inference backends are not bundled. Install compatible, licensed conversions. The app remains available for pairing, whiteboard drawing, local notes and FSRS reviews while weights are missing; tutor inference and embedding-based search require their corresponding models and a compatible native backend.',
            ),
          ),
        ),
      ],
    );
  }
}

final class _ModelCard extends StatelessWidget {
  const _ModelCard({
    required this.spec,
    required this.record,
    required this.busy,
    required this.onImport,
    required this.onVerify,
    required this.onRemove,
  });

  final OnDeviceModelSpec spec;
  final ModelInstallRecord? record;
  final bool busy;
  final VoidCallback onImport;
  final VoidCallback? onVerify;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final installed = record != null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(installed ? Icons.verified_outlined : Icons.download_for_offline_outlined),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(spec.title, style: Theme.of(context).textTheme.titleMedium),
                      Text(spec.description, style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
                Text(installed ? 'Imported' : 'Not installed'),
              ],
            ),
            if (record != null) ...<Widget>[
              const SizedBox(height: 8),
              SelectableText(
                '${record!.fileName} • ${_formatBytes(record!.sizeBytes)}\nSHA-256 ${record!.sha256}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 8),
            if (busy) const LinearProgressIndicator(),
            Wrap(
              spacing: 8,
              children: <Widget>[
                FilledButton.tonalIcon(
                  onPressed: busy ? null : onImport,
                  icon: const Icon(Icons.folder_open),
                  label: Text(installed ? 'Replace from Downloads' : 'Import from Downloads'),
                ),
                if (onVerify != null)
                  IconButton(
                    tooltip: 'Verify size and SHA-256',
                    onPressed: busy ? null : onVerify,
                    icon: const Icon(Icons.fact_check_outlined),
                  ),
                if (onRemove != null)
                  IconButton(
                    tooltip: 'Remove app-private copy',
                    onPressed: busy ? null : onRemove,
                    icon: const Icon(Icons.delete_outline),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
