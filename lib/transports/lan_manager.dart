import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/mesh/mesh_node.dart';
import 'lan_link.dart';

const int defaultBeaconPort = 47999;
const String _beaconTag = 'OFFM1';
const Duration _beaconInterval = Duration(seconds: 3);
const Duration _dialTimeout = Duration(seconds: 5);

/// Brings LAN neighbours into a [MeshNode]: accepts TCP links, dials peers found by UDP
/// beacon or entered by hand, and keeps at most one link per PeerID.
class LanManager {
  LanManager({
    required this.node,
    this.beaconPort = defaultBeaconPort,
    this.beaconInterval = _beaconInterval,
  });

  final MeshNode node;

  /// Beacons are sent to this UDP port on the local broadcast address. 0 disables them.
  final int beaconPort;
  final Duration beaconInterval;

  ServerSocket? _server;
  RawDatagramSocket? _beaconListener;
  RawDatagramSocket? _beaconSender;
  Timer? _beaconTimer;
  final Map<String, LanLink> _links = {};
  final Set<String> _dialing = {};

  int get linkCount => _links.length;

  Set<String> get linkedPeerIds => _links.keys.toSet();

  /// Listens for links on an ephemeral TCP port and returns that port.
  Future<int> start() async {
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    server.listen((socket) => unawaited(_adopt(socket)));
    if (beaconPort > 0) await _startBeacons();
    return server.port;
  }

  /// Dials a neighbour by address. Throws if it cannot be reached.
  Future<void> connect(String host, int port) async {
    final socket = await Socket.connect(host, port, timeout: _dialTimeout);
    await _adopt(socket);
  }

  Future<void> stop() async {
    _beaconTimer?.cancel();
    _beaconTimer = null;
    _beaconListener?.close();
    _beaconSender?.close();
    await _server?.close();
    _server = null;
    for (final link in _links.values.toList()) {
      await link.close();
    }
    _links.clear();
  }

  Future<void> _adopt(Socket socket) async {
    final link = LanLink.attach(socket, localPeerId: node.peerId);
    final Uint8List remoteId;
    try {
      remoteId = await link.remotePeerId;
    } on SocketException {
      return;
    }
    final key = _hex(remoteId);
    if (key == _hex(node.peerId) || _links.containsKey(key)) {
      await link.close();
      return;
    }
    _links[key] = link;
    node.addTransport(link);
    unawaited(link.closed.then((_) async {
      _links.remove(key);
      await node.removeTransport(link);
    }));
  }

  Future<void> _startBeacons() async {
    _beaconListener = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      beaconPort,
      reuseAddress: true,
    );
    _beaconListener!.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = _beaconListener?.receive();
      if (datagram != null) _onBeacon(datagram);
    });
    _beaconSender = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _beaconSender!.broadcastEnabled = true;
    _beaconTimer = Timer.periodic(beaconInterval, (_) => _sendBeacon());
    _sendBeacon();
  }

  void _sendBeacon() {
    final port = _server?.port;
    final sender = _beaconSender;
    if (port == null || sender == null) return;
    final payload = utf8.encode('$_beaconTag ${_hex(node.peerId)} $port');
    sender.send(payload, InternetAddress('255.255.255.255'), beaconPort);
  }

  void _onBeacon(Datagram datagram) {
    final parts = utf8.decode(datagram.data, allowMalformed: true).split(' ');
    if (parts.length != 3 || parts[0] != _beaconTag) return;
    final peerHex = parts[1];
    final port = int.tryParse(parts[2]);
    if (port == null || port <= 0 || port > 65535) return;
    if (peerHex == _hex(node.peerId) || _links.containsKey(peerHex)) return;

    final host = datagram.address.address;
    final dialKey = '$host:$port';
    if (!_dialing.add(dialKey)) return;
    unawaited(connect(host, port)
        .catchError((Object _) {})
        .whenComplete(() => _dialing.remove(dialKey)));
  }

  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
