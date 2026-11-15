import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/app/bootstrap.dart';
import 'package:offmesh/app/identity_store.dart';
import 'package:offmesh/app/panic_wipe.dart';
import 'package:offmesh/app/posture_store.dart';
import 'package:offmesh/app/secret_store.dart';
import 'package:offmesh/app/unit_store.dart';
import 'package:offmesh/core/posture.dart';

/// A store whose delete of [failKey] throws, as a locked keystore would.
class _FailingDeleteStore extends MemorySecretStore {
  _FailingDeleteStore(this.failKey);

  final String failKey;

  @override
  Future<void> delete(String key) async {
    if (key == failKey) throw StateError('locked');
    await super.delete(key);
  }
}

void main() {
  test('a failed delete still deletes every other stored key', () async {
    final store = _FailingDeleteStore(identityKey);
    for (final key in storedSecretKeys) {
      await store.write(key, Uint8List.fromList([1, 2, 3]));
    }

    await expectLater(wipeStoredSecrets(store), throwsStateError);

    expect(await store.read(identityKey), isNotNull);
    expect(await store.read(unitKey), isNull);
    expect(await store.read(postureKey), isNull);
  });

  test(
    'panic wipe empties the store and stops LAN; the rebuilt app is new and unprovisioned',
    () async {
      final store = MemorySecretStore();
      final controller = await buildController(store);
      addTearDown(controller.stop);
      expect(await controller.createUnit('Alpha'), isTrue);
      final oldId = controller.myId;
      expect(controller.listenPort, isNotNull);

      expect(await controller.panicWipe(), isTrue);

      for (final key in storedSecretKeys) {
        expect(await store.read(key), isNull, reason: key);
      }
      expect(controller.listenPort, isNull);
      expect(controller.lan.listenPort, isNull);
      expect(controller.provisioned, isFalse);
      expect(controller.posture.current, Posture.normal);

      final rebuilt = await buildController(store);
      addTearDown(rebuilt.stop);
      expect(rebuilt.myId, isNot(oldId));
      expect(rebuilt.provisioned, isFalse);
      expect(rebuilt.listenPort, isNull);
    },
  );

  test(
    'a wipe that fails reports it, keeps the unit for a retry and stays off the air',
    () async {
      final store = _FailingDeleteStore(unitKey);
      final controller = await buildController(store);
      addTearDown(controller.stop);
      await controller.createUnit('Alpha');

      expect(await controller.panicWipe(), isFalse);

      expect(controller.lastError, startsWith('Wipe incomplete'));
      expect(controller.provisioned, isTrue);
      expect(await store.read(unitKey), isNotNull);
      expect(controller.listenPort, isNull);
    },
  );

  test(
    'a wipe removes the saved posture so the rebuilt phone is Normal',
    () async {
      final store = MemorySecretStore();
      final controller = await buildController(store);
      addTearDown(controller.stop);
      await controller.setPosture(Posture.silent);
      expect(await PostureStore.load(store), Posture.silent);

      expect(await controller.panicWipe(), isTrue);

      // The wipe removes the saved posture, so the rebuilt phone starts Normal.
      expect(await PostureStore.load(store), Posture.normal);
    },
  );
}
