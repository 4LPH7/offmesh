import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/app/posture_store.dart';
import 'package:offmesh/app/secret_store.dart';
import 'package:offmesh/core/posture.dart';

/// A store whose every read fails, as a locked keystore would.
class _UnreadableStore extends MemorySecretStore {
  @override
  Future<Uint8List?> read(String key) async => throw StateError('locked');
}

void main() {
  test('with nothing saved the posture is Normal', () async {
    expect(await PostureStore.load(MemorySecretStore()), Posture.normal);
  });

  test('a saved posture is read back', () async {
    final store = MemorySecretStore();

    await PostureStore.save(store, Posture.quiet);

    expect(await PostureStore.load(store), Posture.quiet);
  });

  test('an unknown saved value loads as Silent', () async {
    final store = MemorySecretStore();
    await store.write(postureKey, Uint8List.fromList('loud'.codeUnits));

    expect(await PostureStore.load(store), Posture.silent);
  });

  test('a read error loads as Silent, never Normal', () async {
    expect(await PostureStore.load(_UnreadableStore()), Posture.silent);
  });
}
