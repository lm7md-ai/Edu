import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:nsd/nsd.dart' as nsd;

/// Resolved host found through the app's local-network mDNS service.
final class DiscoveredHost {
  const DiscoveredHost({
    required this.name,
    required this.host,
    required this.port,
    this.isAvailable = true,
  });

  final String name;
  final String host;
  final int port;
  final bool isAvailable;

  Uri get websocketUri => Uri(
        scheme: 'ws',
        host: host,
        port: port,
        path: 'sync',
      );
}

/// Advertises or discovers Neural Tutor WebSocket hosts on the local network.
final class MdnsDiscoveryService {
  static const String serviceType = '_neuraltutor._tcp';

  final StreamController<DiscoveredHost> _hosts =
      StreamController<DiscoveredHost>.broadcast(sync: true);
  nsd.Registration? _registration;
  nsd.Discovery? _discovery;
  void Function()? _discoveryListener;
  final Map<String, DiscoveredHost> _publishedHosts = <String, DiscoveredHost>{};
  bool _disposed = false;

  Stream<DiscoveredHost> get hosts => _hosts.stream;

  Future<void> advertise({required String name, required int port}) async {
    if (_disposed) throw StateError('mDNS service is disposed.');
    if (port < 1 || port > 65535) throw RangeError.range(port, 1, 65535, 'port');
    await stopAdvertising();
    _registration = await nsd.register(nsd.Service(
      name: name,
      type: serviceType,
      port: port,
      txt: <String, Uint8List?>{
        'v': Uint8List.fromList(utf8.encode('1')),
        'path': Uint8List.fromList(utf8.encode('/sync')),
      },
    ));
  }

  Future<void> startDiscovery() async {
    if (_disposed) throw StateError('mDNS service is disposed.');
    if (_discovery != null) return;
    final discovery = await nsd.startDiscovery(serviceType, autoResolve: true);
    _discovery = discovery;
    void refresh() => _publish(discovery.services);
    _discoveryListener = refresh;
    discovery.addListener(refresh);
    refresh();
  }

  void _publish(List<nsd.Service> services) {
    final current = <String, DiscoveredHost>{};
    for (final service in services) {
      final port = service.port;
      final host = service.host ??
          (service.addresses?.isNotEmpty == true
              ? service.addresses!.first.address
              : null);
      final name = service.name;
      if (port == null || host == null || name == null) continue;
      final entry = DiscoveredHost(name: name, host: host, port: port);
      current['${entry.name}|${entry.host}|${entry.port}'] = entry;
    }
    for (final entry in current.entries) {
      if (!_publishedHosts.containsKey(entry.key)) _hosts.add(entry.value);
    }
    for (final entry in _publishedHosts.entries) {
      if (!current.containsKey(entry.key)) {
        final previous = entry.value;
        _hosts.add(DiscoveredHost(
          name: previous.name,
          host: previous.host,
          port: previous.port,
          isAvailable: false,
        ));
      }
    }
    _publishedHosts
      ..clear()
      ..addAll(current);
  }

  Future<void> stopDiscovery() async {
    final discovery = _discovery;
    _discovery = null;
    if (discovery == null) return;
    final listener = _discoveryListener;
    if (listener != null) discovery.removeListener(listener);
    _discoveryListener = null;
    await nsd.stopDiscovery(discovery);
    for (final host in _publishedHosts.values) {
      _hosts.add(DiscoveredHost(
        name: host.name,
        host: host.host,
        port: host.port,
        isAvailable: false,
      ));
    }
    _publishedHosts.clear();
  }

  Future<void> stopAdvertising() async {
    final registration = _registration;
    _registration = null;
    if (registration != null) await nsd.unregister(registration);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stopDiscovery();
    await stopAdvertising();
    await _hosts.close();
  }
}
