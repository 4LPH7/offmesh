import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/crypto/identity.dart';
import 'package:offmesh/core/mesh/mesh_node.dart';
import 'package:offmesh/core/protocol/packet.dart';

import 'fake_network.dart';

Future<void> _noDelay(Duration _) async {}

void main() {
  test('a flood of spoofed handshake openings cannot grow responder state past the cap', () async {
    final topology = FakeTopology(2, const [(0, 1)]);
    final victim = MeshNode(
      identity: await Identity.generate(),
      transports: topology.transportsOf(1),
      random: Random(1),
      delay: _noDelay,
    )..start();
    final attacker = topology.transportsOf(0).single;
    final random = Random(2);

    for (var i = 0; i < maxPendingHandshakes + 20; i++) {
      final frame = Packet(
        type: PacketType.noiseHandshake,
        ttl: 1,
        packetId: i + 1,
        senderId: Uint8List.fromList(List.generate(8, (_) => random.nextInt(256))),
        recipientId: victim.peerId,
        fragIdx: 0,
        fragTotal: 1,
        payload: Uint8List.fromList(List.generate(32, (_) => random.nextInt(256))),
      ).encode();
      await attacker.send(frame);
    }
    await Future<void>.delayed(Duration.zero);
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(victim.pendingResponderCount, lessThanOrEqualTo(maxPendingHandshakes));
  });

  test('a peer with a full queue refuses further messages instead of growing memory', () async {
    final topology = FakeTopology(1, const []);
    final node = MeshNode(
      identity: await Identity.generate(),
      transports: topology.transportsOf(0),
      delay: _noDelay,
    )..start();
    final unreachable = Uint8List.fromList(List.filled(8, 0x77));

    for (var i = 0; i < maxQueuedPerPeer; i++) {
      await node.sendText(unreachable, Uint8List.fromList([i]));
    }

    await expectLater(
      node.sendText(unreachable, Uint8List.fromList([0xFF])),
      throwsStateError,
    );
  });
}
