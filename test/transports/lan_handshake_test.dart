import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/crypto/identity.dart';
import 'package:offmesh/core/crypto/rotating_id.dart';
import 'package:offmesh/core/crypto/unit_keys.dart';
import 'package:offmesh/core/protocol/sealed_envelope.dart';
import 'package:offmesh/transports/lan_frame.dart';
import 'package:offmesh/transports/lan_link.dart';

import 'lan_test_support.dart';

/// Test-only beacon port, apart from the ports other test files use.
const int _beaconPort = 47995;

/// Well under the 5 s hello timeout, so a pass proves the socket was closed on reject.
const Duration _rejectWithin = Duration(seconds: 1);

/// A loopback server that counts accepted sockets. A stalling one holds them open
/// silently; otherwise it closes each at once.
Future<List<Socket>> _countingServer(
  void Function(int port) onPort, {
  required bool stall,
}) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(server.close);
  final accepted = <Socket>[];
  server.listen((socket) {
    accepted.add(socket);
    addTearDown(socket.destroy);
    if (!stall) socket.destroy();
  });
  onPort(server.port);
  return accepted;
}

void main() {
  final secret = testSecret(5);
  late UnitKeys keys;
  late Identity aliceId;
  late Identity bobId;
  late List<Identity> roster;

  setUp(() async {
    keys = await UnitKeys.derive(secret);
    aliceId = await Identity.generate();
    bobId = await Identity.generate();
    roster = [aliceId, bobId];
  });

  Future<Uint8List> idOf(Identity identity) =>
      rotatingId(keys.idKey, identity.publicKey, epochAt(DateTime.now()));

  Future<TestDevice> listeningBob({
    Duration linkIdleTimeout = defaultLinkIdleTimeout,
  }) => unitDevice(
    bobId,
    unitSecret: secret,
    roster: roster,
    linkIdleTimeout: linkIdleTimeout,
  );

  group('a handshake that does not bind closes the socket at once', () {
    Future<void> expectRejected(
      Future<void> Function(RawPeer peer) script, {
      List<int>? sealKey,
    }) async {
      final bob = await listeningBob();
      final peer = await RawPeer.connect(
        await bob.lan.start(),
        sealKey ?? keys.sealKey,
      );
      await script(peer);
      await peer.done.timeout(_rejectWithin);
      expect(bob.lan.linkCount, 0);
    }

    test('a frame sealed under a different unit key', () async {
      final other = await UnitKeys.derive(testSecret(9));
      await expectRejected(
        (peer) => peer.sendSealed(randomBytes(linkNonceLength)),
        sealKey: other.sealKey,
      );
    });

    test('an unsealed frame', () async {
      await expectRejected(
        (peer) async => peer.socket.add(encodeFrame(Uint8List(60))),
      );
    });

    test('a challenge of the wrong length', () async {
      await expectRejected(
        (peer) async => peer.sendSealed(await idOf(aliceId)),
      );
    });

    test('a hello of the wrong length (bare rotating ID)', () async {
      await expectRejected((peer) async {
        await peer.sendSealed(randomBytes(linkNonceLength));
        await peer.nextOpened();
        await peer.sendSealed(await idOf(aliceId));
      });
    });

    test('a hello for a rotating ID outside the roster', () async {
      final dave = await Identity.generate();
      await expectRejected((peer) async => peer.handshake(await idOf(dave)));
    });

    test('a hello that echoes the wrong challenge', () async {
      await expectRejected((peer) async {
        await peer.sendSealed(randomBytes(linkNonceLength));
        await peer.nextOpened();
        await peer.sendSealed(
          helloBytes(
            await idOf(aliceId),
            randomBytes(linkNonceLength),
            roleDialer,
          ),
        );
      });
    });

    test('a hello that claims the same role as the receiver', () async {
      await expectRejected((peer) async {
        await peer.sendSealed(randomBytes(linkNonceLength));
        final bobNonce = await peer.nextOpened();
        await peer.sendSealed(
          helloBytes(await idOf(aliceId), bobNonce, roleAcceptor),
        );
      });
    });
  });

  test(
    'an outsider relaying between two listening members links neither',
    () async {
      final alice = await unitDevice(
        aliceId,
        unitSecret: secret,
        roster: roster,
      );
      final bob = await listeningBob();
      final toAlice = await Socket.connect(
        '127.0.0.1',
        await alice.lan.start(),
      );
      final toBob = await Socket.connect('127.0.0.1', await bob.lan.start());
      addTearDown(toAlice.destroy);
      addTearDown(toBob.destroy);

      // No unit key: forward every byte both ways and hope the hellos pass.
      Future<void> pipe(Socket from, Socket to) {
        final done = Completer<void>();
        from.listen(
          (data) {
            try {
              to.add(data);
            } catch (_) {
              // The other side already closed.
            }
          },
          onDone: done.complete,
          onError: (Object _) => done.complete(),
        );
        return done.future;
      }

      await Future.wait([
        pipe(toAlice, toBob),
        pipe(toBob, toAlice),
      ]).timeout(_rejectWithin);

      expect(alice.lan.linkCount, 0);
      expect(bob.lan.linkCount, 0);
    },
  );

  test('a link that goes silent after its hello is closed', () async {
    final bob = await listeningBob(
      linkIdleTimeout: const Duration(milliseconds: 600),
    );
    final squatter = await RawPeer.connect(await bob.lan.start(), keys.sealKey);
    // A unit-key holder squats Alice's slot, then never sends another frame.
    await squatter.handshake(await idOf(aliceId));
    await waitFor(() => bob.lan.linkCount == 1);

    await squatter.done.timeout(const Duration(seconds: 2));
    expect(bob.lan.linkCount, 0);
  });

  test('a quiet but healthy link stays up past the idle timeout', () async {
    const idle = Duration(milliseconds: 600);
    final alice = await unitDevice(
      aliceId,
      unitSecret: secret,
      roster: roster,
      linkIdleTimeout: idle,
    );
    final bob = await listeningBob(linkIdleTimeout: idle);
    await alice.lan
        .connect('127.0.0.1', await bob.lan.start())
        .catchError((_) {});
    await waitFor(() => bob.lan.linkCount == 1);

    await Future<void>.delayed(idle * 3);
    expect(alice.lan.linkCount, 1);
    expect(bob.lan.linkCount, 1);
  });

  test('the real member replaces a link squatting its PeerID', () async {
    final alice = await unitDevice(aliceId, unitSecret: secret, roster: roster);
    final bob = await listeningBob();
    final port = await bob.lan.start();
    final squatter = await RawPeer.connect(port, keys.sealKey);
    await squatter.handshake(await idOf(aliceId));
    await waitFor(() => bob.lan.linkCount == 1);

    await alice.lan.connect('127.0.0.1', port).catchError((_) {});
    await squatter.done.timeout(_rejectWithin);
    await waitFor(() => alice.lan.linkCount == 1);
    await alice.node.sendText(
      bob.node.peerId,
      Uint8List.fromList(utf8.encode('slot back')),
    );
    await waitFor(() => bob.inbox.isNotEmpty);

    expect(utf8.decode(bob.inbox.single.plaintext), 'slot back');
    expect(bob.lan.linkCount, 1);
  });

  test(
    'two members dialing each other at once keep the same one link',
    () async {
      final alice = await unitDevice(
        aliceId,
        unitSecret: secret,
        roster: roster,
      );
      final bob = await listeningBob();
      final alicePort = await alice.lan.start();
      final bobPort = await bob.lan.start();

      await Future.wait([
        alice.lan.connect('127.0.0.1', bobPort).catchError((_) {}),
        bob.lan.connect('127.0.0.1', alicePort).catchError((_) {}),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(alice.lan.linkCount, 1);
      expect(bob.lan.linkCount, 1);
      await alice.node.sendText(
        bob.node.peerId,
        Uint8List.fromList(utf8.encode('one link')),
      );
      await waitFor(() => bob.inbox.isNotEmpty);
    },
  );

  test('stop closes a link still in its handshake', () async {
    final bob = await listeningBob();
    final peer = await RawPeer.connect(await bob.lan.start(), keys.sealKey);
    final bobNonce = await peer.nextOpened();

    await bob.lan.stop();
    // The hello would bind, but it arrives after stop.
    await peer.sendSealed(randomBytes(linkNonceLength));
    await peer.sendSealed(
      helloBytes(await idOf(aliceId), bobNonce, roleDialer),
    );

    await peer.done.timeout(_rejectWithin);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(bob.lan.linkCount, 0);
  });

  group('beacon dials', () {
    late RawDatagramSocket sender;

    setUp(() async {
      sender = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(sender.close);
    });

    Future<Uint8List> beacon(int port) async {
      final plaintext = Uint8List(rotatingIdLength + 2)
        ..setRange(0, rotatingIdLength, await idOf(aliceId));
      ByteData.sublistView(plaintext).setUint16(rotatingIdLength, port);
      return SealedEnvelope(keys.sealKey).seal(plaintext);
    }

    void send(List<int> datagram) =>
        sender.send(datagram, InternetAddress.loopbackIPv4, _beaconPort);

    Future<TestDevice> beaconBob() async {
      final bob = await unitDevice(
        bobId,
        unitSecret: secret,
        roster: roster,
        beaconPort: _beaconPort,
        // Short, because Bob defers beacon dials by two intervals when Alice's PeerID
        // is the lower one.
        beaconInterval: const Duration(milliseconds: 100),
        dialBackoff: Duration.zero,
      );
      await bob.lan.start();
      return bob;
    }

    test(
      'beacons for one member naming different ports cause one dial',
      () async {
        await beaconBob();
        late int first;
        late int second;
        final a = await _countingServer((p) => first = p, stall: true);
        final b = await _countingServer((p) => second = p, stall: true);

        send(await beacon(first));
        send(await beacon(second));
        await Future<void>.delayed(const Duration(milliseconds: 500));

        expect(a.length + b.length, 1);
      },
    );

    test('a replayed beacon is ignored; a fresh one is not', () async {
      await beaconBob();
      late int port;
      final accepted = await _countingServer((p) => port = p, stall: false);
      final recorded = await beacon(port);

      send(recorded);
      await waitFor(() => accepted.length == 1);
      // Let the failed dial finish so nothing but the replay cache can refuse.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      send(recorded);
      // Longer than Bob's two-interval dial deferral, so a wrongly accepted replay lands.
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(accepted, hasLength(1));

      send(await beacon(port));
      await waitFor(() => accepted.length == 2);
    });
  });
}
