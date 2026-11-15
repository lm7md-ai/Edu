import 'dart:async';

import 'package:edu/app/providers/engine_providers.dart';
import 'package:edu/features/companion_sync/data/engines/lan_companion_engine_impl.dart';
import 'package:edu/features/voice_tutor/data/engines/local_tutor_engine_base.dart';
import 'package:edu/features/voice_tutor/domain/entities/tutor_engine_event.dart';
import 'package:edu/features/voice_tutor/domain/entities/tutor_prompt.dart';
import 'package:edu/features/whiteboard/data/services/repaint_boundary_snapshot_exporter.dart';
import 'package:edu/features/whiteboard/data/services/webp_snapshot_encoder.dart';
import 'package:edu/features/whiteboard/presentation/widgets/whiteboard_canvas.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Live tutor controls with an explicit, on-demand visual grading snapshot.
final class LiveTutorScreen extends ConsumerStatefulWidget {
  const LiveTutorScreen({super.key});

  @override
  ConsumerState<LiveTutorScreen> createState() => _LiveTutorScreenState();
}

final class _LiveTutorScreenState extends ConsumerState<LiveTutorScreen> {
  final TextEditingController _prompt = TextEditingController();
  final GlobalKey _snapshotBoundaryKey = GlobalKey();
  final RepaintBoundarySnapshotExporter _snapshotExporter = RepaintBoundarySnapshotExporter();
  final WebpSnapshotEncoder _webpEncoder = const WebpSnapshotEncoder();
  final List<String> _recentEvents = <String>[];
  StreamSubscription<TutorEngineEvent>? _eventSubscription;
  String? _status;
  bool _busy = false;
  bool _running = false;

  @override
  void dispose() {
    _prompt.dispose();
    unawaited(_eventSubscription?.cancel() ?? Future<void>.value());
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _status = 'Starting the selected local or companion runtime…';
    });
    try {
      final engine = ref.read(tutorEngineProvider);
      await engine.initialize();
      await _eventSubscription?.cancel();
      _eventSubscription = engine.events.listen(_onTutorEvent);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _running = true;
        _status = 'Tutor runtime is ready.';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'Runtime setup is incomplete: $error';
      });
    }
  }

  void _onTutorEvent(TutorEngineEvent event) {
    final description = switch (event) {
      TutorTextDelta(:final text) => text,
      TutorWhiteboardStepEvent(:final step) => 'Whiteboard step ${step.stepId}: ${step.speechText}',
      TutorTurnCompleted() => 'Tutor turn completed.',
      TutorTurnFailed(:final failure) => 'Tutor error: ${failure.message}',
    };
    if (!mounted) return;
    setState(() {
      _recentEvents.insert(0, description);
      if (_recentEvents.length > 8) _recentEvents.removeLast();
    });
  }

  Future<void> _submit({String? promptOverride}) async {
    final text = promptOverride ?? _prompt.text.trim();
    if (text.isEmpty || !_running) return;
    setState(() => _busy = true);
    try {
      await ref.read(tutorEngineProvider).submit(TutorPrompt(
        requestId: 'ui-${DateTime.now().microsecondsSinceEpoch}',
        text: text,
        createdAt: DateTime.now().toUtc(),
      ));
      if (!mounted) return;
      setState(() => _busy = false);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'Prompt failed: $error';
      });
    }
  }

  Future<void> _interrupt() async {
    try {
      await ref.read(tutorEngineProvider).interrupt();
      if (mounted) setState(() => _status = 'Playback and active generation cancelled.');
    } on Object catch (error) {
      if (mounted) setState(() => _status = 'Could not interrupt: $error');
    }
  }

  Future<void> _gradeMyWork() async {
    if (!_running) return;
    setState(() {
      _busy = true;
      _status = 'Capturing the board for your requested grading check…';
    });
    try {
      final png = await _snapshotExporter.exportPng(repaintBoundaryKey: _snapshotBoundaryKey);
      final webp = await _webpEncoder.encodePng(png.bytes);
      final engine = ref.read(tutorEngineProvider);
      if (engine is LocalTutorEngineBase) {
        engine.updateBoardSnapshot(webp);
      } else if (engine is LanCompanionEngineImpl) {
        await engine.sendBoardSnapshot(
          webp,
          requestId: 'grade-${DateTime.now().microsecondsSinceEpoch}',
        );
      } else {
        throw StateError('The selected tutor engine does not accept visual snapshots.');
      }
      await _submit(promptOverride:
          'Grade my work on the attached whiteboard. Give specific, constructive feedback and cite curriculum sources when relevant.');
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = 'Could not grade the board: $error';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    TutorEngineRuntimeDependencies? dependencies = null;
    String? setupError;
    try {
      dependencies = ref.watch(tutorEngineRuntimeDependenciesProvider);
    } on Object catch (error) {
      setupError = '$error';
    }

    final boardController = dependencies?.whiteboardController;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        final board = boardController == null
            ? _buildBoardSetup(context, setupError)
            : WhiteboardCanvas(
                controller: boardController,
                snapshotBoundaryKey: _snapshotBoundaryKey,
              );
        final controls = _buildControls(context, setupError);
        if (wide) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: <Widget>[
                Expanded(flex: 7, child: ClipRRect(borderRadius: BorderRadius.circular(16), child: board)),
                const SizedBox(width: 16),
                SizedBox(width: 360, child: controls),
              ],
            ),
          );
        }
        return Column(
          children: <Widget>[
            Expanded(flex: 5, child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: ClipRRect(borderRadius: BorderRadius.circular(16), child: board),
            )),
            Expanded(flex: 4, child: controls),
          ],
        );
      },
    );
  }

  Widget _buildBoardSetup(BuildContext context, String? error) => ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(Icons.draw_outlined, size: 48),
                const SizedBox(height: 12),
                const Text('Interactive whiteboard awaits a platform audio scheduler.'),
                if (error != null) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(error, textAlign: TextAlign.center),
                ],
              ],
            ),
          ),
        ),
      );

  Widget _buildControls(BuildContext context, String? setupError) => ListView(
        padding: const EdgeInsets.all(12),
        children: <Widget>[
          Text('Live AI tutor', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _busy ? null : (_running ? null : _start),
            icon: const Icon(Icons.play_arrow),
            label: Text(_running ? 'Runtime ready' : 'Start tutor'),
          ),
          TextField(
            controller: _prompt,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Ask a question',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton.icon(
                onPressed: !_running || _busy ? null : _submit,
                icon: const Icon(Icons.send),
                label: const Text('Ask tutor'),
              ),
              OutlinedButton.icon(
                onPressed: !_running ? null : _interrupt,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('Barge in'),
              ),
              OutlinedButton.icon(
                onPressed: !_running || _busy ? null : _gradeMyWork,
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('Grade My Work'),
              ),
            ],
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_status != null) Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(_status!),
          ),
          if (setupError != null) Text(
            'Runtime dependency configuration is required before inference can start.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const Divider(),
          Text('Recent tutor events', style: Theme.of(context).textTheme.titleMedium),
          for (final event in _recentEvents) ListTile(dense: true, title: Text(event)),
        ],
      );
}
