import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/app/chat_controller.dart';
import 'package:offmesh/core/crypto/identity.dart';
import 'package:offmesh/core/mesh/mesh_node.dart';
import 'package:offmesh/transports/lan_manager.dart';

Future<ChatController> _controller() async {
  final node = MeshNode(
    identity: await Identity.generate(),
    transports: const [],
    random: Random(),
    delay: (_) async {},
  );
  return ChatController(node: node, lan: LanManager(node: node, beaconPort: 0));
}

Uint8List _id(int fill) => Uint8List.fromList(List.filled(8, fill));

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  test('an outgoing message is recorded in the contact thread', () async {
    final controller = await _controller();
    final contact = _hex(_id(0x42));

    await controller.send(contact, 'hello');

    final thread = controller.thread(contact);
    expect(thread, hasLength(1));
    expect(thread.single.outgoing, isTrue);
    expect(thread.single.text, 'hello');
  });

  test('an incoming message opens a thread for its sender', () async {
    final controller = await _controller();

    controller.handleIncoming(ReceivedMessage(
      senderId: _id(0x33),
      plaintext: Uint8List.fromList(utf8.encode('hi there')),
    ));

    final sender = _hex(_id(0x33));
    expect(controller.thread(sender).single.outgoing, isFalse);
    expect(controller.thread(sender).single.text, 'hi there');
    expect(controller.contacts, contains(sender));
  });

  test('adding a contact by ID selects it', () async {
    final controller = await _controller();
    final id = _hex(_id(0x55));

    controller.addContact(id);

    expect(controller.selectedContact, id);
    expect(controller.contacts, contains(id));
  });

  test('a malformed contact ID is refused', () async {
    final controller = await _controller();

    expect(() => controller.addContact('not-hex'), throwsFormatException);
    expect(() => controller.addContact('abcd'), throwsFormatException);
  });
}
