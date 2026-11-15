import 'package:edu/app/providers/engine_providers.dart';
import 'package:edu/app/providers/safe_runtime_bindings.dart';
import 'package:edu/features/model_manager/presentation/on_device_model_manager_screen.dart';
import 'package:edu/features/whiteboard/presentation/controllers/whiteboard_canvas_controller.dart';
import 'package:edu/presentation/live_tutor_screen.dart';
import 'package:edu/presentation/mode_settings_screen.dart';
import 'package:edu/presentation/rag_notes_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Responsive four-workspace shell with a real canvas in the safe no-audio state.
final class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

final class _HomeShellState extends ConsumerState<HomeShell>
    with TickerProviderStateMixin {
  int _selection = 0;
  late final WhiteboardCanvasController _whiteboardController;

  static const List<NavigationDestination> _destinations = <NavigationDestination>[
    NavigationDestination(
      icon: Icon(Icons.record_voice_over_outlined),
      selectedIcon: Icon(Icons.record_voice_over),
      label: 'Tutor',
    ),
    NavigationDestination(
      icon: Icon(Icons.menu_book_outlined),
      selectedIcon: Icon(Icons.menu_book),
      label: 'Curriculum',
    ),
    NavigationDestination(
      icon: Icon(Icons.memory_outlined),
      selectedIcon: Icon(Icons.memory),
      label: 'Models',
    ),
    NavigationDestination(
      icon: Icon(Icons.devices_outlined),
      selectedIcon: Icon(Icons.devices),
      label: 'Settings',
    ),
  ];

  @override
  void initState() {
    super.initState();
    _whiteboardController = WhiteboardCanvasController(
      vsync: this,
      scheduler: const UnavailablePcmStepScheduler(),
    );
    ref.read(activeWhiteboardControllerProvider.notifier).state = _whiteboardController;
  }

  @override
  void dispose() {
    if (identical(
      ref.read(activeWhiteboardControllerProvider),
      _whiteboardController,
    )) {
      ref.read(activeWhiteboardControllerProvider.notifier).state = null;
    }
    _whiteboardController.dispose();
    super.dispose();
  }

  Widget _page() => switch (_selection) {
        0 => const LiveTutorScreen(),
        1 => const RagNotesScreen(),
        2 => const OnDeviceModelManagerScreen(),
        _ => const ModeSettingsScreen(),
      };

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final useRail = constraints.maxWidth >= 900;
          final body = _page();
          if (useRail) {
            return Scaffold(
              body: Row(
                children: <Widget>[
                  NavigationRail(
                    selectedIndex: _selection,
                    onDestinationSelected: (index) => setState(() => _selection = index),
                    labelType: NavigationRailLabelType.all,
                    destinations: <NavigationRailDestination>[
                      for (final destination in _destinations)
                        NavigationRailDestination(
                          icon: destination.icon,
                          selectedIcon: destination.selectedIcon,
                          label: Text(destination.label),
                        ),
                    ],
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: body),
                ],
              ),
            );
          }
          return Scaffold(
            body: SafeArea(child: body),
            bottomNavigationBar: NavigationBar(
              selectedIndex: _selection,
              onDestinationSelected: (index) => setState(() => _selection = index),
              destinations: _destinations,
            ),
          );
        },
      );
}
