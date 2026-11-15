import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/app/chat_controller.dart';
import 'package:offmesh/app/secret_store.dart';
import 'package:offmesh/core/crypto/identity.dart';
import 'package:offmesh/core/mesh/mesh_node.dart';
import 'package:offmesh/core/posture.dart';
import 'package:offmesh/transports/lan_manager.dart';
import 'package:offmesh/ui/relay_screen.dart';

void main() {
  testWidgets(
    'relay mode is black, shows counters, sets Normal and Leave returns',
    (tester) async {
      final identity = await tester.runAsync(Identity.generate) as Identity;
      final node = MeshNode(
        identity: identity,
        transports: const [],
        random: Random(1),
        delay: (_) async {},
      );
      final store = MemorySecretStore();
      final controller = ChatController(
        node: node,
        lan: LanManager(node: node, beaconPort: 0),
        store: store,
      );
      await tester.runAsync(controller.start);
      addTearDown(() => tester.runAsync(controller.stop));
      controller.posture.change(Posture.silent);

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => RelayScreen(controller: controller),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      expect(find.text('open'), findsOneWidget);
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(RelayScreen), findsOneWidget);

      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).last);
      expect(scaffold.backgroundColor, Colors.black);
      expect(find.text('Forwarded: 0'), findsOneWidget);
      expect(find.text('Suppressed: 0'), findsOneWidget);
      expect(find.text('Links: 0'), findsOneWidget);
      expect(controller.posture.current, Posture.normal);
      // Let the setPosture save from initState finish before leaving.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );

      await tester.tap(find.byKey(const Key('relay-leave-button')));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(find.byType(RelayScreen), findsNothing);
    },
  );
}
