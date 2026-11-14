import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/crypto/identity.dart';
import 'package:offmesh/core/mesh/mesh_node.dart';
import 'package:offmesh/core/mesh/transport.dart';
import 'package:offmesh/core/protocol/packet.dart';
import 'package:offmesh/core/protocol/sealed_envelope.dart';

import 'fake_network.dart';

/// 0-1-2-3-4-5-6-7-8-9.
const _line = [
  (0, 1),
  (1, 2),
  (2, 3),
  (3, 4),
  (4, 5),
  (5, 6),
  (6, 7),
  (7, 8),
  (8, 9),
];

/// Spine 0-1-2-3-4-5 with two diamonds (1-6-3 beside 1-2-3, 3-7-5 beside 3-4-5)
/// and a dead-end branch 2-8-9. Node 5 is 5 hops from node 0 on either path.
const _branching = [
  (0, 1),
  (1, 2),
  (2, 3),
  (3, 4),
  (4, 5),
  (1, 6),
  (6, 3),
  (3, 7),
  (7, 5),
  (2, 8),
  (8, 9),
];

Uint8List _message(int length, int seed) =>
    Uint8List.fromList(List.generate(length, (i) => (i * 31 + seed) & 0xFF));

/// Seals every frame on one link under the unit key, one frame at a time in order.
class _SealedTransport implements MeshTransport {
  _SealedTransport(this._inner, this._envelope);

  final MeshTransport _inner;
  final SealedEnvelope _envelope;
  Future<void> _sending = Future<void>.value();

  @override
  Stream<Uint8List> get incoming => _inner.incoming.asyncMap(_envelope.open);

  @override
  Future<void> send(Uint8List frame) {
    final run = _sending.then(
      (_) async => _inner.send(await _envelope.seal(frame)),
    );
    _sending = run;
    return run;
  }
}

/// Calls [onFrame] with each incoming frame just before the router sees it, and
/// yields to the event loop before each send, as a radio with a busy queue would.
class _TapTransport implements MeshTransport {
  _TapTransport(this._inner, this._onFrame);

  final MeshTransport _inner;
  final void Function(Uint8List frame) _onFrame;

  @override
  Stream<Uint8List> get incoming => _inner.incoming.map((frame) {
    _onFrame(frame);
    return frame;
  });

  @override
  Future<void> send(Uint8List frame) async {
    await Future<void>.delayed(Duration.zero);
    await _inner.send(frame);
  }
}

/// Two nodes joined by one link.
const _pair = [(0, 1)];

/// Edits each incoming frame before the node sees it; returning null drops the frame.
class _EditTransport implements MeshTransport {
  _EditTransport(this._inner, this._edit);

  final MeshTransport _inner;
  final Uint8List? Function(Uint8List frame) _edit;

  @override
  Stream<Uint8List> get incoming => _inner.incoming.expand((frame) {
    final edited = _edit(frame);
    return edited == null ? const <Uint8List>[] : [edited];
  });

  @override
  Future<void> send(Uint8List frame) => _inner.send(frame);
}

Packet _withPacket(Packet packet, {PacketType? type, int? packetId}) => Packet(
  type: type ?? packet.type,
  ttl: packet.ttl,
  packetId: packetId ?? packet.packetId,
  senderId: packet.senderId,
  recipientId: packet.recipientId,
  fragIdx: packet.fragIdx,
  fragTotal: packet.fragTotal,
  payload: packet.payload,
);

typedef _LinkWrapper = MeshTransport Function(int node, MeshTransport link);

class _Mesh {
  _Mesh._(this.topology, this.time, this.nodes, this.inbox, this.receipts);

  final FakeTopology topology;
  final VirtualTime time;
  final List<MeshNode> nodes;
  final List<List<ReceivedMessage>> inbox;
  final List<List<DeliveryReceiptEvent>> receipts;

  static Future<_Mesh> build(
    int count,
    List<(int, int)> edges, {
    _LinkWrapper? wrap,
  }) async {
    final topology = FakeTopology(count, edges);
    final time = VirtualTime();
    final nodes = <MeshNode>[];
    for (var i = 0; i < count; i++) {
      nodes.add(
        MeshNode(
          identity: await Identity.generate(),
          transports: [
            for (final link in topology.transportsOf(i))
              wrap == null ? link : wrap(i, link),
          ],
          random: Random(i),
          delay: time.pause,
          clock: () => time.now,
          onError: (error, stack) => fail('node $i: $error\n$stack'),
        )..start(),
      );
    }
    final inbox = List.generate(count, (_) => <ReceivedMessage>[]);
    final receipts = List.generate(count, (_) => <DeliveryReceiptEvent>[]);
    for (var i = 0; i < count; i++) {
      nodes[i].messages.listen(inbox[i].add);
      nodes[i].receipts.listen(receipts[i].add);
    }
    return _Mesh._(topology, time, nodes, inbox, receipts);
  }

  Future<int> send(int from, int to, Uint8List plaintext) =>
      nodes[from].sendText(nodes[to].peerId, plaintext);

  List<Packet> framesOfType(PacketType type) => [
    for (final frame in topology.network.frames)
      if (Packet.decode(frame).type == type) Packet.decode(frame),
  ];
}

void main() {
  test('a 10-node line carries a fragmented message 5 hops and floods its '
      'receipt back to the sender only', () async {
    final mesh = await _Mesh.build(10, _line);
    final message = _message(1500, 1);

    final packetId = await mesh.send(0, 5, message);
    await mesh.time.run();

    expect(mesh.inbox[5].single.plaintext, message);
    expect(mesh.inbox[5].single.senderId, mesh.nodes[0].peerId);
    final event = mesh.receipts[0].single;
    expect(event.peerId, mesh.nodes[5].peerId);
    expect(event.receipt.packetId, packetId);
    expect(event.receipt.receivedAt.isAfter(DateTime.utc(2026)), isTrue);
    for (var i = 1; i < 10; i++) {
      expect(mesh.receipts[i], isEmpty, reason: 'node $i got a receipt');
    }
    // Receipts flood (see MeshNode._sendReceipt): node 5 sends on both links (2 frames),
    // 4-3-2-1-0 relays one frame per hop (4), and 6-7-8-9 does the same (3). The
    expect(mesh.framesOfType(PacketType.ack), hasLength(9));
  });

  test('a reply that starts while a receipt is due keeps the shared session '
      'direction in nonce order', () async {
    final fromZero = _message(900, 3);
    final fromFive = _message(700, 4);
    late final _Mesh mesh;
    var armed = false;
    Future<int>? reply;
    // Node 5 starts a multi-fragment reply the instant the last fragment of
    // node 0's message arrives, so the reply and the receipt for that
    // message are encrypted on the 5->0 cipher back to back.
    mesh = await _Mesh.build(
      10,
      _line,
      wrap: (node, link) => node != 5
          ? link
          : _TapTransport(link, (frame) {
              final p = Packet.decode(frame);
              if (!armed || p.type != PacketType.noiseTransport) return;
              if (p.fragIdx != p.fragTotal - 1) return;
              armed = false;
              reply = mesh.send(5, 0, fromFive);
            }),
    );
    await mesh.send(0, 5, _message(300, 2));
    await mesh.time.run();

    armed = true;
    final zeroId = await mesh.send(0, 5, fromZero);
    await mesh.time.run();
    final fiveId = await reply!;

    expect(mesh.inbox[5].map((m) => m.plaintext).last, fromZero);
    expect(mesh.inbox[0].single.plaintext, fromFive);
    expect(mesh.receipts[0], hasLength(2));
    expect(mesh.receipts[0].last.receipt.packetId, zeroId);
    expect(mesh.receipts[5].single.receipt.packetId, fiveId);
  });

  test('a branching topology delivers across redundant paths, suppresses '
      'duplicate relays, and floods without loops', () async {
    final mesh = await _Mesh.build(10, _branching);
    final message = _message(1500, 5);

    final packetId = await mesh.send(0, 5, message);
    await mesh.time.run();

    expect(mesh.inbox[5], hasLength(1));
    expect(mesh.inbox[5].single.plaintext, message);
    expect(mesh.receipts[0].single.receipt.packetId, packetId);
    final suppressed = mesh.nodes.fold<int>(
      0,
      (sum, node) => sum + node.relaysSuppressed,
    );
    expect(suppressed, greaterThan(0));

    // Each node sends a given fragment at most once per link, so no fragment
    // can cross the air more than 2 x edges times.
    final perFragment = <String, int>{};
    for (final frame in mesh.topology.network.frames) {
      final p = Packet.decode(frame);
      final key = '${p.senderId.hex}:${p.packetId}:${p.fragIdx}';
      perFragment[key] = (perFragment[key] ?? 0) + 1;
    }
    for (final MapEntry(:key, :value) in perFragment.entries) {
      expect(value, lessThanOrEqualTo(2 * _branching.length), reason: key);
    }
  });

  test(
    'the full stack works with every frame sealed under a unit key',
    () async {
      final envelope = SealedEnvelope(List.generate(sealKeyLength, (i) => i));
      final mesh = await _Mesh.build(
        10,
        _branching,
        wrap: (_, link) => _SealedTransport(link, envelope),
      );
      final message = _message(1000, 6);

      final packetId = await mesh.send(0, 5, message);
      await mesh.time.run();

      expect(mesh.inbox[5].single.plaintext, message);
      expect(mesh.receipts[0].single.receipt.packetId, packetId);
      expect(mesh.topology.network.frames, isNotEmpty);
      for (final frame in mesh.topology.network.frames) {
        final packet = Packet.decode(await envelope.open(frame));
        expect(frame.length, packet.encode().length + sealOverhead);
      }
    },
  );

  test('a lost receipt does not stop the next reply from decrypting', () async {
    var dropped = false;
    final mesh = await _Mesh.build(
      2,
      _pair,
      wrap: (node, link) => node != 0
          ? link
          : _EditTransport(link, (frame) {
              if (dropped || Packet.decode(frame).type != PacketType.ack) {
                return frame;
              }
              dropped = true;
              return null;
            }),
    );
    await mesh.send(0, 1, _message(40, 8));
    await mesh.time.run();
    expect(dropped, isTrue, reason: 'node 1 never sent a receipt');
    expect(mesh.inbox[1], hasLength(1));

    final reply = _message(40, 9);
    await mesh.send(1, 0, reply);
    await mesh.time.run();
    expect(mesh.inbox[0].single.plaintext, reply);
  });

  test(
    'a rewritten packetId fails authentication and changes no state',
    () async {
      var rewritten = false;
      final mesh = await _Mesh.build(
        2,
        _pair,
        wrap: (node, link) => node != 1
            ? link
            : _EditTransport(link, (frame) {
                final packet = Packet.decode(frame);
                if (rewritten || packet.type != PacketType.noiseTransport) {
                  return frame;
                }
                rewritten = true;
                return _withPacket(
                  packet,
                  packetId: (packet.packetId + 1) & 0xFFFFFFFF,
                ).encode();
              }),
      );
      await mesh.send(0, 1, _message(40, 1));
      await mesh.time.run();
      expect(rewritten, isTrue);
      expect(mesh.inbox[1], isEmpty);
      expect(mesh.receipts[0], isEmpty);

      await mesh.send(0, 1, _message(40, 2));
      await mesh.time.run();
      expect(mesh.inbox[1].single.plaintext, _message(40, 2));
    },
  );

  test(
    'a message whose type is flipped to ack is not read as a receipt',
    () async {
      var flipped = false;
      final mesh = await _Mesh.build(
        2,
        _pair,
        wrap: (node, link) => node != 1
            ? link
            : _EditTransport(link, (frame) {
                final packet = Packet.decode(frame);
                if (flipped || packet.type != PacketType.noiseTransport) {
                  return frame;
                }
                flipped = true;
                return _withPacket(packet, type: PacketType.ack).encode();
              }),
      );
      // A 12-byte message: its plaintext is exactly the size of a receipt.
      await mesh.send(0, 1, _message(12, 3));
      await mesh.time.run();
      expect(flipped, isTrue);
      expect(mesh.receipts[1], isEmpty);
      expect(mesh.inbox[1], isEmpty);

      await mesh.send(0, 1, _message(40, 4));
      await mesh.time.run();
      expect(mesh.inbox[1].single.plaintext, _message(40, 4));
    },
  );

  test(
    'a forged receipt injected on the link leaves the session usable',
    () async {
      final mesh = await _Mesh.build(2, _pair);
      await mesh.send(0, 1, _message(40, 5));
      await mesh.time.run();

      // Node 0's link delivers this junk frame to node 1, claiming to come from node 0.
      final junk = Packet(
        type: PacketType.ack,
        ttl: maxTtl,
        packetId: 77,
        senderId: mesh.nodes[0].peerId,
        recipientId: mesh.nodes[1].peerId,
        fragIdx: 0,
        fragTotal: 1,
        payload: Uint8List(36),
      );
      await mesh.topology.transportsOf(0).single.send(junk.encode());
      await mesh.time.run();

      await mesh.send(0, 1, _message(40, 6));
      await mesh.time.run();
      expect(mesh.inbox[1], hasLength(2));
      expect(mesh.inbox[1].last.plaintext, _message(40, 6));
    },
  );
}
