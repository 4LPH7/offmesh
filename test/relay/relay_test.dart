import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/crypto/identity.dart';
import 'package:offmesh/core/crypto/unit_keys.dart';
import 'package:offmesh/core/mesh/mesh_node.dart';
import 'package:offmesh/core/protocol/sealed_envelope.dart';
import 'package:offmesh/core/relay/rendezvous.dart';
import 'package:offmesh/relay/relay_server.dart';
import 'package:offmesh/transports/lan_frame.dart';
import 'package:offmesh/transports/relay_transport.dart';

/// A bare client: joins a room by ID and records the frames it receives.
class _RawClient {
  _RawClient._(this.socket);

  final Socket socket;
  final List<Uint8List> received = [];
  final FrameDecoder _decoder = FrameDecoder();
  bool closed = false;

  static Future<_RawClient> join(
    int port,
    List<int> room, {
    bool wait = true,
  }) async {
    final socket = await Socket.connect('127.0.0.1', port);
    final client = _RawClient._(socket);
    socket.listen(
      (chunk) => client.received.addAll(client._decoder.add(chunk)),
      onDone: () => client.closed = true,
      onError: (Object _) => client.closed = true,
    );
    socket.add(encodeFrame(Uint8List.fromList([...relayMagic, ...room])));
    if (wait) await Future<void>.delayed(const Duration(milliseconds: 80));
    return client;
  }

  void send(List<int> frame) =>
      socket.add(encodeFrame(Uint8List.fromList(frame)));
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 150));

Uint8List _room(int n) => Uint8List.fromList(List.filled(rendezvousLength, n));

void main() {
  late RelayServer server;
  late int port;

  setUp(() async {
    server = RelayServer(address: InternetAddress.loopbackIPv4);
    port = await server.start();
    addTearDown(() => server.stop());
  });

  group('rendezvous id', () {
    final secret = List<int>.generate(32, (i) => i);

    test(
      'is 16 bytes, stable for a day, and changes with day and unit',
      () async {
        final today = await rendezvousId(secret, 20000);
        expect(today, hasLength(rendezvousIdLength));
        expect(await rendezvousId(secret, 20000), today);
        expect(await rendezvousId(secret, 20001), isNot(today));
        expect(
          await rendezvousId(List<int>.generate(32, (i) => i + 1), 20000),
          isNot(today),
        );
      },
    );

    test('day numbers follow UTC midnight', () {
      expect(epochDay(DateTime.utc(1970, 1, 2)), 1);
      expect(
        epochDay(DateTime.utc(2026, 11, 16, 23, 59, 59)),
        isNot(epochDay(DateTime.utc(2026, 11, 17))),
      );
    });

    test('short secrets are refused', () {
      expect(rendezvousId(List.filled(31, 1), 1), throwsArgumentError);
    });
  });

  group('server', () {
    test(
      'forwards to the other members of a room, not to the sender or other rooms',
      () async {
        final a = await _RawClient.join(port, _room(1));
        final b = await _RawClient.join(port, _room(1));
        final c = await _RawClient.join(port, _room(2));

        a.send([1, 2, 3]);
        await _settle();

        expect(b.received, [
          Uint8List.fromList([1, 2, 3]),
        ]);
        expect(a.received, isEmpty);
        expect(c.received, isEmpty);
        expect(server.roomCount, 2);
        expect(server.framesForwarded, 1);
      },
    );

    test('a bad first frame closes the connection', () async {
      for (final first in [
        <int>[1, 2, 3],
        [...List.filled(5, 0), ...List.filled(rendezvousLength, 0)],
      ]) {
        final socket = await Socket.connect('127.0.0.1', port);
        final done = Completer<void>();
        socket.listen(
          (_) {},
          onDone: done.complete,
          onError: (Object _) => done.complete(),
        );
        socket.add(encodeFrame(Uint8List.fromList(first)));
        await done.future.timeout(const Duration(seconds: 2));
      }
      expect(server.connectionCount, 0);
    });

    test('an oversized frame closes the sender', () async {
      final a = await _RawClient.join(port, _room(1));
      a.socket.add([0x04, 0x00]); // length 1024, above the 512 limit
      await _settle();
      expect(a.closed, isTrue);
      expect(server.connectionCount, 0);
    });

    test('a room holds at most $maxRelayRoomMembers members', () async {
      final members = <_RawClient>[];
      for (var i = 0; i < maxRelayRoomMembers; i++) {
        members.add(await _RawClient.join(port, _room(9), wait: false));
      }
      await _settle();
      final extra = await _RawClient.join(port, _room(9));
      await _settle();

      expect(extra.closed, isTrue);
      expect(server.connectionsRefused, 1);
      expect(server.connectionCount, maxRelayRoomMembers);
    });

    test('keepalive frames are not forwarded', () async {
      await _RawClient.join(port, _room(3));
      final b = await _RawClient.join(port, _room(3));
      final a = await _RawClient.join(port, _room(3));
      a.send(const []);
      await _settle();
      expect(b.received, isEmpty);
    });

    test('a flood past the rate limit is dropped, not forwarded', () async {
      // A frozen clock: the token bucket cannot refill, so the cut-off is exact however
      // slow the machine is.
      final frozen = DateTime.utc(2026);
      final limited = RelayServer(
        address: InternetAddress.loopbackIPv4,
        clock: () => frozen,
      );
      final limitedPort = await limited.start();
      addTearDown(limited.stop);
      final a = await _RawClient.join(limitedPort, _room(4));
      final b = await _RawClient.join(limitedPort, _room(4));
      for (var i = 0; i < relayFramesPerSecond + 50; i++) {
        a.send([i & 0xFF]);
      }
      await _settle();
      await _settle();
      expect(limited.framesForwarded, relayFramesPerSecond);
      expect(limited.framesDropped, 50);
      expect(b.received, hasLength(relayFramesPerSecond));
    });

    test('leaving frees the room', () async {
      final a = await _RawClient.join(port, _room(5));
      expect(server.roomCount, 1);
      a.socket.destroy();
      await _settle();
      expect(server.roomCount, 0);
      expect(server.connectionCount, 0);
    });
  });

  group('transport', () {
    final secret = List<int>.generate(32, (i) => 100 + i);

    Future<RelayTransport> transport(
      List<int> unitSecret, {
      List<int>? sealSecret,
    }) async {
      final keys = await UnitKeys.derive(sealSecret ?? unitSecret);
      final t = RelayTransport(
        host: '127.0.0.1',
        port: port,
        envelope: SealedEnvelope(keys.sealKey),
        unitSecret: unitSecret,
        minBackoff: const Duration(milliseconds: 50),
        maxBackoff: const Duration(milliseconds: 200),
      );
      addTearDown(t.stop);
      return t;
    }

    Future<void> connected(RelayTransport t) async {
      for (var i = 0; i < 100 && t.state != RelayState.connected; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(t.state, RelayState.connected);
    }

    test(
      'two members chat end to end through the relay, which sees only ciphertext',
      () async {
        final a = await transport(secret)
          ..start();
        final b = await transport(secret)
          ..start();
        await connected(a);
        await connected(b);
        final spy = await _RawClient.join(
          port,
          await rendezvousId(secret, epochDay(DateTime.now())),
        );

        final nodeA = MeshNode(
          identity: await Identity.generate(),
          transports: [a],
          random: Random(1),
        )..start();
        final nodeB = MeshNode(
          identity: await Identity.generate(),
          transports: [b],
          random: Random(2),
        )..start();
        addTearDown(nodeA.stop);
        addTearDown(nodeB.stop);
        final inbox = <ReceivedMessage>[];
        nodeB.messages.listen(inbox.add);

        await nodeA.sendText(
          nodeB.peerId,
          Uint8List.fromList(utf8.encode('over the internet')),
        );
        for (var i = 0; i < 300 && inbox.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }

        expect(inbox, hasLength(1));
        expect(utf8.decode(inbox.single.plaintext), 'over the internet');
        expect(spy.received, isNotEmpty);
        for (final frame in spy.received) {
          expect(
            latin1.decode(frame, allowInvalid: true),
            isNot(contains('over the internet')),
          );
        }
      },
    );

    test(
      'frames sealed under another unit key are dropped and counted',
      () async {
        final a = await transport(secret)
          ..start();
        // Same room (same secret for the rendezvous), different seal key.
        final intruder =
            await transport(secret, sealSecret: List<int>.filled(32, 7))
              ..start();
        await connected(a);
        await connected(intruder);
        final heard = <Uint8List>[];
        a.incoming.listen(heard.add);

        await intruder.send(Uint8List.fromList([1, 2, 3]));
        await _settle();

        expect(heard, isEmpty);
        expect(a.framesDropped, 1);
      },
    );

    test('reconnects after the relay restarts and keeps delivering', () async {
      final a = await transport(secret)
        ..start();
      final b = await transport(secret)
        ..start();
      await connected(a);
      await connected(b);
      final heard = <Uint8List>[];
      b.incoming.listen(heard.add);

      await server.stop();
      await _settle();
      server = RelayServer(address: InternetAddress.loopbackIPv4, port: port);
      await server.start();
      await connected(a);
      await connected(b);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await a.send(Uint8List.fromList([9, 9]));
      await _settle();

      expect(heard, [
        Uint8List.fromList([9, 9]),
      ]);
    });

    test(
      'a transport that cannot reach the relay keeps retrying and sends nothing',
      () async {
        final keys = await UnitKeys.derive(secret);
        final t = RelayTransport(
          host: '127.0.0.1',
          port: 1,
          envelope: SealedEnvelope(keys.sealKey),
          unitSecret: secret,
          minBackoff: const Duration(milliseconds: 30),
          maxBackoff: const Duration(milliseconds: 60),
        )..start();
        addTearDown(t.stop);
        await _settle();
        await t.send(Uint8List.fromList([1]));
        expect(t.state, anyOf(RelayState.retrying, RelayState.connecting));
        await t.stop();
        expect(t.state, RelayState.stopped);
      },
    );
  });
}
