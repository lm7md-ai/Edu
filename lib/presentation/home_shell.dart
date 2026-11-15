import 'package:edu/presentation/live_tutor_screen.dart';
import 'package:edu/presentation/mode_settings_screen.dart';
import 'package:edu/presentation/rag_notes_screen.dart';
import 'package:flutter/material.dart';

/// Responsive three-workspace shell: tutor/whiteboard, curriculum/recall, settings.
final class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

final class _HomeShellState extends State<HomeShell> {
  int _selection = 0;

  static const List<NavigationDestination> _destinations = <NavigationDestination>[
    NavigationDestination(icon: Icon(Icons.record_voice_over_outlined), selectedIcon: Icon(Icons.record_voice_over), label: 'Tutor'),
    NavigationDestination(icon: Icon(Icons.menu_book_outlined), selectedIcon: Icon(Icons.menu_book), label: 'Curriculum'),
    NavigationDestination(icon: Icon(Icons.devices_outlined), selectedIcon: Icon(Icons.devices), label: 'Settings'),
  ];

  Widget _page() => switch (_selection) {
        0 => const LiveTutorScreen(),
        1 => const RagNotesScreen(),
        _ => const ModeSettingsScreen(),
      };

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final useRail = constraints.maxWidth >= 840;
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
