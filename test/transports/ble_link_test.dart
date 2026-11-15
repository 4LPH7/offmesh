import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/crypto/identity.dart';
import 'package:offmesh/core/crypto/rotating_id.dart';
import 'package:offmesh/core/crypto/unit_keys.dart';
import 'package:offmesh/core/ble/ble_segmenter.dart';
import 'package:offmesh/core/protocol/sealed_envelope.dart';
import 'package:offmesh/transports/ble_link.dart';
import 'package:offmesh/transports/sealed_link.dart';

import 'ble_fake_radio.dart';
import 'lan_test_support.dart';

void main() {
  late UnitKeys keys;
  late Identity alice;
  late Identity bob;
  late RosterResolver roster;

  setUp(() async {
    keys = await UnitKeys.derive(testSecret(7));
    alice = await Identity.generate();
    bob = await Identity.generate();
    roster = await RosterResolver.create(keys.idKey, [
      alice.publicKey,
      bob.publicKey,
    ]);
  });

  Future<BleLink> attach(
    FakeBleChannel channel,
    Identity self, {
    void Function()? onDrop,
    SealedEnvelope? envelope,
  }) async {
    return BleLink.attach(
      channel,
      envelope: envelope ?? SealedEnvelope(keys.sealKey),
      resolver: roster,
      localRotatingId: await rotatingId(
        keys.idKey,
        self.publicKey,
        epochAt(DateTime.now()),
      ),
      onDrop: onDrop,
    );
  }

  Future<(BleLink, BleLink)> connectedPair({int mtu = 23}) async {
    final (clientEnd, serverEnd) = FakeBleChannel.pair(mtu: mtu);
    final a = await attach(clientEnd, alice);
    final b = await attach(serverEnd, bob);
    await a.remotePeerId;
    await b.remotePeerId;
    return (a, b);
  }

  for (final mtu in [23, 517]) {
    test(
      'a 220-byte packet crosses at MTU $mtu and opens on the far side',
      () async {
        final (a, b) = await connectedPair(mtu: mtu);
        final payload = randomBytes(220);

        final received = b.incoming.first;
        await a.send(payload);

        expect(await received, payload);
        expect(await a.remotePeerId, bob.peerId);
        expect(await b.remotePeerId, alice.peerId);
      },
    );
  }

  test('each side learns the other PeerID through the roster', () async {
    final (a, b) = await connectedPair();
    expect(await a.remotePeerId, bob.peerId);
    expect(await b.remotePeerId, alice.peerId);
  });

  test(
    'a packet over one sealed frame is rejected without closing the link',
    () async {
      final (a, _) = await connectedPair();

      await expectLater(
        a.send(randomBytes(maxBleFrameLength)),
        throwsArgumentError,
      );
      expect(a.isClosed, isFalse);
    },
  );

  test(
    'a malformed chunk is counted as a drop and the link keeps working',
    () async {
      var drops = 0;
      final (clientEnd, serverEnd) = FakeBleChannel.pair();
      final a = await attach(clientEnd, alice);
      final b = await attach(serverEnd, bob, onDrop: () => drops++);
      await a.remotePeerId;
      await b.remotePeerId;

      clientEnd.sendRaw(Uint8List.fromList([1, 2]));
      clientEnd.sendRaw(Uint8List.fromList([5, 2, 0, 0, 9]));
      await Future<void>.delayed(Duration.zero);
      expect(drops, 2);

      final received = b.incoming.first;
      await a.send(randomBytes(40));
      expect((await received).length, 40);
    },
  );

  test(
    'a frame sealed under another unit key is dropped and the link closes',
    () async {
      final otherKeys = await UnitKeys.derive(testSecret(8));
      final (clientEnd, serverEnd) = FakeBleChannel.pair();
      final a = await attach(clientEnd, alice);
      final b = await attach(
        serverEnd,
        bob,
        envelope: SealedEnvelope(otherKeys.sealKey),
      );

      // Attach both listeners before awaiting: the far side fails first and would otherwise be unhandled.
      final aFailed = expectLater(
        a.remotePeerId,
        throwsA(isA<LinkClosedException>()),
      );
      final bFailed = expectLater(
        b.remotePeerId,
        throwsA(isA<LinkClosedException>()),
      );
      await aFailed;
      await bFailed;
      expect(a.isClosed, isTrue);
    },
  );

  test('closing one end closes the peer when its channel goes away', () async {
    final (a, b) = await connectedPair();
    await a.close();
    await expectLater(b.closed, completes);
    expect(b.isClosed, isTrue);
  });
}
