import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/crypto/identity.dart';
import 'package:offmesh/core/mesh/mesh_node.dart';
import 'package:offmesh/transports/lan_manager.dart';

/// Two devices on the real network stack with the default beacon port. Neither is given
/// the other's address: they must find each other through the UDP broadcast beacon.
void main() {
  test(
    'two devices find each other by beacon and exchange an encrypted message',
    () async {
      final aNode = MeshNode(
        identity: await Identity.generate(),
        transports: const [],
        random: Random(1),
        delay: (_) async {},
      );
      final bNode = MeshNode(
        identity: await Identity.generate(),
        transports: const [],
        random: Random(2),
        delay: (_) async {},
      );
      final a = LanManager(
        node: aNode,
        beaconInterval: const Duration(milliseconds: 300),
      );
      final b = LanManager(
        node: bNode,
        beaconInterval: const Duration(milliseconds: 300),
      );
      final bInbox = <ReceivedMessage>[];
      bNode.messages.listen(bInbox.add);
      aNode.start();
      bNode.start();
      await a.start();
      await b.start();
      addTearDown(() async {
        await a.stop();
        await b.stop();
      });

      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (!(a.linkCount == 1 && b.linkCount == 1)) {
        if (DateTime.now().isAfter(deadline)) {
          fail(
            'beacon discovery did not link the two devices (a=${a.linkCount}, b=${b.linkCount})',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      await aNode.sendText(
        bNode.peerId,
        Uint8List.fromList(utf8.encode('found by beacon')),
      );
      while (bInbox.isEmpty) {
        if (DateTime.now().isAfter(deadline)) fail('message did not arrive');
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(utf8.decode(bInbox.single.plaintext), 'found by beacon');
    },
    timeout: const Timeout(Duration(seconds: 40)),
  );
}
