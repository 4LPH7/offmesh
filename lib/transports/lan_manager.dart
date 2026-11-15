import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/crypto/rotating_id.dart';
import '../core/crypto/unit_keys.dart';
import '../core/mesh/mesh_node.dart';
import '../core/posture.dart';
import '../core/protocol/sealed_envelope.dart';
import 'lan_link.dart';

const int defaultBeaconPort = 47999;
const Duration _beaconInterval = Duration(seconds: 3);
const Duration _dialTimeout = Duration(seconds: 5);
const Duration _helloTimeout = Duration(seconds: 5);

/// Unauthenticated sockets allowed at once (accepted or dialled, before their hello).
const int maxPendingLinks = 16;
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
    PostureController? posture,
  }) : _clock = clock ?? DateTime.now,
       posture = posture ?? PostureController();

  final MeshNode node;

  /// Every transmission here checks this first. ChatController changes it.
  final PostureController posture;

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

  /// The TCP port this phone listens on, or null when it is not listening.
  int? get listenPort => _server?.port;

  /// True while the beacon listener is bound. Tests use it to check that Silent leaves
  /// no UDP socket behind.
  bool get beaconsRunning => _beaconListener != null;

  /// Listens for links on an ephemeral TCP port and returns that port. Does nothing and
  /// returns the current port when already listening. Refused in Silent.
  Future<int> start() async {
    _requireUnit;
    if (posture.current == Posture.silent) {
      throw StateError('Silent: not listening');
    }
    final running = _server;
    if (running != null) return running.port;
    final generation = _generation;
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    // Silent (or a stop) during the bind must not leave a listener up.
    if (_isStale(generation)) {
      await server.close();
      throw StateError('Silent: not listening');
    }
    _server = server;
    server.listen((socket) {
      // Sockets are unauthenticated until their hello arrives. Refuse new ones past the
      // cap so a flood of silent connections cannot exhaust file descriptors.
      if (_pending.length >= maxPendingLinks) {
        socket.destroy();
        return;
      }
      unawaited(_adopt(socket, isDialer: false));
    });
    if (beaconPort > 0) await _startBeacons(generation);
    // Silent or a stop during the beacon binds. stop() already took the server. Only
    // a same-generation Silent still needs a stop() here, and a newer generation owns
    // whatever it set up, so this never touches it.
    if (_isStale(generation)) {
      if (generation == _generation) await stop();
      throw StateError('Silent: not listening');
    }
    return server.port;
  }

  /// True once a stop, or Silent, has happened since [generation] was taken.
  bool _isStale(int generation) =>
      generation != _generation || posture.current == Posture.silent;

  /// Dials a neighbour by address. Throws if it cannot be reached or in Silent.
  Future<void> connect(String host, int port) async {
    _requireUnit;
    if (posture.current == Posture.silent) {
      throw StateError('Silent: not dialing');
    }
    await _dial(host, port);
  }

  /// Closes every link, including those still in their handshake, and abandons dials
  /// in flight, so nothing made before the call survives it.
  Future<void> stop() async {
    _generation++;
    // Every handle is taken before the first await. A start() that runs while the
    // closes below are pending then sees a clean state, and its new listener and links
    // are never cleared by this call.
    final links = [..._pending, ..._links.values];
    final server = _server;
    final listener = _beaconListener;
    final sender = _beaconSender;
    _beaconTimer?.cancel();
    _beaconTimer = null;
    _beaconListener = null;
    _beaconSender = null;
    _server = null;
    _pending.clear();
    _links.clear();
    _dialing.clear();
    _backingOff.clear();
    _seenBeacons.clear();
    listener?.close();
    sender?.close();
    await server?.close();
    for (final link in links) {
      await link.close();
    }
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
    if (generation != _generation || posture.current == Posture.silent) {
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

  /// Binds the beacon sockets for [generation]. Each bind is awaited, so handles are
  /// stored only while that generation is still current. A stale bind closes what it
  /// opened and stores nothing; the caller in [start] reports the stale state.
  Future<void> _startBeacons(int generation) async {
    final listener = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      beaconPort,
      reuseAddress: true,
    );
    if (_isStale(generation)) {
      listener.close();
      return;
    }
    final sender = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    if (_isStale(generation)) {
      listener.close();
      sender.close();
      return;
    }
    sender.broadcastEnabled = true;
    listener.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = listener.receive();
      if (datagram != null) unawaited(_onBeacon(datagram));
    });
    _beaconListener = listener;
    _beaconSender = sender;
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
      // Checked after the awaits: a switch to Quiet or Silent during sealing must stop this send.
      if (posture.current != Posture.normal) return;
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
    // Beacons only drive dials in Normal; Quiet and Silent never dial on their own.
    if (unit == null || posture.current != Posture.normal) return;
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
      // The posture may have changed while waiting; a dial must not start after Quiet or Silent.
      if (posture.current != Posture.normal) {
        _dialing.remove(peerHex);
        return;
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
