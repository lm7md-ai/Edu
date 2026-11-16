import 'package:edu/features/model_manager/data/on_device_model_catalog.dart';
import 'package:edu/features/model_manager/presentation/model_manager_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Downloads model files from HTTPS URLs into app-private storage; download does
/// not imply runtime compatibility.
final class OnDeviceModelManagerScreen extends ConsumerStatefulWidget {
  const OnDeviceModelManagerScreen({super.key});

  @override
  ConsumerState<OnDeviceModelManagerScreen> createState() =>
      _OnDeviceModelManagerScreenState();
}

final class _OnDeviceModelManagerScreenState
    extends ConsumerState<OnDeviceModelManagerScreen> {
  final Set<OnDeviceModelId> _busy = <OnDeviceModelId>{};
  final Map<OnDeviceModelId, _DownloadProgress> _progress =
      <OnDeviceModelId, _DownloadProgress>{};
  String? _status;

  OnDeviceModelCatalog get _catalog => OnDeviceModelCatalog.instance;

  Future<Uri?> _promptForCustomUrl(OnDeviceModelSpec spec) async {
    final controller = TextEditingController();
    final sourceText = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${spec.title} custom download URL'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Use a direct HTTPS file link from a source you trust. This is an '
              'alternative if the recommended source is unavailable. Web pages '
              'and sign-in-only links will not work.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'Direct HTTPS URL',
                hintText: 'https://…/model.litertlm',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => Navigator.pop(context, controller.text.trim()),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            icon: const Icon(Icons.download),
            label: const Text('Download'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (sourceText == null || !mounted) return null;

    final source = Uri.tryParse(sourceText.trim());
    if (source == null ||
        source.scheme != 'https' ||
        source.host.isEmpty ||
        source.userInfo.isNotEmpty) {
      setState(() => _status = 'Enter a valid HTTPS file URL for ${spec.title}.');
      return null;
    }
    return source;
  }

  Future<void> _download(
    OnDeviceModelSpec spec, {
    bool useCustomUrl = false,
  }) async {
    final String? configuredUrl = spec.defaultDownloadUrl;
    final Uri? source = !useCustomUrl && configuredUrl != null
        ? Uri.parse(configuredUrl)
        : await _promptForCustomUrl(spec);
    if (source == null || !mounted) return;

    setState(() {
      _busy.add(spec.id);
      _progress.remove(spec.id);
      _status = useCustomUrl
          ? 'Downloading ${spec.title} from the custom HTTPS URL…'
          : 'Downloading ${spec.title} from ${spec.downloadSourceLabel}…';
    });
    var lastReportedBytes = 0;
    try {
      final record = await _catalog.downloadModel(
        spec.id,
        source,
        onProgress: (receivedBytes, totalBytes) {
          // Avoid rebuilding the full list for every network chunk.
          if (!mounted ||
              (receivedBytes - lastReportedBytes < 512 * 1024 &&
                  (totalBytes == null || receivedBytes < totalBytes))) {
            return;
          }
          lastReportedBytes = receivedBytes;
          setState(() {
            _progress[spec.id] = _DownloadProgress(receivedBytes, totalBytes);
          });
        },
        onVerifying: (downloadedBytes) {
          if (!mounted) return;
          setState(() {
            _progress[spec.id] = _DownloadProgress(
              downloadedBytes,
              downloadedBytes,
              verifying: true,
            );
          });
        },
      );
      ref.read(modelCatalogRevisionProvider.notifier).state++;
      if (mounted) {
        setState(() {
          _progress.remove(spec.id);
          _status = '${spec.title} downloaded; size and SHA-256 recorded '
              '(${_formatBytes(record.sizeBytes)}; '
              '${record.sha256.substring(0, 16)}…). Runtime compatibility was not checked.';
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _progress.remove(spec.id);
          _status = 'Download failed for ${spec.title}: $error. '
              'If the source link is unavailable, try “Custom URL”.';
        });
      }
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
        content: const Text('The model file in app-private storage will be deleted.'),
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
          'Where a preselected HTTPS source is listed, Download model starts it '
          'directly. Use Custom URL if the source is unavailable or none is listed. '
          'Files are stored in app-private storage with their size and a locally '
          'computed SHA-256. Downloading does not verify publisher identity or '
          'runtime compatibility: check the model card and app backend requirements. '
          'A matching file extension alone is not proof that a model can run.',
        ),
        const SizedBox(height: 16),
        for (final spec in OnDeviceModelSpec.all)
          _ModelCard(
            spec: spec,
            record: records[spec.id],
            busy: _busy.contains(spec.id),
            progress: _progress[spec.id],
            onDownload: () => _download(spec),
            onCustomUrl: () => _download(spec, useCustomUrl: true),
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
              'Model weights and vendor inference backends are not bundled. Install '
              'compatible, licensed conversions. The app remains available for pairing, '
              'whiteboard drawing, local notes and FSRS reviews while weights are missing; '
              'tutor inference and embedding-based search require their corresponding '
              'models and a compatible native backend.',
            ),
          ),
        ),
      ],
    );
  }
}

final class _DownloadProgress {
  const _DownloadProgress(
    this.receivedBytes,
    this.totalBytes, {
    this.verifying = false,
  });

  final int receivedBytes;
  final int? totalBytes;
  final bool verifying;

  double? get fraction => totalBytes == null || totalBytes == 0
      ? null
      : (receivedBytes / totalBytes!).clamp(0.0, 1.0).toDouble();
}

final class _ModelCard extends StatelessWidget {
  const _ModelCard({
    required this.spec,
    required this.record,
    required this.busy,
    required this.progress,
    required this.onDownload,
    required this.onCustomUrl,
    required this.onVerify,
    required this.onRemove,
  });

  final OnDeviceModelSpec spec;
  final ModelInstallRecord? record;
  final bool busy;
  final _DownloadProgress? progress;
  final VoidCallback onDownload;
  final VoidCallback onCustomUrl;
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
                Icon(installed ? Icons.download_done : Icons.download_for_offline_outlined),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(spec.title, style: Theme.of(context).textTheme.titleMedium),
                      Text(spec.description, style: Theme.of(context).textTheme.bodySmall),
                      Text(
                        'Source: ${spec.downloadSourceLabel}',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
                Text(installed ? 'Downloaded' : 'Not downloaded'),
              ],
            ),
            if (record != null) ...<Widget>[
              const SizedBox(height: 8),
              SelectableText(
                '${record!.fileName} • ${_formatBytes(record!.sizeBytes)}\n'
                'SHA-256 ${record!.sha256}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 8),
            if (busy) ...<Widget>[
              LinearProgressIndicator(value: progress?.fraction),
              if (progress != null) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  progress!.verifying
                      ? 'Downloaded ${_formatBytes(progress!.receivedBytes)} • verifying SHA-256…'
                      : progress!.totalBytes == null
                          ? 'Downloaded ${_formatBytes(progress!.receivedBytes)}'
                          : '${_formatBytes(progress!.receivedBytes)} of '
                              '${_formatBytes(progress!.totalBytes!)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
            Wrap(
              spacing: 8,
              children: <Widget>[
                FilledButton.tonalIcon(
                  onPressed: busy ? null : onDownload,
                  icon: const Icon(Icons.download),
                  label: Text(
                    spec.defaultDownloadUrl == null
                        ? 'Choose download URL…'
                        : installed
                            ? 'Download replacement'
                            : 'Download model',
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: busy ? null : onCustomUrl,
                  icon: const Icon(Icons.link),
                  label: const Text('Custom URL'),
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
