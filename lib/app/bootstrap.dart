import 'dart:io';
import 'dart:math';

import '../core/crypto/identity.dart';
import '../core/mesh/mesh_node.dart';
import '../transports/lan_manager.dart';
import 'chat_controller.dart';
import 'identity_store.dart';
import 'secret_store.dart';
import 'voice_audio.dart';

/// The app cannot start. [message] is safe to show: it never carries key bytes or paths.
class StartupFailure implements Exception {
  const StartupFailure(this.message);

  final String message;
}

/// Loads the device identity and starts a fresh node and controller. Also run again
/// after a panic wipe, so the app gets a new identity rather than keeping the wiped one.
Future<ChatController> buildController(SecretStore store) async {
  final Identity identity;
  try {
    identity = await IdentityStore.loadOrCreate(store);
  } on IdentityStoreException catch (e) {
    throw StartupFailure(e.message);
  } catch (_) {
    // Platform errors may include file paths; keep the screen generic.
    throw const StartupFailure('secure storage is unavailable');
  }
  final node = MeshNode(
    identity: identity,
    transports: const [],
    random: Random.secure(),
  );
  // Push-to-talk plugins exist for Android and Windows only.
  final voice = Platform.isAndroid || Platform.isWindows;
  final controller = ChatController(
    node: node,
    lan: LanManager(node: node),
    store: store,
    capture: voice ? RecordVoiceCapture() : null,
    playback: voice ? SoloudVoicePlayback() : null,
  );
  try {
    await controller.start();
  } catch (_) {
    throw const StartupFailure('secure storage or networking is unavailable');
  }
  return controller;
}
