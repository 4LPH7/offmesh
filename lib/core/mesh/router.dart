import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../protocol/packet.dart';
import '../protocol/seen_cache.dart';
import 'transport.dart';

typedef PacketSink = void Function(Packet packet);
typedef Pause = Future<void> Function(Duration duration);

const Duration minRelayJitter = Duration(milliseconds: 15);
const Duration maxRelayJitter = Duration(milliseconds: 85);

/// Floods packets across every transport, delivers those addressed here, and relays the rest.
///
/// Flood routing: no routing tables. Each node relays a packet at most once (SeenCache),
/// never back out the link it arrived on, and drops it when TTL runs out.
class MeshRouter {
  MeshRouter({
    required this.localId,
    required List<MeshTransport> transports,
    required PacketSink onDeliver,
    SeenCache? seenCache,
    Random? random,
    Pause? delay,
    DateTime Function()? clock,
  })  : _transports = List.unmodifiable(transports),
        _onDeliver = onDeliver,
        _seen = seenCache ?? SeenCache(clock: clock ?? DateTime.now),
        _random = random ?? Random.secure(),
        _delay = delay ?? Future<void>.delayed;

  final Uint8List localId;
  final List<MeshTransport> _transports;
  final PacketSink _onDeliver;
  final SeenCache _seen;
  final Random _random;
  final Pause _delay;
  final List<StreamSubscription<Uint8List>> _subscriptions = [];

  void start() {
    for (final transport in _transports) {
      _subscriptions.add(
        transport.incoming.listen((frame) => _onFrame(transport, frame)),
      );
    }
  }

  Future<void> stop() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
  }

  /// Sends a packet this node created. It is recorded as seen first so the echo is dropped.
  Future<void> originate(Packet packet) async {
    _seen.isDuplicate(packet);
    await _sendEverywhere(packet.encode(), except: null);
  }

  Future<void> _onFrame(MeshTransport from, Uint8List frame) async {
    final Packet packet;
    try {
      packet = Packet.decode(frame);
    } on PacketFormatException {
      return;
    }
    if (_seen.isDuplicate(packet)) return;

    final addressedHere = packet.isBroadcast || _sameId(packet.recipientId, localId);
    if (addressedHere) _onDeliver(packet);

    final stillNeeded = packet.isBroadcast || !addressedHere;
    if (!stillNeeded || packet.ttl <= 1) return;

    await _delay(_relayJitter());
    await _sendEverywhere(_withTtl(packet, packet.ttl - 1).encode(), except: from);
  }

  Future<void> _sendEverywhere(Uint8List frame, {required MeshTransport? except}) async {
    await Future.wait([
      for (final transport in _transports)
        if (!identical(transport, except)) transport.send(frame),
    ]);
  }

  Duration _relayJitter() {
    final span = maxRelayJitter.inMilliseconds - minRelayJitter.inMilliseconds;
    return minRelayJitter + Duration(milliseconds: _random.nextInt(span + 1));
  }

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
