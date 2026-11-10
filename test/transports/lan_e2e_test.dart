import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/crypto/identity.dart';
import 'package:offmesh/core/mesh/mesh_node.dart';
import 'package:offmesh/transports/lan_manager.dart';

class _Device {
  _Device(this.node, this.lan, this.inbox);

  final MeshNode node;
  final LanManager lan;
  final List<ReceivedMessage> inbox;
}

Future<_Device> _device() async {
  final node = MeshNode(
    identity: await Identity.generate(),
    transports: const [],
    random: Random(),
    delay: (_) async {},
  );
  final lan = LanManager(node: node, beaconPort: 0);
  final inbox = <ReceivedMessage>[];
  node.messages.listen(inbox.add);
  node.start();
  return _Device(node, lan, inbox);
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test('two devices on loopback exchange an encrypted message over a LAN link', () async {
    final alice = await _device();
    final bob = await _device();
    final port = await bob.lan.start();
    addTearDown(() async {
      await alice.lan.stop();
      await bob.lan.stop();
    });

    await alice.lan.connect('127.0.0.1', port);
    await alice.node.sendText(bob.node.peerId, Uint8List.fromList(utf8.encode('over the LAN')));

    await _waitFor(() => bob.inbox.isNotEmpty);
    expect(utf8.decode(bob.inbox.single.plaintext), 'over the LAN');
    expect(bob.inbox.single.senderId, alice.node.peerId);
  });

  test('a second connection to the same peer is closed, leaving one link', () async {
    final alice = await _device();
    final bob = await _device();
    final port = await bob.lan.start();
    addTearDown(() async {
      await alice.lan.stop();
      await bob.lan.stop();
    });

    await alice.lan.connect('127.0.0.1', port);
    await _waitFor(() => alice.lan.linkCount == 1 && bob.lan.linkCount == 1);
    await alice.lan.connect('127.0.0.1', port);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(alice.lan.linkCount, 1);
    expect(bob.lan.linkCount, 1);
  });

  test('a device does not link to itself', () async {
    final alice = await _device();
    final port = await alice.lan.start();
    addTearDown(alice.lan.stop);

    await alice.lan.connect('127.0.0.1', port);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(alice.lan.linkCount, 0);
  });
}
