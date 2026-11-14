import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/crypto/rotating_id.dart';
import '../core/crypto/unit_keys.dart';
import '../core/mesh/mesh_node.dart';
import '../core/protocol/sealed_envelope.dart';
import 'lan_link.dart';

const int defaultBeaconPort = 47999;
const Duration _beaconInterval = Duration(seconds: 3);
const Duration _dialTimeout = Duration(seconds: 5);
const Duration _helloTimeout = Duration(seconds: 5);
const Duration _dialBackoff = Duration(seconds: 3);

/// Beacon-triggered dials in flight at once, across all peers.
const int _maxConcurrentDials = 8;

/// Beacon plaintext: rotating ID (8) || TCP port (2, big-endian).
const int _beaconLength = rotatingIdLength + 2;

/// The unit material a link or beacon needs: one seal key and the roster resolver.
class _Unit {
  const _Unit(this.envelope, this.idKey, this.resolver);

  final SealedEnvelope envelope;
  final Uint8List idKey;
  final RosterResolver resolver;
}

/// Brings LAN neighbours into a [MeshNode]: accepts TCP links, dials peers found by UDP
/// beacon or entered by hand, and keeps at most one link per PeerID. Every byte it sends
/// on a socket or as a beacon is sealed with the unit seal key; see [configure].
class LanManager {
  LanManager({
    required this.node,
    this.beaconPort = defaultBeaconPort,
    this.beaconInterval = _beaconInterval,
    this.linkIdleTimeout = defaultLinkIdleTimeout,
    this.dialBackoff = _dialBackoff,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final MeshNode node;

  /// Beacons are sent to this UDP port on the local broadcast address. 0 disables them.
  final int beaconPort;
  final Duration beaconInterval;

  /// A link that opens no frame for this long is closed.
  final Duration linkIdleTimeout;

  /// After a beacon-triggered dial to a peer fails, beacons for that peer are ignored
  /// for this long.
  final Duration dialBackoff;
  final DateTime Function() _clock;

  _Unit? _unit;
  ServerSocket? _server;
  RawDatagramSocket? _beaconListener;
  RawDatagramSocket? _beaconSender;
  Timer? _beaconTimer;
  final Map<String, LanLink> _links = {};
  // Links still in their handshake; stop() closes them.
  final Set<LanLink> _pending = {};
  // PeerIDs (hex) with a beacon-triggered dial in flight, or backing off after one failed.
  final Set<String> _dialing = {};
  final Set<String> _backingOff = {};
  // Sealed beacons already acted on (hex of the datagram) with when they were seen.
  final Map<String, DateTime> _seenBeacons = {};
  // Bumped by stop(); work started under an older generation is abandoned.
  int _generation = 0;
  int _dropped = 0;

  int get linkCount => _links.length;

  Set<String> get linkedPeerIds => _links.keys.toSet();

  /// Sealed frames and beacons that failed to open and were discarded.
  int get droppedFrames => _dropped;

  /// Sets the unit seal key, ID key and roster. Call before [start], and again whenever
  /// the roster changes; open links keep the configuration they were made with.
  Future<void> configure(
    UnitKeys keys,
    List<List<int>> rosterPublicKeys,
  ) async {
    _unit = _Unit(
      SealedEnvelope(keys.sealKey, clock: _clock),
      Uint8List.fromList(keys.idKey),
      await RosterResolver.create(keys.idKey, rosterPublicKeys, clock: _clock),
    );
  }

  _Unit get _requireUnit =>
      _unit ?? (throw StateError('LanManager is not configured with a unit'));

  /// Listens for links on an ephemeral TCP port and returns that port.
  Future<int> start() async {
    _requireUnit;
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    server.listen((socket) => unawaited(_adopt(socket, isDialer: false)));
    if (beaconPort > 0) await _startBeacons();
    return server.port;
  }

  /// Dials a neighbour by address. Throws if it cannot be reached.
  Future<void> connect(String host, int port) async {
    _requireUnit;
    await _dial(host, port);
  }

  /// Closes every link, including those still in their handshake, and abandons dials
  /// in flight, so nothing made before the call survives it.
  Future<void> stop() async {
    _generation++;
    _beaconTimer?.cancel();
    _beaconTimer = null;
    _beaconListener?.close();
    _beaconListener = null;
    _beaconSender?.close();
    _beaconSender = null;
    await _server?.close();
    _server = null;
    _dialing.clear();
    _backingOff.clear();
    _seenBeacons.clear();
    for (final link in [..._pending, ..._links.values]) {
      await link.close();
    }
    _pending.clear();
    _links.clear();
  }

  Future<Uint8List> _ownRotatingId(_Unit unit) =>
      rotatingId(unit.idKey, node.identity.publicKey, epochAt(_clock()));

  /// Returns true when the dial produced a link.
  Future<bool> _dial(String host, int port) async {
    final generation = _generation;
    final socket = await Socket.connect(host, port, timeout: _dialTimeout);
    if (generation != _generation) {
      socket.destroy();
      return false;
    }
    return _adopt(socket, isDialer: true);
  }

  /// Runs the handshake on [socket] and registers the link. Returns true when it did.
  Future<bool> _adopt(Socket socket, {required bool isDialer}) async {
    final generation = _generation;
    final unit = _requireUnit;
    final localId = await _ownRotatingId(unit);
    if (generation != _generation) {
      socket.destroy();
      return false;
    }
    final link = LanLink.attach(
      socket,
      envelope: unit.envelope,
      resolver: unit.resolver,
      localRotatingId: localId,
      isDialer: isDialer,
      idleTimeout: linkIdleTimeout,
      onDrop: () => _dropped++,
    );
    _pending.add(link);
    final Uint8List remoteId;
    try {
      remoteId = await link.remotePeerId.timeout(_helloTimeout);
    } on Exception {
      // SocketException (closed or rejected hello) or TimeoutException.
      await link.close();
      return false;
    } finally {
      _pending.remove(link);
    }
    final key = _hex(remoteId);
    final existing = _links[key];
    if (generation != _generation ||
        key == _hex(node.peerId) ||
        (existing != null && !_replaces(link, existing, key))) {
      await link.close();
      return false;
    }
    _links[key] = link;
    node.addTransport(link);
    unawaited(
      link.closed.then((_) async {
        if (identical(_links[key], link)) _links.remove(key);
        await node.removeTransport(link);
      }),
    );
    if (existing != null) await existing.close();
    return true;
  }

  /// Decides which of two links to the same peer survives. Both ends reach the same
  /// verdict: a link dialed by the lower PeerID beats one dialed by the higher; between
  /// links in the same direction, the newer wins, so a stale or squatted link cannot
  /// lock the peer out.
  bool _replaces(LanLink newer, LanLink older, String peerHex) {
    final selfIsLower = _hex(node.peerId).compareTo(peerHex) < 0;
    bool preferred(LanLink link) => link.isDialer == selfIsLower;
    return preferred(newer) || !preferred(older);
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
      if (datagram != null) unawaited(_onBeacon(datagram));
    });
    _beaconSender = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _beaconSender!.broadcastEnabled = true;
    _beaconTimer = Timer.periodic(beaconInterval, (_) => _sendBeacon());
    unawaited(_sendBeacon());
  }

  Future<void> _sendBeacon() async {
    final unit = _unit;
    final port = _server?.port;
    if (unit == null || port == null) return;
    try {
      final plaintext = Uint8List(_beaconLength)
        ..setRange(0, rotatingIdLength, await _ownRotatingId(unit));
      ByteData.sublistView(plaintext).setUint16(rotatingIdLength, port);
      final sealed = await unit.envelope.seal(plaintext);
      _beaconSender?.send(
        sealed,
        InternetAddress('255.255.255.255'),
        beaconPort,
      );
    } catch (_) {
      // A beacon is best effort; the next tick tries again.
    }
  }

  /// True the first time [wire] is seen within the seal freshness window.
  bool _firstSighting(List<int> wire) {
    final now = _clock();
    _seenBeacons.removeWhere(
      (_, seenAt) => now.difference(seenAt).abs() > sealFreshnessWindow,
    );
    final key = _hex(wire);
    if (_seenBeacons.containsKey(key)) return false;
    _seenBeacons[key] = now;
    return true;
  }

  Future<void> _onBeacon(Datagram datagram) async {
    final unit = _unit;
    final generation = _generation;
    if (unit == null) return;
    try {
      final Uint8List plaintext;
      try {
        plaintext = await unit.envelope.open(datagram.data);
      } on SealedEnvelopeException {
        _dropped++;
        return;
      }
      if (plaintext.length != _beaconLength) {
        _dropped++;
        return;
      }
      // A replayed beacon (same sealed bytes, maybe a spoofed source) is ignored.
      if (generation != _generation || !_firstSighting(datagram.data)) return;
      final member = await unit.resolver.resolve(
        Uint8List.sublistView(plaintext, 0, rotatingIdLength),
      );
      if (member == null || generation != _generation) return;
      final peerHex = _hex(member.peerId);
      if (peerHex == _hex(node.peerId) || _links.containsKey(peerHex)) return;
      final port = ByteData.sublistView(plaintext).getUint16(rotatingIdLength);
      if (port == 0) return;
      // One dial per member at a time, whatever address its beacons claim.
      if (_dialing.contains(peerHex) ||
          _backingOff.contains(peerHex) ||
          _dialing.length >= _maxConcurrentDials) {
        return;
      }

      _dialing.add(peerHex);
      // Both members hear each other's beacons. The lower PeerID dials; the higher waits
      // two beacon intervals and dials only if no link came, so the pair does not build
      // two links and lose packets while one replaces the other.
      if (peerHex.compareTo(_hex(node.peerId)) < 0) {
        await Future<void>.delayed(beaconInterval * 2);
        if (generation != _generation) return;
        if (_links.containsKey(peerHex)) {
          _dialing.remove(peerHex);
          return;
        }
      }
      final linked = await _dial(
        datagram.address.address,
        port,
      ).catchError((Object _) => false);
      if (generation != _generation) return;
      _dialing.remove(peerHex);
      if (!linked) {
        _backingOff.add(peerHex);
        Timer(dialBackoff, () {
          if (generation == _generation) _backingOff.remove(peerHex);
        });
      }
    } catch (_) {
      // A hostile or stale beacon must never fail the zone; the next beacon retries.
    }
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
