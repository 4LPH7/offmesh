import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/app/channel_store.dart';
import 'package:offmesh/app/chat_controller.dart';
import 'package:offmesh/app/panic_wipe.dart';
import 'package:offmesh/app/secret_store.dart';
import 'package:offmesh/core/crypto/identity.dart';
import 'package:offmesh/core/mesh/mesh_node.dart';
import 'package:offmesh/transports/lan_manager.dart';

Future<ChatController> _started(SecretStore store, Identity identity) async {
  final node = MeshNode(
    identity: identity,
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

void main() {
  test('joining needs a unit', () async {
    final controller = await _started(
      MemorySecretStore(),
      await Identity.generate(),
    );

    expect(await controller.joinChannel('ops'), isFalse);
    expect(controller.lastError, 'Join a unit first');
    expect(controller.channels, isEmpty);
  });

  test(
    'join opens the channel, survives a restart, and leave forgets it',
    () async {
      final store = MemorySecretStore();
      final identity = await Identity.generate();
      final first = await _started(store, identity);
      expect(await first.createUnit('Alpha'), isTrue);

      expect(await first.joinChannel('  Ops '), isTrue);
      expect(first.channels, ['#ops']);
      expect(first.selectedContact, '#ops');
      expect(first.conversations.first, '#ops');
      expect(await ChannelStore.load(store), ['ops']);
      await first.stop();

      final second = await _started(store, identity);
      expect(second.channels, ['#ops']);

      expect(await second.leaveChannel('#ops'), isTrue);
      expect(second.channels, isEmpty);
      expect(await ChannelStore.load(store), isEmpty);
    },
  );

  test('a bad channel name is refused with a message', () async {
    final controller = await _started(
      MemorySecretStore(),
      await Identity.generate(),
    );
    await controller.createUnit('Alpha');

    expect(await controller.joinChannel('   '), isFalse);
    expect(controller.lastError, 'channel name is empty');
  });

  test('panic wipe covers the channel list', () {
    expect(storedSecretKeys, contains(channelsKey));
  });
}
