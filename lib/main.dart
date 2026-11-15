import 'package:flutter/material.dart';

import 'app/bootstrap.dart';
import 'app/chat_controller.dart';
import 'app/secret_store.dart';
import 'ui/home_page.dart';
import 'ui/provisioning_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = PlatformSecretStore();
  final ChatController controller;
  try {
    controller = await buildController(store);
  } on StartupFailure catch (e) {
    runApp(StartupErrorApp(message: e.message));
    return;
  }
  runApp(OffMeshRoot(store: store, controller: controller));
}

/// Owns the controller so a panic wipe can replace it. The wiped node's identity is
/// discarded; the next controller loads a new one from the store.
class OffMeshRoot extends StatefulWidget {
  const OffMeshRoot({super.key, required this.store, required this.controller});

  final SecretStore store;
  final ChatController controller;

  @override
  State<OffMeshRoot> createState() => _OffMeshRootState();
}

class _OffMeshRootState extends State<OffMeshRoot> {
  late ChatController _controller = widget.controller;
  String? _failure;

  Future<void> _rebuildAfterWipe() async {
    final wiped = _controller;
    if (!await wiped.panicWipe()) return;
    try {
      final fresh = await buildController(widget.store);
      setState(() => _controller = fresh);
    } on StartupFailure catch (e) {
      setState(() => _failure = e.message);
    }
    wiped.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final failure = _failure;
    if (failure != null) return StartupErrorApp(message: failure);
    return OffMeshApp(controller: _controller, onPanicWipe: _rebuildAfterWipe);
  }
}

class OffMeshApp extends StatelessWidget {
  const OffMeshApp({super.key, required this.controller, this.onPanicWipe});

  final ChatController controller;
  final Future<void> Function()? onPanicWipe;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OffMesh',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF126B63),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(scrolledUnderElevation: 0),
        cardTheme: CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Color(0xFFE0E5E3)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      home: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => controller.provisioned
            ? HomePage(controller: controller, onPanicWipe: onPanicWipe)
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
