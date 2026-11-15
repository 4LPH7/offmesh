import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/app/chat_controller.dart';
import 'package:offmesh/app/secret_store.dart';
import 'package:offmesh/core/crypto/identity.dart';
import 'package:offmesh/core/mesh/mesh_node.dart';
import 'package:offmesh/core/posture.dart';
import 'package:offmesh/transports/lan_manager.dart';

/// Direct tests for connect rejection and the Silent burst guard, which were previously
/// only exercised indirectly by link-count tests.
void main() {
  test(
    'connect to this phone itself throws instead of reporting success',
    () async {
      final node = MeshNode(
        identity: await Identity.generate(),
        transports: const [],
        random: Random(1),
        delay: (_) async {},
      );
      final controller = ChatController(
        node: node,
        lan: LanManager(node: node, beaconPort: 0),
        store: MemorySecretStore(),
      );
      addTearDown(controller.stop);
      await controller.start();
      expect(await controller.createUnit('Alpha'), isTrue);
      final ownPort = controller.listenPort!;

      await expectLater(
        controller.lan.connect('127.0.0.1', ownPort),
        throwsStateError,
      );
      expect(controller.lan.linkCount, 0);
    },
  );

  test('a burst in Silent sends nothing and says why', () async {
    final node = MeshNode(
      identity: await Identity.generate(),
      transports: const [],
      random: Random(2),
      delay: (_) async {},
    );
    final controller = ChatController(
      node: node,
      lan: LanManager(node: node, beaconPort: 0),
      store: MemorySecretStore(),
    );
    addTearDown(controller.stop);
    await controller.start();
    await controller.setPosture(Posture.silent);

    await controller.sendBurst();

    expect(controller.lastError, startsWith('Silent'));
    expect(controller.queuedCount, 0);
  });
}
