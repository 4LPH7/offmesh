import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/crypto/identity.dart';
import 'package:offmesh/core/posture.dart';

import 'lan_test_support.dart';

/// A port of its own, so this file's beacons never meet another test file's beacons.
late int _lifecycleBeaconPort;

void main() {
  setUpAll(() async {
    _lifecycleBeaconPort = await freeUdpPort();
  });
  test(
    'a start that begins while stop() is closing gets a live listener',
    () async {
      final id = await Identity.generate();
      final a = await unitDevice(id, unitSecret: testSecret(4), roster: [id]);
      await a.lan.start();

      final stopping = a.lan.stop();
      final restarted = await a.lan.start();
      await stopping;

      expect(a.lan.listenPort, restarted);
      final socket = await Socket.connect('127.0.0.1', restarted);
      socket.destroy();
    },
  );

  test('Silent during start leaves no beacon socket or listener behind', () async {
    final id = await Identity.generate();
    final a = await unitDevice(
      id,
      unitSecret: testSecret(5),
      roster: [id],
      beaconPort: _lifecycleBeaconPort,
    );
    final starting = a.lan.start().then<void>((_) {}, onError: (Object _) {});
    // Yield until the TCP listener is up, then go Silent the way ChatController does.
    // Best effort: the beacon binds may or may not still be pending at that point.
    for (var turn = 0; a.lan.listenPort == null && turn < 1000; turn++) {
      await Future<void>.delayed(Duration.zero);
    }
    a.lan.posture.change(Posture.silent);
    await a.lan.stop();
    await starting;

    expect(a.lan.listenPort, isNull);
    expect(a.lan.beaconsRunning, isFalse);
  });
}
