import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/app/chat_controller.dart';
import 'package:offmesh/core/crypto/identity.dart';
import 'package:offmesh/core/mesh/mesh_node.dart';
import 'package:offmesh/transports/lan_manager.dart';
import 'package:offmesh/ui/home_page.dart';

const String _contactId = '0123456789abcdef';

void main() {
  testWidgets('shows my ID and adds a contact by pasted ID', (tester) async {
    final identity = await tester.runAsync(Identity.generate) as Identity;
    final node = MeshNode(
      identity: identity,
      transports: const [],
      random: Random(1),
      delay: (_) async {},
    );
    final controller = ChatController(node: node, lan: LanManager(node: node, beaconPort: 0));

    await tester.pumpWidget(MaterialApp(home: HomePage(controller: controller)));

    expect(find.text('My ID'), findsOneWidget);
    expect(find.text(controller.myId), findsOneWidget);

    await tester.enterText(find.byKey(const Key('contact-id-field')), _contactId);
    await tester.tap(find.byKey(const Key('add-contact-button')));
    await tester.pump();

    expect(controller.selectedContact, _contactId);
    expect(find.text(_contactId), findsWidgets);
  });
}
