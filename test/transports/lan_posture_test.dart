import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/crypto/identity.dart';
import 'package:offmesh/core/posture.dart';

import 'lan_test_support.dart';

/// A port of its own, so this file's beacons never meet another test file's beacons.
late int _quietTestBeaconPort;

/// Two devices that find each other only by beacon. Quiet on one side must stop the
/// beacons and the beacon-triggered dials, and Normal must bring the link back.
void main() {
  setUpAll(() async {
    _quietTestBeaconPort = await freeUdpPort();
  });
  test(
    'a Quiet phone sends no beacon and dials none, and links once it is Normal',
    () async {
      final aId = await Identity.generate();
      final bId = await Identity.generate();
      final secret = testSecret(9);
      final a = await unitDevice(
        aId,
        unitSecret: secret,
        roster: [aId, bId],
        beaconPort: _quietTestBeaconPort,
      );
      final b = await unitDevice(
        bId,
        unitSecret: secret,
        roster: [aId, bId],
        beaconPort: _quietTestBeaconPort,
      );
      b.lan.posture.change(Posture.quiet);
      await a.lan.start();
      await b.lan.start();

      // Roughly ten beacon intervals: any beacon or dial would have linked by now.
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(a.lan.linkCount, 0);
      expect(b.lan.linkCount, 0);

      b.lan.posture.change(Posture.normal);
      await waitFor(
        () => a.lan.linkCount == 1 && b.lan.linkCount == 1,
        timeout: const Duration(seconds: 20),
      );
    },
    timeout: const Timeout(Duration(seconds: 40)),
  );
}
