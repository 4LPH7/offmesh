import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/app/chat_controller.dart';
import 'package:offmesh/app/secret_store.dart';
import 'package:offmesh/app/unit_store.dart';
import 'package:offmesh/core/crypto/identity.dart';
import 'package:offmesh/core/mesh/mesh_node.dart';
import 'package:offmesh/core/protocol/delivery_ack.dart';
import 'package:offmesh/core/protocol/packet.dart';
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

Future<ChatController> _started(SecretStore store, {Identity? id}) async {
  final controller = await _controller(store, id: id);
  await controller.start();
  return controller;
}

String _codeOf(Identity identity, String name) =>
    IdentityCode.encode(UnitMember(identity.publicKey, name));

void main() {
  test('an unprovisioned phone does not listen and refuses to dial', () async {
    final controller = await _started(MemorySecretStore());

    await controller.connect('127.0.0.1', 1);

    expect(controller.provisioned, isFalse);
    expect(controller.listenPort, isNull);
    expect(controller.lastError, 'Join a unit before linking');
    expect(controller.lan.linkCount, 0);
  });

  test('creating a unit stores it, lists this phone and starts LAN', () async {
    final store = MemorySecretStore();
    final controller = await _started(store);

    expect(await controller.createUnit(' Alpha '), isTrue);

    expect(controller.provisioned, isTrue);
    expect(controller.listenPort, isNotNull);
    final self = controller.members.single;
    expect(self.isSelf, isTrue);
    expect(self.name, 'Alpha');
    expect(self.peerId, controller.myId);
    expect(self.fingerprint, controller.myFingerprint);
    expect(controller.contacts, isEmpty);
    expect((await UnitStore.load(store))!.members.single.name, 'Alpha');
    expect(controller.myIdentityCode, startsWith(identityCodePrefix));
  });

  test('a stored unit is loaded on the next start', () async {
    final store = MemorySecretStore();
    final identity = await Identity.generate();
    await (await _started(store, id: identity)).createUnit('Alpha');

    final again = await _started(store, id: identity);

    expect(again.provisioned, isTrue);
    expect(again.listenPort, isNotNull);
    expect(again.members.single.name, 'Alpha');
  });

  test(
    'adding a member makes it a contact with name and fingerprint',
    () async {
      final store = MemorySecretStore();
      final controller = await _started(store);
      await controller.createUnit('Alpha');
      final bravo = await Identity.generate();

      expect(await controller.addMember(_codeOf(bravo, 'Bravo')), isTrue);

      expect(controller.contacts, [bravo.peerId.hex]);
      expect(controller.nameOf(bravo.peerId.hex), 'Bravo');
      expect(
        controller.members.last.fingerprint,
        await fingerprint(bravo.publicKey),
      );
      expect((await UnitStore.load(store))!.members, hasLength(2));
    },
  );

  test('a member added while listening can link without a restart', () async {
    final alpha = await _started(MemorySecretStore());
    await alpha.createUnit('Alpha');
    final port = alpha.listenPort!;
    final bravoId = await Identity.generate();
    final bravo = await _started(MemorySecretStore(), id: bravoId);

    expect(await alpha.addMember(_codeOf(bravoId, 'Bravo')), isTrue);
    expect(await bravo.importUnit(alpha.unitCode!), isTrue);
    await bravo.connect('127.0.0.1', port);

    expect(alpha.listenPort, port);
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (alpha.lan.linkCount != 1 || bravo.lan.linkCount != 1) {
      if (DateTime.now().isAfter(deadline)) fail('members did not link');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(alpha.linkedNeighbours, {bravoId.peerId.hex});

    // The real receipt stream marks the message delivered.
    final alphaId = alpha.myId;
    await bravo.send(alphaId, 'over LAN');
    while (!bravo.thread(alphaId).single.delivered) {
      if (DateTime.now().isAfter(deadline)) fail('no delivery receipt');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(alpha.thread(bravoId.peerId.hex).single.text, 'over LAN');
  });

  test('a receipt marks only the matching message from that peer', () async {
    final me = await Identity.generate();
    final alpha = await Identity.generate();
    final charlie = await Identity.generate();
    final controller = await _started(MemorySecretStore(), id: me);
    await controller.importUnit(
      UnitRoster(UnitStore.generateSecret(), [
        UnitMember(me.publicKey, 'Bravo'),
        UnitMember(alpha.publicKey, 'Alpha'),
        UnitMember(charlie.publicKey, 'Charlie'),
      ]).toText(),
    );
    final alphaId = alpha.peerId.hex;
    await controller.send(alphaId, 'one');
    await controller.send(alphaId, 'two');
    final sent = controller.thread(alphaId);
    expect(sent.map((m) => m.packetId), everyElement(isNotNull));
    expect(sent.any((m) => m.delivered), isFalse);
    DeliveryReceiptEvent receipt(Identity from, int packetId) =>
        DeliveryReceiptEvent(
          peerId: from.peerId,
          receipt: DeliveryReceipt(
            packetId: packetId,
            receivedAt: DateTime.utc(2026),
          ),
        );

    controller.handleReceipt(receipt(charlie, sent[1].packetId!));
    controller.handleReceipt(receipt(alpha, sent[1].packetId! ^ 1));
    expect(controller.thread(alphaId).any((m) => m.delivered), isFalse);

    controller.handleReceipt(receipt(alpha, sent[1].packetId!));
    expect(controller.thread(alphaId).map((m) => (m.text, m.delivered)), [
      ('one', false),
      ('two', true),
    ]);
  });

  test('a bad or duplicate identity code is refused', () async {
    final controller = await _started(MemorySecretStore());
    expect(await controller.addMember('OFFM-ID1:AAAA'), isFalse);
    expect(controller.lastError, 'not in a unit');

    await controller.createUnit('Alpha');
    expect(await controller.addMember('garbage'), isFalse);
    expect(controller.lastError, contains('identity code'));
    expect(await controller.addMember(controller.myIdentityCode!), isFalse);
    expect(controller.lastError, 'duplicate member key');
    expect(controller.members, hasLength(1));
  });

  test(
    'a unit code without this phone is refused and nothing is stored',
    () async {
      final store = MemorySecretStore();
      final controller = await _started(store);
      final other = UnitRoster(UnitStore.generateSecret(), [
        UnitMember((await Identity.generate()).publicKey, 'Alpha'),
      ]);

      expect(await controller.importUnit(other.toText()), isFalse);

      expect(controller.lastError, contains('does not list this phone'));
      expect(controller.provisioned, isFalse);
      expect(controller.listenPort, isNull);
      expect(await store.read(unitKey), isNull);
    },
  );

  test(
    'joining a unit that lists this phone stores it; re-import replaces',
    () async {
      final store = MemorySecretStore();
      final me = await Identity.generate();
      final alpha = await Identity.generate();
      final controller = await _started(store, id: me);
      final first = UnitRoster(UnitStore.generateSecret(), [
        UnitMember(alpha.publicKey, 'Alpha'),
        UnitMember(me.publicKey, 'Bravo'),
      ]);

      expect(await controller.importUnit(first.toText()), isTrue);
      expect(controller.contacts, [alpha.peerId.hex]);
      expect(controller.listenPort, isNotNull);

      final second = UnitRoster(UnitStore.generateSecret(), [
        UnitMember(me.publicKey, 'Bravo'),
      ]);
      expect(await controller.importUnit(second.toText()), isTrue);

      expect(controller.contacts, isEmpty);
      expect(controller.listenPort, isNotNull);
      expect((await UnitStore.load(store))!.unitSecret, second.unitSecret);
    },
  );

  test('a damaged stored unit leaves the phone unprovisioned', () async {
    final store = MemorySecretStore();
    await store.write(unitKey, Uint8List.fromList([9, 9]));

    final controller = await _started(store);

    expect(controller.provisioned, isFalse);
    expect(controller.listenPort, isNull);
    expect(controller.lastError, contains('damaged'));
  });

  test(
    'messages: outgoing recorded, roster sender kept, others dropped',
    () async {
      final me = await Identity.generate();
      final alpha = await Identity.generate();
      final controller = await _started(MemorySecretStore(), id: me);
      await controller.importUnit(
        UnitRoster(UnitStore.generateSecret(), [
          UnitMember(me.publicKey, 'Bravo'),
          UnitMember(alpha.publicKey, 'Alpha'),
        ]).toText(),
      );
      final alphaId = alpha.peerId.hex;

      await controller.send(alphaId, 'hello');
      controller.handleIncoming(
        ReceivedMessage(
          senderId: alpha.peerId,
          plaintext: Uint8List.fromList(utf8.encode('hi there')),
        ),
      );
      controller.handleIncoming(
        ReceivedMessage(
          senderId: Uint8List.fromList(List.filled(8, 0x33)),
          plaintext: Uint8List.fromList(utf8.encode('stranger')),
        ),
      );

      final thread = controller.thread(alphaId);
      expect(thread.map((m) => (m.outgoing, m.text)), [
        (true, 'hello'),
        (false, 'hi there'),
      ]);
      expect(controller.contacts, [alphaId]);
      expect(controller.thread('3333333333333333'), isEmpty);
    },
  );
}
