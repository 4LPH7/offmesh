import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/app/chat_controller.dart';
import 'package:offmesh/app/secret_store.dart';
import 'package:offmesh/app/unit_store.dart';
import 'package:offmesh/core/crypto/identity.dart';
import 'package:offmesh/core/mesh/mesh_node.dart';
import 'package:offmesh/core/posture.dart';
import 'package:offmesh/core/provisioning/unit_roster.dart';
import 'package:offmesh/transports/lan_manager.dart';
import 'package:offmesh/ui/home_page.dart';

/// A started, provisioned controller for "Bravo" in a unit with "Alpha".
Future<ChatController> _setUp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final me = await tester.runAsync(Identity.generate) as Identity;
  final alpha = await tester.runAsync(Identity.generate) as Identity;
  final node = MeshNode(
    identity: me,
    transports: const [],
    random: Random(1),
    delay: (_) async {},
  );
  final controller = ChatController(
    node: node,
    lan: LanManager(node: node, beaconPort: 0),
    store: MemorySecretStore(),
  );
  await tester.runAsync(() async {
    await controller.start();
    await controller.importUnit(
      UnitRoster(UnitStore.generateSecret(), [
        UnitMember(me.publicKey, 'Bravo'),
        UnitMember(alpha.publicKey, 'Alpha'),
      ]).toText(),
    );
  });
  addTearDown(() => tester.runAsync(controller.stop));
  return controller;
}

void main() {
  testWidgets('quiet shows the send-burst button and the posture is saved', (
    tester,
  ) async {
    final controller = await _setUp(tester);
    await tester.pumpWidget(
      MaterialApp(home: HomePage(controller: controller)),
    );
    await tester.tap(find.byKey(const Key('home-tab-controls')));
    await tester.pump();
    expect(find.byKey(const Key('send-burst-button')), findsNothing);

    await tester.runAsync(() => controller.setPosture(Posture.quiet));
    await tester.pump();

    expect(find.byKey(const Key('send-burst-button')), findsOneWidget);
    expect(find.text('0 messages held'), findsOneWidget);

    final alpha = controller.contacts.single;
    controller.select(alpha);
    await tester.runAsync(() => controller.send(alpha, 'hello'));
    await tester.pump();

    expect(find.text('1 message held'), findsOneWidget);
    await tester.tap(find.byKey(const Key('home-tab-messages')));
    await tester.pump();
    expect(
      find.byWidgetPredicate((w) => w is Icon && w.semanticLabel == 'Held'),
      findsOneWidget,
    );
  });

  testWidgets('panic wipe runs only after the word WIPE is typed', (
    tester,
  ) async {
    final controller = await _setUp(tester);
    var wiped = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(
          controller: controller,
          onPanicWipe: () async => wiped++,
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('home-tab-controls')));
    await tester.pump();

    await tester.ensureVisible(find.byKey(const Key('panic-wipe-button')));
    await tester.tap(find.byKey(const Key('panic-wipe-button')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('wipe-confirm-button')))
          .onPressed,
      isNull,
    );

    await tester.enterText(find.byKey(const Key('wipe-confirm-field')), 'wipe');
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('wipe-confirm-button')))
          .onPressed,
      isNull,
    );
    expect(wiped, 0);

    await tester.enterText(find.byKey(const Key('wipe-confirm-field')), 'WIPE');
    await tester.pump();
    await tester.tap(find.byKey(const Key('wipe-confirm-button')));
    await tester.pumpAndSettle();

    expect(wiped, 1);
  });
}
