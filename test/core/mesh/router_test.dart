import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/mesh/router.dart';
import 'package:offmesh/core/mesh/transport.dart';
import 'package:offmesh/core/protocol/packet.dart';

final Uint8List _me = Uint8List.fromList(List.filled(8, 0xAA));
final Uint8List _other = Uint8List.fromList(List.filled(8, 0xBB));
final Uint8List _stranger = Uint8List.fromList(List.filled(8, 0xCC));

class _FakeTransport implements MeshTransport {
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  final List<Uint8List> sent = [];

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> send(Uint8List frame) async {
    sent.add(frame);
  }

  void receive(Uint8List frame) => _incoming.add(frame);
}

Uint8List _frame({
  Uint8List? recipient,
  Uint8List? sender,
  int ttl = 5,
  int packetId = 1,
  PacketType type = PacketType.noiseTransport,
}) {
  return Packet(
    type: type,
    ttl: ttl,
    packetId: packetId,
    senderId: sender ?? _stranger,
    recipientId: recipient ?? _me,
    fragIdx: 0,
    fragTotal: 1,
    payload: Uint8List.fromList([9, 9, 9]),
  ).encode();
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late List<Packet> delivered;
  late _FakeTransport source;
  late _FakeTransport other;
  late MeshRouter router;

  setUp(() {
    delivered = [];
    source = _FakeTransport();
    other = _FakeTransport();
    router = MeshRouter(
      localId: _me,
      transports: [source, other],
      onDeliver: delivered.add,
      random: Random(1),
      delay: (_) async {},
    )..start();
  });

  tearDown(() => router.stop());

  test(
    'delivers a packet addressed to this node and does not relay it',
    () async {
      source.receive(_frame(recipient: _me));
      await _settle();

      expect(delivered, hasLength(1));
      expect(source.sent, isEmpty);
      expect(other.sent, isEmpty);
    },
  );

  test(
    'relays a packet for someone else with TTL decremented, never back to its source',
    () async {
      source.receive(_frame(recipient: _other, ttl: 5));
      await _settle();

      expect(delivered, isEmpty);
      expect(source.sent, isEmpty);
      expect(other.sent, hasLength(1));
      expect(Packet.decode(other.sent.single).ttl, 4);
    },
  );

  test('a packet with TTL 1 is not relayed further', () async {
    source.receive(_frame(recipient: _other, ttl: 1));
    await _settle();

    expect(other.sent, isEmpty);
    expect(delivered, isEmpty);
  });

  test('a broadcast is delivered locally and relayed', () async {
    source.receive(_frame(recipient: Packet.broadcastId, ttl: 3));
    await _settle();

    expect(delivered, hasLength(1));
    expect(other.sent, hasLength(1));
    expect(Packet.decode(other.sent.single).ttl, 2);
  });

  test('a duplicate arriving twice is delivered and relayed once', () async {
    final frame = _frame(recipient: Packet.broadcastId, ttl: 5);
    source.receive(frame);
    source.receive(frame);
    await _settle();

    expect(delivered, hasLength(1));
    expect(other.sent, hasLength(1));
  });

  test(
    'a packet this node originated is not delivered back when it echoes',
    () async {
      final own = Packet.decode(
        _frame(recipient: Packet.broadcastId, sender: _me, ttl: 7),
      );
      await router.originate(own);
      source.receive(other.sent.single);
      await _settle();

      expect(delivered, isEmpty);
      expect(other.sent, hasLength(1));
    },
  );

  test('originate sends on every transport', () async {
    await router.originate(
      Packet.decode(_frame(recipient: _other, sender: _me, ttl: 7)),
    );

    expect(source.sent, hasLength(1));
    expect(other.sent, hasLength(1));
  });

  test('malformed frames are dropped silently', () async {
    source.receive(Uint8List.fromList([1, 2, 3]));
    await _settle();

    expect(delivered, isEmpty);
    expect(other.sent, isEmpty);
  });
}
