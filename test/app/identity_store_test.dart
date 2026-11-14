import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/app/identity_store.dart';
import 'package:offmesh/app/secret_store.dart';
import 'package:offmesh/core/crypto/identity.dart';
import 'package:offmesh/core/crypto/noise_xx.dart';

void main() {
  test('a second load returns the same identity', () async {
    final store = MemorySecretStore();
    final first = await IdentityStore.loadOrCreate(store);
    final second = await IdentityStore.loadOrCreate(store);

    expect(second.peerId, first.peerId);
    expect(second.publicKey, first.publicKey);
  });

  test('a fresh store gives a different identity', () async {
    final a = await IdentityStore.loadOrCreate(MemorySecretStore());
    final b = await IdentityStore.loadOrCreate(MemorySecretStore());

    expect(a.peerId, isNot(b.peerId));
  });

  for (final length in [0, 31, 33]) {
    test('a $length-byte stored value throws and is not overwritten', () async {
      final store = MemorySecretStore();
      final bad = Uint8List.fromList(List.filled(length, 7));
      await store.write(identityKey, bad);

      await expectLater(
        IdentityStore.loadOrCreate(store),
        throwsA(isA<IdentityStoreException>()),
      );
      expect(await store.read(identityKey), bad);
    });
  }

  test('a non-base64 platform value throws IdentityStoreException', () async {
    await expectLater(
      IdentityStore.loadOrCreate(_BadBase64Store()),
      throwsA(isA<IdentityStoreException>()),
    );
  });

  test('a failed first write propagates', () async {
    await expectLater(
      IdentityStore.loadOrCreate(_FailingWriteStore()),
      throwsA(isA<StateError>()),
    );
  });

  test('fromPrivateKey rejects a wrong-length seed', () async {
    await expectLater(
      Identity.fromPrivateKey(List.filled(31, 1)),
      throwsArgumentError,
    );
  });

  test('the reloaded identity completes a Noise XX handshake', () async {
    final store = MemorySecretStore();
    await IdentityStore.loadOrCreate(store);
    final reloaded = await IdentityStore.loadOrCreate(store);
    final peer = await Identity.generate();
    final prologue = Uint8List.fromList(utf8.encode('offmesh-test'));

    final initiator = await NoiseHandshake.initiator(
      staticKeyPair: peer.keyPair,
      prologue: prologue,
      expectedResponderPeerId: reloaded.peerId,
    );
    final responder = await NoiseHandshake.responder(
      staticKeyPair: reloaded.keyPair,
      prologue: prologue,
    );
    await responder.readMessage(await initiator.writeMessage(Uint8List(0)));
    await initiator.readMessage(await responder.writeMessage(Uint8List(0)));
    await responder.readMessage(await initiator.writeMessage(Uint8List(0)));

    expect(initiator.session.remoteStaticPublicKey, reloaded.publicKey);
    final frame = await responder.session.encrypt(utf8.encode('hi'));
    expect(utf8.decode(await initiator.session.decrypt(frame)), 'hi');
  });
}

class _BadBase64Store extends MemorySecretStore {
  @override
  Future<Uint8List?> read(String key) async => base64Decode('not base64!');
}

class _FailingWriteStore extends MemorySecretStore {
  @override
  Future<void> write(String key, Uint8List value) async =>
      throw StateError('write failed');
}
