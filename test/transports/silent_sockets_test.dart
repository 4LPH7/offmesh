import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/crypto/identity.dart';
import 'package:offmesh/core/posture.dart';

import 'lan_test_support.dart';

/// Silent must leave no socket behind. These tests check the OS, not the posture flag:
/// a TCP connect to the old port must be refused, and the beacon port must be free to bind.
void main() {
  test('Silent closes the TCP listener and frees the beacon port', () async {
    final identity = await Identity.generate();
    final beaconPort = await freeUdpPort();
    final device = await unitDevice(
      identity,
      unitSecret: testSecret(21),
      roster: [identity],
      beaconPort: beaconPort,
    );
    final tcpPort = await device.lan.start();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    device.lan.posture.change(Posture.silent);
    await device.lan.stop();

    // The old listener must be gone: nothing accepts a connection on that port.
    await expectLater(
      Socket.connect('127.0.0.1', tcpPort, timeout: const Duration(seconds: 2)),
      throwsA(isA<SocketException>()),
    );
    // And no UDP socket still holds the beacon port: a fresh bind succeeds.
    final probe = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      beaconPort,
      reuseAddress: false,
    );
    probe.close();
  });

  test('a Silent phone refuses to start a listener at all', () async {
    final identity = await Identity.generate();
    final device = await unitDevice(
      identity,
      unitSecret: testSecret(22),
      roster: [identity],
    );
    device.lan.posture.change(Posture.silent);

    await expectLater(device.lan.start(), throwsStateError);
    expect(device.lan.beaconsRunning, isFalse);
  });
}
