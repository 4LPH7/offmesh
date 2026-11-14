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

/// Fails its first send, as a link that dropped just after it was heard from would.
class _FlakyTransport extends _FakeTransport {
  bool _failNext = true;

  @override
  Future<void> send(Uint8List frame) async {
    if (_failNext) {
      _failNext = false;
      throw StateError('link dropped');
    }
    sent.add(frame);
  }
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

  group('managed flood suppression', () {
    late Completer<void> gate;
    late _FakeTransport a;
    late _FakeTransport b;
    late _FakeTransport c;
    late MeshRouter gated;

    MeshRouter build(List<MeshTransport> links) => MeshRouter(
      localId: _me,
      transports: links,
      onDeliver: (_) {},
      random: Random(1),
      delay: (_) => gate.future,
    )..start();

    setUp(() {
      gate = Completer<void>();
      a = _FakeTransport();
      b = _FakeTransport();
      c = _FakeTransport();
    });

    tearDown(() => gated.stop());

    test(
      'on a 2-link node, hearing the relay from the other link cancels it',
      () async {
        gated = build([a, b]);
        final frame = _frame(recipient: Packet.broadcastId, ttl: 5);
        a.receive(frame);
        await _settle();
        b.receive(frame);
        await _settle();
        gate.complete();
        await _settle();

        expect(a.sent, isEmpty);
        expect(b.sent, isEmpty);
        expect(gated.relaysSent, 0);
        expect(gated.relaysSuppressed, 1);
      },
    );

    test(
      'a third neighbour that has not sent the packet still receives it',
      () async {
        gated = build([a, b, c]);
        final frame = _frame(recipient: _other, ttl: 5);
        a.receive(frame);
        await _settle();
        b.receive(frame);
        await _settle();
        gate.complete();
        await _settle();

        expect(a.sent, isEmpty);
        expect(b.sent, isEmpty);
        expect(c.sent, hasLength(1));
        expect(Packet.decode(c.sent.single).ttl, 4);
        expect(gated.relaysSent, 1);
        expect(gated.relaysSuppressed, 1);
      },
    );

    test('a duplicate after the relay fired is only dropped', () async {
      gated = build([a, b, c]);
      final frame = _frame(recipient: Packet.broadcastId, ttl: 5);
      a.receive(frame);
      await _settle();
      gate.complete();
      await _settle();
      b.receive(frame);
      await _settle();

      expect(b.sent, hasLength(1));
      expect(c.sent, hasLength(1));
      expect(gated.relaysSent, 2);
      expect(gated.relaysSuppressed, 0);
    });
  });

  group('reverse-path table', () {
    late _FakeTransport a;
    late _FakeTransport b;
    late DateTime now;
    late MeshRouter timed;

    setUp(() {
      now = DateTime.utc(2026);
      a = _FakeTransport();
      b = _FakeTransport();
      timed = MeshRouter(
        localId: _me,
        transports: [a, b],
        onDeliver: (_) {},
        random: Random(1),
        delay: (_) async {},
        clock: () => now,
      )..start();
    });

    tearDown(() => timed.stop());

    test('returns the link the sender was heard on', () async {
      a.receive(_frame(sender: _stranger));
      await _settle();

      expect(timed.nextHopFor(_stranger), same(a));
      expect(timed.nextHopFor(_other), isNull);
    });

    test('keeps the closer link and takes a closer or equal one', () async {
      a.receive(_frame(sender: _stranger, ttl: 5, packetId: 1));
      await _settle();
      b.receive(_frame(sender: _stranger, ttl: 3, packetId: 2));
      await _settle();
      expect(timed.nextHopFor(_stranger), same(a));

      b.receive(_frame(sender: _stranger, ttl: 5, packetId: 3));
      await _settle();
      expect(timed.nextHopFor(_stranger), same(b));
    });

    test('an entry expires after routeMaxAge', () async {
      a.receive(_frame(sender: _stranger));
      await _settle();
      now = now.add(routeMaxAge);
      expect(timed.nextHopFor(_stranger), same(a));

      now = now.add(const Duration(seconds: 1));
      expect(timed.nextHopFor(_stranger), isNull);
    });

    test('evicts the least recently heard sender past maxRoutes', () async {
      for (var i = 0; i <= maxRoutes; i++) {
        final id = Uint8List(8)..buffer.asByteData().setUint32(4, i + 1);
        a.receive(_frame(sender: id));
      }
      await _settle();

      final first = Uint8List(8)..buffer.asByteData().setUint32(4, 1);
      final last = Uint8List(8)
        ..buffer.asByteData().setUint32(4, maxRoutes + 1);
      expect(timed.nextHopFor(first), isNull);
      expect(timed.nextHopFor(last), same(a));
    });

    test('removing a link drops its routes', () async {
      a.receive(_frame(sender: _stranger));
      await _settle();
      await timed.removeTransport(a);

      expect(timed.nextHopFor(_stranger), isNull);
    });

    test(
      'a closer link that has gone quiet loses to a farther link that is heard',
      () async {
        a.receive(_frame(sender: _stranger, ttl: 7, packetId: 1));
        await _settle();
        now = now.add(closerRouteGrace + const Duration(seconds: 1));
        b.receive(_frame(sender: _stranger, ttl: 5, packetId: 2));
        await _settle();

        expect(timed.nextHopFor(_stranger), same(b));
      },
    );

    test(
      'a reverse-path send that fails drops that route and floods instead',
      () async {
        final link = _FakeTransport();
        final flaky = _FlakyTransport();
        final router = MeshRouter(
          localId: _me,
          transports: [link, flaky],
          onDeliver: (_) {},
          random: Random(1),
          delay: (_) async {},
          clock: () => now,
        )..start();
        flaky.receive(_frame(sender: _stranger));
        await _settle();

        await router.originateTo(
          Packet.decode(_frame(recipient: _stranger, sender: _me, packetId: 9)),
        );

        expect(router.nextHopFor(_stranger), isNull);
        expect(link.sent.map(Packet.decode).map((p) => p.packetId), [9]);
        await router.stop();
      },
    );

    test('originateTo uses the known next hop only', () async {
      a.receive(_frame(sender: _stranger));
      await _settle();
      await timed.originateTo(
        Packet.decode(_frame(sender: _me, recipient: _stranger, packetId: 9)),
      );

      expect(a.sent, hasLength(1));
      expect(b.sent, isEmpty);
    });

    test('originateTo floods when no route is known', () async {
      await timed.originateTo(
        Packet.decode(_frame(sender: _me, recipient: _other, packetId: 9)),
      );

      expect(a.sent, hasLength(1));
      expect(b.sent, hasLength(1));
    });
  });
}
