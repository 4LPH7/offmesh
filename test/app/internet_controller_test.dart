import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/app/chat_controller.dart';
import 'package:offmesh/app/internet_store.dart';
import 'package:offmesh/app/panic_wipe.dart';
import 'package:offmesh/app/secret_store.dart';
import 'package:offmesh/core/crypto/identity.dart';
import 'package:offmesh/core/mesh/mesh_node.dart';
import 'package:offmesh/core/posture.dart';
import 'package:offmesh/relay/relay_server.dart';
import 'package:offmesh/transports/lan_manager.dart';
import 'package:offmesh/transports/relay_transport.dart';

Future<ChatController> _controller(SecretStore store) async {
  final node = MeshNode(
    identity: await Identity.generate(),
    transports: const [],
    random: Random(),
    delay: (_) async {},
  );
  final controller = ChatController(
    node: node,
    lan: LanManager(node: node, beaconPort: 0),
    store: store,
  );
  addTearDown(controller.stop);
  await controller.start();
  return controller;
}

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  group('relay address', () {
    test('parses host, host:port, IPv4 and [IPv6]', () {
      expect(
        RelayAddress.parse('relay.example.org').toString(),
        'relay.example.org:7777',
      );
      expect(RelayAddress.parse(' 203.0.113.5:9000 ').port, 9000);
      expect(
        RelayAddress.parse('[2001:db8::1]:8000').toString(),
        '[2001:db8::1]:8000',
      );
      expect(RelayAddress.parse('[::1]').port, 7777);
    });

    test('refuses empty, spaced, bare IPv6, bad ports and odd characters', () {
      for (final bad in [
        '',
        '   ',
        'a b:1',
        '2001:db8::1',
        'host:0',
        'host:70000',
        'host:abc',
        'ho/st:1',
        ':7777',
        '[::1',
      ]) {
        expect(
          () => RelayAddress.parse(bad),
          throwsFormatException,
          reason: bad,
        );
      }
    });
  });

  group('internet switch', () {
    test(
      'off by default; needs a unit, an address and Normal posture',
      () async {
        final c = await _controller(MemorySecretStore());
        expect(c.internetOn, isFalse);

        await c.setInternet(true);
        expect(c.lastError, 'Join a unit first');

        await c.createUnit('Alice');
        await c.setInternet(true);
        expect(c.lastError, 'Set a relay address first');

        expect(await c.setRelayAddress('not valid'), isFalse);
        expect(c.relayAddress, isNull);

        expect(await c.setRelayAddress('127.0.0.1:1'), isTrue);
        await c.setPosture(Posture.quiet);
        await c.setInternet(true);
        expect(c.lastError, 'Set the posture to Normal to use the internet');
        expect(c.internetOn, isFalse);
      },
    );

    test('connects to a relay, and Silent or Quiet switch it off', () async {
      final relay = RelayServer(address: InternetAddress.loopbackIPv4);
      final port = await relay.start();
      addTearDown(relay.stop);
      final c = await _controller(MemorySecretStore());
      await c.createUnit('Alice');
      await c.setRelayAddress('127.0.0.1:$port');

      await c.setInternet(true);
      await _until(() => c.internetState == RelayState.connected);
      expect(c.internetOn, isTrue);
      expect(c.internetState, RelayState.connected);
      expect(relay.connectionCount, 1);

      await c.setPosture(Posture.quiet);
      expect(c.internetOn, isFalse);
      await _until(() => relay.connectionCount == 0);
      expect(relay.connectionCount, 0);

      await c.setPosture(Posture.normal);
      await c.setInternet(true);
      await _until(() => c.internetState == RelayState.connected);
      await c.setPosture(Posture.silent);
      expect(c.internetOn, isFalse);
      expect(c.internetState, RelayState.stopped);
    });

    test(
      'the address and the warning flag persist; wipe covers them',
      () async {
        final store = MemorySecretStore();
        final first = await _controller(store);
        await first.setRelayAddress('relay.example.org:7000');
        await first.acknowledgeInternet();
        await first.stop();

        final second = await _controller(store);
        expect(second.relayAddress, 'relay.example.org:7000');
        expect(second.internetAcked, isTrue);
        expect(
          second.internetOn,
          isFalse,
          reason: 'internet mode is off at every launch',
        );

        expect(
          storedSecretKeys,
          containsAll([relayAddressKey, internetAckKey]),
        );
      },
    );

    test('a damaged stored address reads as no relay', () async {
      final store = MemorySecretStore();
      await store.write(relayAddressKey, Uint8List.fromList([0xFF, 0xFE]));
      final c = await _controller(store);
      expect(c.relayAddress, isNull);
    });
  });
}
