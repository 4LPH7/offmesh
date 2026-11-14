import 'dart:math';

import 'package:flutter/material.dart';

import 'app/chat_controller.dart';
import 'app/identity_store.dart';
import 'app/secret_store.dart';
import 'core/crypto/identity.dart';
import 'core/mesh/mesh_node.dart';
import 'transports/lan_manager.dart';
import 'ui/home_page.dart';
import 'ui/provisioning_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = PlatformSecretStore();
  final Identity identity;
  try {
    identity = await IdentityStore.loadOrCreate(store);
  } on IdentityStoreException catch (e) {
    runApp(StartupErrorApp(message: e.message));
    return;
  } catch (_) {
    // Platform errors may include file paths; keep the screen generic.
    runApp(const StartupErrorApp(message: 'secure storage is unavailable'));
    return;
  }
  final node = MeshNode(
    identity: identity,
    transports: const [],
    random: Random.secure(),
  );
  final controller = ChatController(
    node: node,
    lan: LanManager(node: node),
    store: store,
  );
  try {
    await controller.start();
  } catch (_) {
    runApp(
      const StartupErrorApp(
        message: 'secure storage or networking is unavailable',
      ),
    );
    return;
  }
  runApp(OffMeshApp(controller: controller));
}

class OffMeshApp extends StatelessWidget {
  const OffMeshApp({super.key, required this.controller});

  final ChatController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OffMesh',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => controller.provisioned
            ? HomePage(controller: controller)
            : ProvisioningPage(controller: controller),
      ),
    );
  }
}

/// Shown instead of the app when the device identity cannot be loaded.
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OffMesh',
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('OffMesh cannot start: $message'),
          ),
        ),
      ),
    );
  }
}
