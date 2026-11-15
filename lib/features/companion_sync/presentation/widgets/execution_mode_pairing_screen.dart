import 'dart:async';

import 'package:edu/core/execution/execution_mode.dart';
import 'package:edu/features/companion_sync/data/services/mdns_discovery_service.dart';
import 'package:edu/features/companion_sync/domain/entities/pairing_credentials.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Execution-mode selector with host QR/PIN presentation and companion QR scan.
final class ExecutionModePairingScreen extends StatefulWidget {
  const ExecutionModePairingScreen({
    required this.hostCredentials,
    required this.onModeChanged,
    required this.onCompanionPaired,
    this.mdnsDiscoveryService,
    this.initialMode = ExecutionMode.standaloneHost,
    super.key,
  });

  final PairingCredentials hostCredentials;
  final ValueChanged<ExecutionMode> onModeChanged;
  final ValueChanged<PairingCredentials> onCompanionPaired;
  final MdnsDiscoveryService? mdnsDiscoveryService;
  final ExecutionMode initialMode;

  @override
  State<ExecutionModePairingScreen> createState() =>
      _ExecutionModePairingScreenState();
}

final class _ExecutionModePairingScreenState
    extends State<ExecutionModePairingScreen> {
  late ExecutionMode _mode;
  late PairingCredentials _hostCredentials;
  PairingCredentials? _scannedCredentials;
  final TextEditingController _pinController = TextEditingController();
  String? _status;
  bool _invalidPin = false;
  List<DiscoveredHost> _discoveredHosts = <DiscoveredHost>[];
  StreamSubscription<DiscoveredHost>? _discoverySubscription;
  Future<void> _networkModeTail = Future<void>.value();

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
    _hostCredentials = widget.hostCredentials;
    final discovery = widget.mdnsDiscoveryService;
    if (discovery != null) {
      _discoverySubscription = discovery.hosts.listen((host) {
        if (!mounted) return;
        setState(() {
          _discoveredHosts.removeWhere((existing) =>
              existing.name == host.name && existing.host == host.host &&
              existing.port == host.port);
          if (host.isAvailable) _discoveredHosts.add(host);
        });
      });
      _scheduleNetworkMode(_mode);
    }
  }

  @override
  void didUpdateWidget(covariant ExecutionModePairingScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hostCredentials != widget.hostCredentials) {
      _hostCredentials = widget.hostCredentials;
      if (_mode == ExecutionMode.standaloneHost) _scheduleNetworkMode(_mode);
    }
    if (oldWidget.initialMode != widget.initialMode && _mode != widget.initialMode) {
      _mode = widget.initialMode;
      _scheduleNetworkMode(_mode);
    }
    if (oldWidget.mdnsDiscoveryService != widget.mdnsDiscoveryService) {
      _discoveredHosts.clear();
      unawaited(_discoverySubscription?.cancel() ?? Future<void>.value());
      _discoverySubscription = null;
      final oldDiscovery = oldWidget.mdnsDiscoveryService;
      if (oldDiscovery != null) {
        _networkModeTail = _networkModeTail.then((_) async {
          await oldDiscovery.stopDiscovery();
          await oldDiscovery.stopAdvertising();
        });
      }
      final discovery = widget.mdnsDiscoveryService;
      if (discovery != null) {
        _discoverySubscription = discovery.hosts.listen((host) {
          if (!mounted) return;
          setState(() {
            _discoveredHosts.removeWhere((existing) =>
                existing.name == host.name && existing.host == host.host &&
                existing.port == host.port);
            if (host.isAvailable) _discoveredHosts.add(host);
          });
        });
        _scheduleNetworkMode(_mode);
      }
    }
  }

  @override
  void dispose() {
    _pinController.dispose();
    unawaited(_discoverySubscription?.cancel() ?? Future<void>.value());
    final discovery = widget.mdnsDiscoveryService;
    if (discovery != null) {
      _networkModeTail = _networkModeTail.then((_) async {
        await discovery.stopDiscovery();
        await discovery.stopAdvertising();
      });
      unawaited(_networkModeTail);
    }
    super.dispose();
  }

  void _scheduleNetworkMode(ExecutionMode mode) {
    _networkModeTail = _networkModeTail.then((_) => _updateNetworkMode(mode)).catchError(
      (Object error, StackTrace stackTrace) {
        if (mounted) setState(() => _status = 'Local network setup failed.');
      },
    );
  }

  Future<void> _updateNetworkMode(ExecutionMode mode) async {
    final discovery = widget.mdnsDiscoveryService;
    if (discovery == null) return;
    if (mode == ExecutionMode.standaloneHost) {
      await discovery.stopDiscovery();
      final port = _hostCredentials.endpoint.port;
      if (port > 0) {
        await discovery.advertise(
          name: 'NeuralTutor-Host',
          port: port,
        );
      }
    } else if (mode == ExecutionMode.lanCompanion) {
      await discovery.stopAdvertising();
      await discovery.startDiscovery();
    } else {
      await discovery.stopDiscovery();
      await discovery.stopAdvertising();
    }
  }

  void _selectMode(ExecutionMode? mode) {
    if (mode == null) return;
    setState(() {
      _mode = mode;
      _status = null;
      _invalidPin = false;
    });
    widget.onModeChanged(mode);
    _scheduleNetworkMode(mode);
  }

  void _onBarcode(BarcodeCapture capture) {
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null) continue;
      try {
        final credentials = PairingCredentials.fromQrPayload(value);
        setState(() {
          _scannedCredentials = credentials;
          _status = 'Host found. Enter the PIN shown on its screen.';
          _invalidPin = false;
        });
        return;
      } on FormatException {
        setState(() => _status = 'That QR code is not an Edu host pairing code.');
      }
    }
  }

  void _pair() {
    final credentials = _scannedCredentials;
    if (credentials == null) {
      setState(() => _status = 'Scan the host QR code before entering its PIN.');
      return;
    }
    if (_pinController.text.trim() != credentials.pin) {
      setState(() {
        _invalidPin = true;
        _status = 'PIN does not match the scanned host.';
      });
      return;
    }
    widget.onCompanionPaired(credentials);
    setState(() {
      _invalidPin = false;
      _status = 'Paired with ${credentials.endpoint.host}.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: <Widget>[
        Text('Execution mode', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 12),
        DropdownButtonFormField<ExecutionMode>(
          value: _mode,
          decoration: const InputDecoration(labelText: 'Choose how tutoring runs'),
          items: <DropdownMenuItem<ExecutionMode>>[
            for (final mode in ExecutionMode.values)
              DropdownMenuItem<ExecutionMode>(
                value: mode,
                child: Text(_modeName(mode)),
              ),
          ],
          onChanged: _selectMode,
        ),
        const SizedBox(height: 20),
        if (_mode == ExecutionMode.standaloneHost) _buildHostCard(context),
        if (_mode == ExecutionMode.lanCompanion) _buildCompanionCard(context),
        if (_mode == ExecutionMode.lightEdge)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Text('Light Edge runs the lightweight tutor profile on this device.'),
            ),
          ),
      ],
    );
  }

  Widget _buildHostCard(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text('Pair a companion tablet', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              QrImageView(
                data: _hostCredentials.toQrPayload(),
                size: 240,
                errorCorrectionLevel: QrErrorCorrectLevel.H,
                backgroundColor: Colors.white,
              ),
              const SizedBox(height: 12),
              SelectableText('PIN  ${_hostCredentials.pin}',
                  style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 8),
              SelectableText(_hostCredentials.endpoint.toString()),
              const SizedBox(height: 12),
            ],
          ),
        ),
      );

  Widget _buildCompanionCard(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: <Widget>[
              Text('Connect to a host phone', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              SizedBox(
                height: 260,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: MobileScanner(onDetect: _onBarcode),
                ),
              ),
              if (_discoveredHosts.isNotEmpty) ...<Widget>[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Discovered hosts', style: Theme.of(context).textTheme.titleMedium),
                ),
                for (final host in _discoveredHosts)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.wifi),
                    title: Text(host.name),
                    subtitle: Text('${host.host}:${host.port}'),
                  ),
              ],
              const SizedBox(height: 16),
              TextField(
                controller: _pinController,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: InputDecoration(
                  labelText: 'Six-digit host PIN',
                  errorText: _invalidPin ? 'PIN does not match' : null,
                  suffixIcon: IconButton(
                    onPressed: _pair,
                    tooltip: 'Pair with host',
                    icon: const Icon(Icons.link),
                  ),
                ),
                onSubmitted: (_) => _pair(),
              ),
              if (_status != null) Text(_status!),
            ],
          ),
        ),
      );

  static String _modeName(ExecutionMode mode) => switch (mode) {
        ExecutionMode.standaloneHost => 'Standalone Host',
        ExecutionMode.lanCompanion => 'LAN Companion',
        ExecutionMode.lightEdge => 'Light Edge',
      };
}
