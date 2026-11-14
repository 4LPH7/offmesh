import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/app/secret_store.dart';
import 'package:offmesh/app/unit_store.dart';
import 'package:offmesh/core/provisioning/unit_roster.dart';

class _BadBase64Store extends MemorySecretStore {
  @override
  Future<Uint8List?> read(String key) async =>
      throw const FormatException('bad base64');
}

void main() {
  test('an empty store means unprovisioned', () async {
    expect(await UnitStore.load(MemorySecretStore()), isNull);
  });

  test('a saved unit loads back with secret and members', () async {
    final store = MemorySecretStore();
    final roster = UnitRoster(UnitStore.generateSecret(), [
      UnitMember(Uint8List(32), 'Alpha'),
    ]);

    await UnitStore.save(store, roster);
    final loaded = await UnitStore.load(store);

    expect(loaded!.unitSecret, roster.unitSecret);
    expect(loaded.members.single.name, 'Alpha');
  });

  test('a damaged stored unit throws and is left untouched', () async {
    final store = MemorySecretStore();
    final junk = Uint8List.fromList([1, 2, 3]);
    await store.write(unitKey, junk);

    await expectLater(
      UnitStore.load(store),
      throwsA(isA<UnitStoreException>()),
    );
    expect(await store.read(unitKey), junk);
    await expectLater(
      UnitStore.load(_BadBase64Store()),
      throwsA(isA<UnitStoreException>()),
    );
  });

  test('generated secrets are 32 bytes and differ', () {
    final a = UnitStore.generateSecret();
    expect(a, hasLength(unitSecretLength));
    expect(a, isNot(UnitStore.generateSecret()));
  });
}
