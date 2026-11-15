import 'dart:convert';
import 'dart:typed_data';

import '../core/posture.dart';
import 'secret_store.dart';

const String postureKey = 'posture.v1';

class PostureStore {
  /// The saved posture. Absent means Normal. Any unreadable value, or a read error,
  /// loads as Silent: a broken setting must not switch transmission on.
  static Future<Posture> load(SecretStore store) async {
    try {
      final bytes = await store.read(postureKey);
      if (bytes == null) return Posture.normal;
      final name = utf8.decode(bytes, allowMalformed: true);
      return Posture.values.asNameMap()[name] ?? Posture.silent;
    } catch (_) {
      return Posture.silent;
    }
  }

  static Future<void> save(SecretStore store, Posture posture) =>
      store.write(postureKey, Uint8List.fromList(utf8.encode(posture.name)));
}
