import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/app/chat_controller.dart';
import 'package:offmesh/app/history_store.dart';
import 'package:offmesh/app/panic_wipe.dart';
import 'package:offmesh/app/secret_store.dart';
import 'package:offmesh/core/crypto/identity.dart';
import 'package:offmesh/core/mesh/mesh_node.dart';
import 'package:offmesh/transports/lan_manager.dart';

Future<ChatController> _controller(SecretStore store, Identity identity) async {
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
  await controller.start();
  return controller;
}

ChatMessage _m(String text, {bool queued = false}) => ChatMessage(
  outgoing: true,
  text: text,
  at: DateTime.fromMillisecondsSinceEpoch(1000),
  packetId: 7,
  queued: queued,
);

void main() {
  test(
    'round trip keeps fields, drops held messages, caps each thread',
    () async {
      final store = MemorySecretStore();
      await HistoryStore.save(store, {
        '#ops': [
          for (var i = 0; i < maxHistoryPerThread + 5; i++) _m('m$i'),
          _m('held', queued: true),
        ],
        'abc': [
          ChatMessage(
            outgoing: false,
            text: 'hi',
            at: DateTime.fromMillisecondsSinceEpoch(5),
            from: 'Alpha',
          ),
        ],
      });
      final loaded = await HistoryStore.load(store);
      expect(loaded['#ops']!.length, maxHistoryPerThread);
      expect(loaded['#ops']!.first.text, 'm5');
      expect(loaded['#ops']!.any((m) => m.text == 'held'), isFalse);
      expect(loaded['#ops']!.last.packetId, 7);
      expect(loaded['abc']!.single.from, 'Alpha');
      expect(loaded['abc']!.single.outgoing, isFalse);
    },
  );

  test('a damaged record reads as no history', () async {
    final store = MemorySecretStore();
    await store.write(historyKey, Uint8List.fromList([0xFF, 0x00, 0x7B]));
    expect(await HistoryStore.load(store), isEmpty);
  });

  test('threads survive a restart, and panic wipe deletes them', () async {
    final store = MemorySecretStore();
    final me = await Identity.generate();
    final first = await _controller(store, me);
    await first.createUnit('Alpha');
    await first.joinChannel('ops');
    await first.send('#ops', 'over');
    await first.stop();

    final second = await _controller(store, me);
    addTearDown(second.stop);
    expect(second.thread('#ops').map((m) => m.text), ['over']);
    expect(storedSecretKeys, contains(historyKey));

    expect(await second.panicWipe(), isTrue);
    expect(await store.read(historyKey), isNull);
  });
}
