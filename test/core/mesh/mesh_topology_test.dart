import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/crypto/identity.dart';
import 'package:offmesh/core/mesh/router.dart';
import 'package:offmesh/core/protocol/packet.dart';

import 'fake_network.dart';

Future<void> _noDelay(Duration _) async {}

void main() {
  test('a broadcast on a 5-node ring reaches every node once and floods without a storm', () async {
    final ids = [for (var i = 0; i < 5; i++) (await Identity.generate()).peerId];
    final topology = FakeTopology(5, const [(0, 1), (1, 2), (2, 3), (3, 4), (4, 0)]);
    final delivered = List.generate(5, (_) => <Packet>[]);
    final routers = [
      for (var i = 0; i < 5; i++)
        MeshRouter(
          localId: ids[i],
          transports: topology.transportsOf(i),
          onDeliver: delivered[i].add,
          random: Random(i),
          delay: _noDelay,
        )..start(),
    ];

    await routers[0].originate(Packet(
      type: PacketType.announce,
      ttl: 7,
      packetId: 42,
      senderId: ids[0],
      recipientId: Packet.broadcastId,
      fragIdx: 0,
      fragTotal: 1,
      payload: Uint8List(0),
    ));
    await pumpEventQueue();

    for (var i = 1; i < 5; i++) {
      expect(delivered[i], hasLength(1), reason: 'node $i should deliver once');
    }
    expect(delivered[0], isEmpty, reason: 'the origin does not deliver its own packet');
    // Origin sends on 2 links; each of the other 4 nodes relays exactly once.
    expect(topology.network.transmissions, 6);
  });

  test('a unicast addressed to one node on a ring is delivered only there', () async {
    final ids = [for (var i = 0; i < 4; i++) (await Identity.generate()).peerId];
    final topology = FakeTopology(4, const [(0, 1), (1, 2), (2, 3), (3, 0)]);
    final delivered = List.generate(4, (_) => <Packet>[]);
    final routers = [
      for (var i = 0; i < 4; i++)
        MeshRouter(
          localId: ids[i],
          transports: topology.transportsOf(i),
          onDeliver: delivered[i].add,
          random: Random(i),
          delay: _noDelay,
        )..start(),
    ];

    await routers[0].originate(Packet(
      type: PacketType.noiseTransport,
      ttl: 7,
      packetId: 7,
      senderId: ids[0],
      recipientId: ids[2],
      fragIdx: 0,
      fragTotal: 1,
      payload: Uint8List.fromList([1, 2, 3]),
    ));
    await pumpEventQueue();

    expect(delivered[2], hasLength(1));
    expect(delivered[1], isEmpty);
    expect(delivered[3], isEmpty);
  });
}
