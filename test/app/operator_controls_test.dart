import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/app/chat_controller.dart';
import 'package:offmesh/app/posture_store.dart';
import 'package:offmesh/app/secret_store.dart';
import 'package:offmesh/core/crypto/identity.dart';
import 'package:offmesh/core/mesh/mesh_node.dart';
import 'package:offmesh/core/posture.dart';
import 'package:offmesh/core/provisioning/unit_roster.dart';
import 'package:offmesh/transports/lan_manager.dart';

Future<ChatController> _controller(SecretStore store, {Identity? id}) async {
  final node = MeshNode(
    identity: id ?? await Identity.generate(),
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
  return controller;
}

/// A started controller in a unit with one contact, Bravo.
Future<(ChatController, String)> _withContact(SecretStore store) async {
  final controller = await _controller(store);
  await controller.start();
  await controller.createUnit('Alpha');
  final bravo = await Identity.generate();
  await controller.addMember(
    IdentityCode.encode(UnitMember(bravo.publicKey, 'Bravo')),
  );
  return (controller, controller.contacts.single);
}

void main() {
  test('Silent is restored on launch and nothing binds', () async {
    final store = MemorySecretStore();
    final id = await Identity.generate();
    final first = await _controller(store, id: id);
    await first.start();
    await first.createUnit('Alpha');
    await first.setPosture(Posture.silent);
    expect(first.lan.listenPort, isNull);

    final again = await _controller(store, id: id);
    await again.start();

    expect(again.posture.current, Posture.silent);
    expect(again.provisioned, isTrue);
    expect(again.lan.listenPort, isNull);
    expect(again.listenPort, isNull);
  });

  test('Silent refuses to dial and to start listening', () async {
    final controller = await _controller(MemorySecretStore());
    await controller.start();
    await controller.createUnit('Alpha');
    await controller.setPosture(Posture.silent);

    await controller.connect('127.0.0.1', 1);
    expect(controller.lastError, startsWith('Silent'));
    await expectLater(controller.lan.start(), throwsStateError);
    expect(controller.lan.listenPort, isNull);
  });

  test('Silent stops listening and Normal starts it again', () async {
    final controller = await _controller(MemorySecretStore());
    await controller.start();
    await controller.createUnit('Alpha');
    expect(controller.listenPort, isNotNull);

    await controller.setPosture(Posture.silent);
    expect(controller.listenPort, isNull);
    expect(controller.lan.listenPort, isNull);

    await controller.setPosture(Posture.normal);
    expect(controller.listenPort, isNotNull);
  });

  test('Quiet keeps the listener up, since it only stops beacons', () async {
    final controller = await _controller(MemorySecretStore());
    await controller.start();
    await controller.createUnit('Alpha');

    await controller.setPosture(Posture.quiet);

    expect(controller.posture.current, Posture.quiet);
    expect(controller.listenPort, isNotNull);
  });

  test('Silent sends nothing and holds nothing', () async {
    final (controller, contact) = await _withContact(MemorySecretStore());
    await controller.setPosture(Posture.silent);

    await controller.send(contact, 'hello');

    expect(controller.thread(contact), isEmpty);
    expect(controller.queuedCount, 0);
    expect(controller.lastError, startsWith('Silent'));
  });

  test('Quiet holds a message until the send burst', () async {
    final (controller, contact) = await _withContact(MemorySecretStore());
    await controller.setPosture(Posture.quiet);

    await controller.send(contact, 'one');

    final held = controller.thread(contact).single;
    expect(held.queued, isTrue);
    expect(held.packetId, isNull);
    expect(controller.queuedCount, 1);

    await controller.sendBurst();

    expect(controller.queuedCount, 0);
    final sent = controller.thread(contact).single;
    expect(sent.queued, isFalse);
    expect(sent.packetId, isNotNull);
  });

  test('a saved posture is read back on the next start', () async {
    final store = MemorySecretStore();
    final id = await Identity.generate();
    final first = await _controller(store, id: id);
    await first.start();
    await first.setPosture(Posture.quiet);

    final again = await _controller(store, id: id);
    await again.start();

    expect(await PostureStore.load(store), Posture.quiet);
    expect(again.posture.current, Posture.quiet);
  });
}
