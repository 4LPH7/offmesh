import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/app/chat_controller.dart';
import 'package:offmesh/app/secret_store.dart';
import 'package:offmesh/app/unit_store.dart';
import 'package:offmesh/core/crypto/identity.dart';
import 'package:offmesh/core/mesh/mesh_node.dart';
import 'package:offmesh/core/provisioning/unit_roster.dart';
import 'package:offmesh/main.dart';
import 'package:offmesh/transports/lan_manager.dart';
import 'package:offmesh/ui/home_page.dart';
import 'package:offmesh/ui/provisioning_page.dart';

Future<ChatController> _unprovisioned(WidgetTester tester) async {
  // Tall surface so the whole lazy ListView is built.
  tester.view.physicalSize = const Size(800, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final identity = await tester.runAsync(Identity.generate) as Identity;
  final node = MeshNode(
    identity: identity,
    transports: const [],
    random: Random(1),
    delay: (_) async {},
  );
  final controller = ChatController(
    node: node,
    lan: LanManager(node: node, beaconPort: 0),
    store: MemorySecretStore(),
  );
  await tester.runAsync(controller.start);
  addTearDown(() => tester.runAsync(controller.stop));
  return controller;
}

void main() {
  testWidgets('unprovisioned app shows the provisioning screen, not chat', (
    tester,
  ) async {
    final controller = await _unprovisioned(tester);

    await tester.pumpWidget(OffMeshApp(controller: controller));

    expect(find.byType(ProvisioningPage), findsOneWidget);
    expect(find.byType(HomePage), findsNothing);
    expect(
      find.text('This phone is not in a unit and will not link to anyone.'),
      findsOneWidget,
    );
    expect(controller.listenPort, isNull);
    expect(find.text('Set up OffMesh · step 1 of 3'), findsOneWidget);
    final next = find.byKey(const Key('name-next-button'));
    expect(tester.widget<FilledButton>(next).onPressed, isNull);

    await tester.enterText(find.byKey(const Key('my-name-field')), 'Alpha');
    await tester.pump();
    expect(tester.widget<FilledButton>(next).onPressed, isNotNull);
    await tester.tap(next);
    await tester.pump();

    expect(find.text('Set up OffMesh · step 2 of 3'), findsOneWidget);
    expect(find.text(controller.identityCodeFor('Alpha')!), findsOneWidget);
    expect(find.byKey(const Key('create-unit-button')), findsOneWidget);
  });

  testWidgets('a unit code without this phone shows a clear refusal', (
    tester,
  ) async {
    final controller = await _unprovisioned(tester);
    final stranger = await tester.runAsync(Identity.generate) as Identity;
    final code = UnitRoster(UnitStore.generateSecret(), [
      UnitMember(stranger.publicKey, 'Alpha'),
    ]).toText();
    await tester.pumpWidget(OffMeshApp(controller: controller));
    await tester.enterText(find.byKey(const Key('my-name-field')), 'Bravo');
    await tester.pump();
    await tester.tap(find.byKey(const Key('name-next-button')));
    await tester.pump();

    await tester.enterText(find.byKey(const Key('unit-code-field')), code);
    await tester.tap(find.byKey(const Key('join-unit-button')));
    await tester.pump();

    expect(find.textContaining('does not list this phone'), findsOneWidget);
    expect(find.byType(ProvisioningPage), findsOneWidget);
  });

  testWidgets('creating a unit switches to the home screen', (tester) async {
    final controller = await _unprovisioned(tester);
    await tester.pumpWidget(OffMeshApp(controller: controller));
    await tester.enterText(find.byKey(const Key('my-name-field')), 'Alpha');
    await tester.pump();
    await tester.tap(find.byKey(const Key('name-next-button')));
    await tester.pump();

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('create-unit-button')));
      for (var i = 0; i < 100 && controller.listenPort == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pump();

    expect(controller.provisioned, isTrue);
    expect(find.byType(HomePage), findsOneWidget);
    await tester.tap(find.byKey(const Key('menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('menu-unit')));
    await tester.pumpAndSettle();
    expect(find.text('Alpha (this device)'), findsOneWidget);
  });
}
