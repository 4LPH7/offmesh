import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/crypto/identity.dart';
import 'package:offmesh/core/protocol/packet.dart';
import 'package:offmesh/transports/lan_manager.dart';

import 'lan_test_support.dart';

void main() {
  late Identity aliceId;
  late Identity bobId;
  late List<Identity> roster;
  final secret = testSecret(1);

  setUp(() async {
    aliceId = await Identity.generate();
    bobId = await Identity.generate();
    roster = [aliceId, bobId];
  });

  test(
    'two devices on loopback exchange an encrypted message over a LAN link',
    () async {
      final alice = await unitDevice(
        aliceId,
        unitSecret: secret,
        roster: roster,
      );
      final bob = await unitDevice(bobId, unitSecret: secret, roster: roster);
      final port = await bob.lan.start();

      await alice.lan.connect('127.0.0.1', port);
      await alice.node.sendText(
        bob.node.peerId,
        Uint8List.fromList(utf8.encode('over the LAN')),
      );

      await waitFor(() => bob.inbox.isNotEmpty);
      expect(utf8.decode(bob.inbox.single.plaintext), 'over the LAN');
      expect(bob.inbox.single.senderId, alice.node.peerId);
      expect(alice.lan.linkedPeerIds, {bob.node.peerId.hex});
      expect(bob.lan.linkedPeerIds, {alice.node.peerId.hex});
    },
  );

  test(
    'a second connection to the same peer is closed, leaving one link',
    () async {
      final alice = await unitDevice(
        aliceId,
        unitSecret: secret,
        roster: roster,
      );
      final bob = await unitDevice(bobId, unitSecret: secret, roster: roster);
      final port = await bob.lan.start();

      await alice.lan.connect('127.0.0.1', port);
      await waitFor(() => alice.lan.linkCount == 1 && bob.lan.linkCount == 1);
      await alice.lan.connect('127.0.0.1', port);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(alice.lan.linkCount, 1);
      expect(bob.lan.linkCount, 1);
    },
  );

  test('a device does not link to itself', () async {
    final alice = await unitDevice(aliceId, unitSecret: secret, roster: roster);
    final port = await alice.lan.start();

    await alice.lan.connect('127.0.0.1', port);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(alice.lan.linkCount, 0);
  });

  test('a device with a different unit key cannot link', () async {
    final bob = await unitDevice(bobId, unitSecret: secret, roster: roster);
    final carol = await unitDevice(
      aliceId,
      unitSecret: testSecret(2),
      roster: roster,
    );
    final port = await bob.lan.start();

    await carol.lan.connect('127.0.0.1', port);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(carol.lan.linkCount, 0);
    expect(bob.lan.linkCount, 0);
  });

  test('a device with the unit key but outside the roster cannot link', () async {
    final daveId = await Identity.generate();
    final bob = await unitDevice(bobId, unitSecret: secret, roster: roster);
    // Dave holds the secret and lists Bob, but Bob's roster does not list Dave.
    final dave = await unitDevice(
      daveId,
      unitSecret: secret,
      roster: [daveId, bobId],
    );
    final port = await bob.lan.start();

    await dave.lan.connect('127.0.0.1', port);
    await waitFor(() => dave.lan.linkCount == 0 && bob.lan.linkCount == 0);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(dave.lan.linkCount, 0);
    expect(bob.lan.linkCount, 0);
  });

  test('start and connect refuse until a unit is configured', () async {
    final alice = await unitDevice(aliceId, unitSecret: secret, roster: roster);
    final unconfigured = LanManager(node: alice.node, beaconPort: 0);

    await expectLater(unconfigured.start(), throwsStateError);
    await expectLater(unconfigured.connect('127.0.0.1', 1), throwsStateError);
  });
}
