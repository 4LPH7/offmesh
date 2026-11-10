import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/crypto/identity.dart';
import 'package:offmesh/core/mesh/mesh_node.dart';
import 'package:offmesh/core/protocol/packet.dart';

import 'fake_network.dart';

Future<void> _noDelay(Duration _) async {}

Uint8List _utf8(String text) => Uint8List.fromList(utf8.encode(text));

bool _contains(Uint8List haystack, Uint8List needle) {
  for (var start = 0; start + needle.length <= haystack.length; start++) {
    var match = true;
    for (var i = 0; i < needle.length; i++) {
      if (haystack[start + i] != needle[i]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}

class _Harness {
  _Harness._(this.topology, this.nodes, this.inbox);

  final FakeTopology topology;
  final List<MeshNode> nodes;
  final List<List<ReceivedMessage>> inbox;

  static Future<_Harness> build(int count, List<(int, int)> edges) async {
    final topology = FakeTopology(count, edges);
    final nodes = <MeshNode>[];
    for (var i = 0; i < count; i++) {
      nodes.add(MeshNode(
        identity: await Identity.generate(),
        transports: topology.transportsOf(i),
        random: Random(i),
        delay: _noDelay,
      )..start());
    }
    final inbox = List.generate(count, (_) => <ReceivedMessage>[]);
    for (var i = 0; i < count; i++) {
      nodes[i].messages.listen(inbox[i].add);
    }
    return _Harness._(topology, nodes, inbox);
  }

  int handshakeFrames() => topology.network.frames
      .where((frame) => Packet.decode(frame).type == PacketType.noiseHandshake)
      .length;
}

void main() {
  group('MeshNode over a 5-node line (A-B-C-D-E)', () {
    const line = [(0, 1), (1, 2), (2, 3), (3, 4)];

    test('delivers an encrypted message across four hops, only to the recipient', () async {
      final h = await _Harness.build(5, line);

      await h.nodes[0].sendText(h.nodes[4].peerId, _utf8('hello across four hops'));
      await pumpEventQueue();

      expect(h.inbox[4], hasLength(1));
      expect(utf8.decode(h.inbox[4].single.plaintext), 'hello across four hops');
      expect(h.inbox[4].single.senderId, h.nodes[0].peerId);
      for (final relay in [0, 1, 2, 3]) {
        expect(h.inbox[relay], isEmpty, reason: 'node $relay must not receive it');
      }
    });

    test('a second message reuses the session: no new handshake', () async {
      final h = await _Harness.build(5, line);
      await h.nodes[0].sendText(h.nodes[4].peerId, _utf8('first'));
      await pumpEventQueue();
      final handshakesAfterFirst = h.handshakeFrames();

      await h.nodes[0].sendText(h.nodes[4].peerId, _utf8('second'));
      await pumpEventQueue();

      expect(h.handshakeFrames(), handshakesAfterFirst);
      expect(h.inbox[4].map((m) => utf8.decode(m.plaintext)), ['first', 'second']);
    });

    test('relays see only ciphertext, never the plaintext', () async {
      final h = await _Harness.build(5, line);
      final secret = _utf8('TOP-SECRET-MARKER-7431');

      await h.nodes[0].sendText(h.nodes[4].peerId, secret);
      await pumpEventQueue();

      expect(h.inbox[4], hasLength(1));
      expect(h.topology.network.frames, isNotEmpty);
      for (final frame in h.topology.network.frames) {
        expect(_contains(frame, secret), isFalse);
      }
    });

    test('a message with TTL 2 does not reach a node 4 hops away', () async {
      final h = await _Harness.build(5, line);
      await h.nodes[0].sendText(h.nodes[4].peerId, _utf8('established'));
      await pumpEventQueue();

      await h.nodes[0].sendText(h.nodes[4].peerId, _utf8('short-lived'), ttl: 2);
      await pumpEventQueue();

      expect(h.inbox[4].map((m) => utf8.decode(m.plaintext)), ['established']);
    });

    test('a long message is fragmented and reassembled intact', () async {
      final h = await _Harness.build(5, line);
      final long = Uint8List.fromList(List.generate(1500, (i) => i & 0xFF));

      await h.nodes[0].sendText(h.nodes[4].peerId, long);
      await pumpEventQueue();

      expect(h.inbox[4], hasLength(1));
      expect(h.inbox[4].single.plaintext, long);
    });
  });

  group('MeshNode simultaneous first contact', () {
    test('two nodes that message each other at once both receive exactly one message', () async {
      final h = await _Harness.build(2, const [(0, 1)]);

      await Future.wait([
        h.nodes[0].sendText(h.nodes[1].peerId, _utf8('from zero')),
        h.nodes[1].sendText(h.nodes[0].peerId, _utf8('from one')),
      ]);
      await pumpEventQueue();

      expect(h.inbox[1].map((m) => utf8.decode(m.plaintext)), ['from zero']);
      expect(h.inbox[0].map((m) => utf8.decode(m.plaintext)), ['from one']);
    });
  });
}
