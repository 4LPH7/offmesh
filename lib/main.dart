import 'dart:math';

import 'package:flutter/material.dart';

import 'app/chat_controller.dart';
import 'core/crypto/identity.dart';
import 'core/mesh/mesh_node.dart';
import 'transports/lan_manager.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final identity = await Identity.generate();
  final node = MeshNode(
    identity: identity,
    transports: const [],
    random: Random.secure(),
  );
  final controller = ChatController(node: node, lan: LanManager(node: node));
  await controller.start();
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
      home: HomePage(controller: controller),
    );
  }
}
