import 'dart:io';

import 'package:edu/app/providers/engine_providers.dart';
import 'package:edu/core/execution/execution_mode.dart';
import 'package:edu/features/companion_sync/data/services/mdns_discovery_service.dart';
import 'package:edu/features/companion_sync/domain/entities/pairing_credentials.dart';
import 'package:edu/features/companion_sync/presentation/widgets/execution_mode_pairing_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Execution mode, host QR/PIN and LAN companion pairing settings.
final class ModeSettingsScreen extends ConsumerStatefulWidget {
  const ModeSettingsScreen({super.key});

  @override
  ConsumerState<ModeSettingsScreen> createState() => _ModeSettingsScreenState();
}

final class _ModeSettingsScreenState extends ConsumerState<ModeSettingsScreen> {
  final MdnsDiscoveryService _discovery = MdnsDiscoveryService();
  bool _generatingHost = false;
  String? _status;

  @override
  void dispose() {
    _discovery.dispose();
    super.dispose();
  }

  Future<void> _createHostCredentials() async {
    setState(() {
      _generatingHost = true;
      _status = null;
    });
    try {
      final host = await _firstLanIpv4();
      final credentials = PairingCredentials.generate(
        endpoint: Uri(scheme: 'ws', host: host, port: 8765, path: '/sync'),
      );
      ref.read(hostPairingCredentialsProvider.notifier).state = credentials;
      ref.read(executionModeProvider.notifier).state = ExecutionMode.standaloneHost;
      if (mounted) setState(() => _generatingHost = false);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _generatingHost = false;
          _status = 'Could not prepare host pairing: $error';
        });
      }
    }
  }

  Future<String> _firstLanIpv4() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (address.type == InternetAddressType.IPv4 && !address.isLoopback) {
          return address.address;
        }
      }
    }
    throw StateError('Connect to Wi-Fi or Ethernet before creating a host QR code.');
  }

  void _onModeChanged(ExecutionMode mode) {
    ref.read(executionModeProvider.notifier).state = mode;
  }

  void _onCompanionPaired(PairingCredentials credentials) {
    ref.read(pairedHostCredentialsProvider.notifier).state = credentials;
    ref.read(executionModeProvider.notifier).state = ExecutionMode.lanCompanion;
    setState(() => _status = 'Paired with ${credentials.endpoint.host}.');
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(executionModeProvider);
    final host = ref.watch(hostPairingCredentialsProvider);
    final paired = ref.watch(pairedHostCredentialsProvider);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: <Widget>[
        Text('Device & connection settings', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 12),
        SegmentedButton<ExecutionMode>(
          segments: const <ButtonSegment<ExecutionMode>>[
            ButtonSegment(value: ExecutionMode.standaloneHost, label: Text('Host'), icon: Icon(Icons.phone_android)),
            ButtonSegment(value: ExecutionMode.lanCompanion, label: Text('Companion'), icon: Icon(Icons.tablet_android)),
            ButtonSegment(value: ExecutionMode.lightEdge, label: Text('Light Edge'), icon: Icon(Icons.bolt)),
          ],
          selected: <ExecutionMode>{mode},
          onSelectionChanged: (selection) => _onModeChanged(selection.single),
        ),
        const SizedBox(height: 16),
        if (host == null)
          Card(
            child: ListTile(
              leading: const Icon(Icons.qr_code_2),
              title: const Text('Prepare a host QR and PIN'),
              subtitle: const Text('The host listens on the selected LAN address at port 8765.'),
              trailing: _generatingHost
                  ? const CircularProgressIndicator()
                  : const Icon(Icons.chevron_right),
              onTap: _generatingHost ? null : _createHostCredentials,
            ),
          )
        else
          SizedBox(
            height: 620,
            child: ExecutionModePairingScreen(
              hostCredentials: host,
              initialMode: mode,
              mdnsDiscoveryService: _discovery,
              onModeChanged: _onModeChanged,
              onCompanionPaired: _onCompanionPaired,
            ),
          ),
        if (paired != null)
          ListTile(
            leading: const Icon(Icons.link),
            title: const Text('Paired host'),
            subtitle: Text('${paired.endpoint.host}:${paired.endpoint.port}'),
            trailing: IconButton(
              tooltip: 'Forget paired host',
              icon: const Icon(Icons.link_off),
              onPressed: () {
                ref.read(pairedHostCredentialsProvider.notifier).state = null;
                setState(() => _status = 'Pairing removed from this device.');
              },
            ),
          ),
        const Card(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text('Use LAN Companion for a paired tablet, Standalone Host for this device as the tutor, or Light Edge for the reduced-memory Gemma profile.'),
          ),
        ),
        if (_status != null) Padding(
          padding: const EdgeInsets.all(8),
          child: Text(_status!),
        ),
      ],
    );
  }
}
