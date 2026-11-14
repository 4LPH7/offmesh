import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/crypto/identity.dart';
import 'package:offmesh/transports/lan_manager.dart';

import 'lan_test_support.dart';

/// Two devices on the real network stack with the default beacon port. Neither is given
/// the other's address: they must find each other through the sealed UDP beacon.
void main() {
  test(
    'two devices find each other by beacon and exchange an encrypted message',
    () async {
      final aId = await Identity.generate();
      final bId = await Identity.generate();
      final secret = testSecret(7);
      final a = await unitDevice(
        aId,
        unitSecret: secret,
        roster: [aId, bId],
        beaconPort: defaultBeaconPort,
      );
      final b = await unitDevice(
        bId,
        unitSecret: secret,
        roster: [aId, bId],
        beaconPort: defaultBeaconPort,
      );
      await a.lan.start();
      await b.lan.start();

      await waitFor(
        () => a.lan.linkCount == 1 && b.lan.linkCount == 1,
        timeout: const Duration(seconds: 20),
      );

      await a.node.sendText(
        b.node.peerId,
        Uint8List.fromList(utf8.encode('found by beacon')),
      );
      await waitFor(() => b.inbox.isNotEmpty);
      expect(utf8.decode(b.inbox.single.plaintext), 'found by beacon');
    },
    timeout: const Timeout(Duration(seconds: 40)),
  );
}
