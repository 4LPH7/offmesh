import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import '../protocol/packet.dart';
import '../protocol/seen_cache.dart';
import 'transport.dart';

typedef PacketSink = void Function(Packet packet);
typedef Pause = Future<void> Function(Duration duration);

const Duration minRelayJitter = Duration(milliseconds: 15);
const Duration maxRelayJitter = Duration(milliseconds: 85);

/// How long a reverse-path entry stays usable without fresh traffic from that sender.
const Duration routeMaxAge = Duration(minutes: 5);

/// How long a closer link keeps beating a farther one. Past this, the sender has
/// probably moved, so the farther link wins. Sized to one packet's relay trip.
final Duration closerRouteGrace = Duration(
  milliseconds: maxRelayJitter.inMilliseconds * maxTtl,
);

/// Most senders the reverse-path table remembers; the least recently heard is evicted.
const int maxRoutes = 256;

/// Most relays tracked for suppression at once; beyond this, relays still go out unsuppressed.
const int maxPendingRelays = 256;

/// The link a sender was last heard on, and how many hops away it was.
class _Route {
  const _Route(this.transport, this.hops, this.lastSeen);

  final MeshTransport transport;
  final int hops;
  final DateTime lastSeen;
}

/// Floods packets across every transport, delivers those addressed here, and relays the rest.
///
/// Managed flooding: each node relays a packet at most once (SeenCache), never back out
/// the link it arrived on, and drops it when TTL runs out. During the relay jitter, a copy
/// heard from another link means that neighbour already has it, so it is skipped too.
/// Accepted packets also teach a reverse-path table (sender -> link) for return traffic.
class MeshRouter {
  MeshRouter({
    required this.localId,
    required List<MeshTransport> transports,
    required PacketSink onDeliver,
    SeenCache? seenCache,
    Random? random,
    Pause? delay,
    DateTime Function()? clock,
  }) : _transports = List.of(transports),
       _onDeliver = onDeliver,
       _clock = clock ?? DateTime.now,
       _seen = seenCache ?? SeenCache(clock: clock ?? DateTime.now),
       _random = random ?? Random.secure(),
       _delay = delay ?? Future<void>.delayed;

  final Uint8List localId;
  final List<MeshTransport> _transports;
  final PacketSink _onDeliver;
  final DateTime Function() _clock;
  final SeenCache _seen;
  final Random _random;
  final Pause _delay;
  final Map<MeshTransport, StreamSubscription<Uint8List>> _subscriptions = {};
  final LinkedHashMap<String, _Route> _routes = LinkedHashMap();
  final Map<String, Set<MeshTransport>> _pending = {};
  bool _started = false;

  int _relaysSent = 0;
  int _relaysSuppressed = 0;

  /// Frames sent by relaying (not originating).
  int get relaysSent => _relaysSent;

  /// Relay sends skipped because that link already delivered the packet during the jitter.
  int get relaysSuppressed => _relaysSuppressed;

  void start() {
    _started = true;
    for (final transport in _transports) {
      _attach(transport);
    }
  }

  /// Adds a link that appeared at runtime (a LAN socket, a BLE connection).
  void addTransport(MeshTransport transport) {
    if (_transports.contains(transport)) return;
    _transports.add(transport);
    if (_started) _attach(transport);
  }

  /// Removes a link that closed. Packets are no longer sent or received on it.
  Future<void> removeTransport(MeshTransport transport) async {
    _transports.remove(transport);
    _routes.removeWhere((_, route) => identical(route.transport, transport));
    await _subscriptions.remove(transport)?.cancel();
  }

  Future<void> stop() async {
    _started = false;
    // Copy: a link closing during stop calls removeTransport, which edits the map.
    for (final subscription in _subscriptions.values.toList()) {
      await subscription.cancel();
    }
    _subscriptions.clear();
  }

  void _attach(MeshTransport transport) {
    _subscriptions[transport] = transport.incoming.listen(
      (frame) => _onFrame(transport, frame),
    );
  }

  /// The link [peerId] was last heard on, or null if unknown or older than [routeMaxAge].
  MeshTransport? nextHopFor(Uint8List peerId) {
    final key = peerId.hex;
    final route = _routes[key];
    if (route == null) return null;
    if (_clock().difference(route.lastSeen) > routeMaxAge) {
      _routes.remove(key);
      return null;
    }
    return route.transport;
  }

  /// Sends a packet this node created. It is recorded as seen first so the echo is dropped.
  Future<void> originate(Packet packet) async {
    _seen.isDuplicate(packet);
    await _sendTo(packet.encode(), skip: const {});
  }

  /// Sends a packet only on the reverse path toward its recipient, flooding if none is known.
  /// A failed send drops that route and floods instead; a flood failure still propagates.
  Future<void> originateTo(Packet packet) async {
    final hop = nextHopFor(packet.recipientId);
    if (hop != null) {
      _seen.isDuplicate(packet);
      try {
        await hop.send(packet.encode());
        return;
      } on Object {
        _routes.remove(packet.recipientId.hex);
      }
    }
    await originate(packet);
  }

  Future<void> _onFrame(MeshTransport from, Uint8List frame) async {
    final Packet packet;
    try {
      packet = Packet.decode(frame);
    } on PacketFormatException {
      return;
    }
    final key = _fingerprint(packet);
    if (_seen.isDuplicate(packet)) {
      _pending[key]?.add(from);
      return;
    }
    _learnRoute(packet, from);

    final addressedHere =
        packet.isBroadcast || _sameId(packet.recipientId, localId);
    if (addressedHere) _onDeliver(packet);

    final stillNeeded = packet.isBroadcast || !addressedHere;
    if (!stillNeeded || packet.ttl <= 1) return;

    final skip = {from};
    final tracked = _pending.length < maxPendingRelays;
    if (tracked) _pending[key] = skip;
    try {
      await _delay(_relayJitter());
    } finally {
      if (tracked) _pending.remove(key);
    }
    _relaysSuppressed += _transports
        .where((t) => !identical(t, from) && skip.contains(t))
        .length;
    _relaysSent += await _sendTo(
      _withTtl(packet, packet.ttl - 1).encode(),
      skip: skip,
    );
  }

  void _learnRoute(Packet packet, MeshTransport from) {
    final key = packet.senderId.hex;
    // ponytail: assumes senders originate at maxTtl (MeshNode does by default);
    // a smaller starting TTL looks farther. Carry an explicit hop count if that changes.
    final hops = maxTtl - packet.ttl;
    final now = _clock();
    final old = _routes.remove(key);
    final keepOld =
        old != null &&
        old.hops < hops &&
        now.difference(old.lastSeen) <= closerRouteGrace;
    if (_routes.length >= maxRoutes) _routes.remove(_routes.keys.first);
    _routes[key] = keepOld ? old : _Route(from, hops, now);
  }

  /// Sends [frame] on every link not in [skip]; returns how many sends were made.
  Future<int> _sendTo(
    Uint8List frame, {
    required Set<MeshTransport> skip,
  }) async {
    final targets = [
      for (final transport in List.of(_transports))
        if (!skip.contains(transport)) transport,
    ];
    await Future.wait([for (final transport in targets) transport.send(frame)]);
    return targets.length;
  }

  Duration _relayJitter() {
    final span = maxRelayJitter.inMilliseconds - minRelayJitter.inMilliseconds;
    return minRelayJitter + Duration(milliseconds: _random.nextInt(span + 1));
  }

  static String _fingerprint(Packet packet) =>
      '${packet.senderId.hex}:${packet.packetId}:${packet.fragIdx}';

  static Packet _withTtl(Packet packet, int ttl) => Packet(
    type: packet.type,
    ttl: ttl,
    packetId: packet.packetId,
    senderId: packet.senderId,
    recipientId: packet.recipientId,
    fragIdx: packet.fragIdx,
    fragTotal: packet.fragTotal,
    payload: packet.payload,
  );

  static bool _sameId(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
