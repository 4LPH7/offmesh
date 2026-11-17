import 'dart:math';

import 'package:flutter/material.dart';
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
import 'package:offmesh/ui/home_page.dart';

/// A started controller for "Bravo" in a unit with "Alpha", and Alpha's identity.
Future<(ChatController, Identity)> _setUp(WidgetTester tester) async {
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
  return (controller, alpha);
}

/// Opens a menu item from the talk screen: the menu, then the item (two taps).
Future<void> _openMenu(WidgetTester tester, String item) async {
  await tester.tap(find.byKey(const Key('menu-button')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key(item)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows my ID, members with fingerprints, and selects a contact', (
    tester,
  ) async {
    final (controller, alpha) = await _setUp(tester);
    final alphaPrint = controller.members.last.fingerprint;

    await tester.pumpWidget(
      MaterialApp(home: HomePage(controller: controller)),
    );

    expect(find.text('No one to talk to yet'), findsNothing);
    expect(find.byKey(const Key('status-line')), findsOneWidget);
    expect(find.bySemanticsLabel('Status: No one in range'), findsOneWidget);
    await _openMenu(tester, 'menu-unit');

    expect(find.text('My ID'), findsOneWidget);
    expect(find.text(controller.myId), findsOneWidget);
    expect(find.text('Bravo (this device)'), findsOneWidget);
    expect(find.text(alphaPrint), findsOneWidget);
    expect(find.byKey(const Key('share-unit-button')), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('conversation-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('conversation-${alpha.peerId.hex}')));
    await tester.pumpAndSettle();

    expect(controller.selectedContact, alpha.peerId.hex);
    expect(
      find.descendant(
        of: find.byKey(const Key('conversation-picker')),
        matching: find.text('Alpha'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('message-field')), findsOneWidget);
  });

  testWidgets('screens fit phone, tablet and desktop widths, and 2x text', (
    tester,
  ) async {
    final (controller, alpha) = await _setUp(tester);
    controller.select(alpha.peerId.hex);

    for (final scale in [1.0, 2.0]) {
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: MaterialApp(home: HomePage(controller: controller)),
        ),
      );
      for (final size in [
        const Size(320, 720),
        const Size(768, 1024),
        const Size(1440, 900),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'Talk $size x$scale');

        await _openMenu(tester, 'menu-unit');
        expect(tester.takeException(), isNull, reason: 'Unit $size x$scale');
        await tester.pageBack();
        await tester.pumpAndSettle();

        await _openMenu(tester, 'menu-controls');
        expect(tester.takeException(), isNull, reason: 'Ctrl $size x$scale');
        await tester.pageBack();
        await tester.pumpAndSettle();
      }
    }
  });

  testWidgets('every tappable control on the talk screen is 48 dp or more', (
    tester,
  ) async {
    final (controller, alpha) = await _setUp(tester);
    controller.select(alpha.peerId.hex);
    await tester.pumpWidget(
      MaterialApp(home: HomePage(controller: controller)),
    );
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
  });

  testWidgets('the delivered mark appears only after the matching receipt', (
    tester,
  ) async {
    final (controller, alpha) = await _setUp(tester);
    final alphaId = alpha.peerId.hex;
    controller.select(alphaId);
    await tester.runAsync(() async {
      await controller.send(alphaId, 'one');
      await controller.send(alphaId, 'two');
    });
    await tester.pumpWidget(
      MaterialApp(home: HomePage(controller: controller)),
    );

    expect(find.byIcon(Icons.done), findsNWidgets(2));
    expect(find.byIcon(Icons.done_all), findsNothing);

    controller.handleReceipt(
      DeliveryReceiptEvent(
        peerId: alpha.peerId,
        receipt: DeliveryReceipt(
          packetId: controller.thread(alphaId).last.packetId!,
          receivedAt: DateTime.utc(2026),
        ),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.done), findsOneWidget);
    expect(find.byIcon(Icons.done_all), findsOneWidget);
    expect(find.text('Delivered'), findsOneWidget);
    expect(find.text('Sent'), findsOneWidget);
    final latest = find.byKey(
      ValueKey('message-${controller.thread(alphaId).last.packetId}'),
    );
    expect(
      find.descendant(of: latest, matching: find.text('two')),
      findsOneWidget,
    );
  });
}
