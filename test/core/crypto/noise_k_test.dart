import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/crypto/noise_k.dart';
import 'package:offmesh/core/crypto/noise_xx.dart';

Uint8List _hex(String text) {
  final out = Uint8List(text.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(text.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Future<SimplePublicKey> _publicOf(SimpleKeyPair pair) =>
    pair.extractPublicKey();

void main() {
  // Vectors: trevp/screech vectors.txt, Noise_K_25519_ChaChaPoly_SHA256, msg_0.
  // The cabinetos/noise-vectors.txt empty-payload case shares the same ephemeral and
  // confirms the first 32 ciphertext bytes independently.
  group('Noise K vectors', () {
    test(
      'screech msg_0 with payload "test_msg_0" matches byte for byte',
      () async {
        final initiator = await X25519().newKeyPairFromSeed(
          _hex(
            '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
          ),
        );
        final responder = await X25519().newKeyPairFromSeed(
          _hex(
            '0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20',
          ),
        );
        final ephemeral = await X25519().newKeyPairFromSeed(
          _hex(
            '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f',
          ),
        );
        final responderPublic = Uint8List.fromList(
          (await _publicOf(responder)).bytes,
        );

        final sealed = await NoiseK.seal(
          initiatorStatic: initiator,
          responderStaticPublic: responderPublic,
          prologue: Uint8List(0),
          plaintext: _hex('746573745f6d73675f30'),
          ephemeral: ephemeral,
        );

        expect(
          _toHex(sealed),
          '358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254'
          'b8cae311a5f3367e2170caf5c7ae0947b49ced8a3b7a99f10460',
        );
      },
    );

    test('cabinetos msg_0 with empty payload matches byte for byte', () async {
      final initiator = await X25519().newKeyPairFromSeed(
        _hex(
          '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
        ),
      );
      final responder = await X25519().newKeyPairFromSeed(
        _hex(
          '0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20',
        ),
      );
      final ephemeral = await X25519().newKeyPairFromSeed(
        _hex(
          '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f',
        ),
      );

      final sealed = await NoiseK.seal(
        initiatorStatic: initiator,
        responderStaticPublic: Uint8List.fromList(
          (await _publicOf(responder)).bytes,
        ),
        prologue: Uint8List(0),
        plaintext: const [],
        ephemeral: ephemeral,
      );

      expect(
        _toHex(sealed),
        '358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254'
        'af724161ce8037f690f587990caba741',
      );
    });
  });

  group('Noise K round trip and failures', () {
    late SimpleKeyPair initiator;
    late SimpleKeyPair responder;
    late Uint8List initiatorPublic;
    late Uint8List responderPublic;
    final prologue = Uint8List.fromList([1, 2, 3]);
    final plaintext = Uint8List.fromList('meet at the bridge 14:00'.codeUnits);

    setUp(() async {
      initiator = await X25519().newKeyPair();
      responder = await X25519().newKeyPair();
      initiatorPublic = Uint8List.fromList((await _publicOf(initiator)).bytes);
      responderPublic = Uint8List.fromList((await _publicOf(responder)).bytes);
    });

    Future<Uint8List> sealIt({Uint8List? pro}) => NoiseK.seal(
      initiatorStatic: initiator,
      responderStaticPublic: responderPublic,
      prologue: pro ?? prologue,
      plaintext: plaintext,
    );

    test('opens with the right keys and prologue', () async {
      final message = await sealIt();
      final opened = await NoiseK.open(
        responderStatic: responder,
        initiatorStaticPublic: initiatorPublic,
        prologue: prologue,
        message: message,
      );
      expect(opened, plaintext);
    });

    test('plaintext does not appear on the wire', () async {
      final message = await sealIt();
      expect(_toHex(message).contains(_toHex(plaintext)), isFalse);
    });

    test('wrong responder key fails', () async {
      final message = await sealIt();
      final other = await X25519().newKeyPair();
      expect(
        () => NoiseK.open(
          responderStatic: other,
          initiatorStaticPublic: initiatorPublic,
          prologue: prologue,
          message: message,
        ),
        throwsA(isA<NoiseException>()),
      );
    });

    test('wrong claimed sender fails', () async {
      final message = await sealIt();
      final impostor = Uint8List.fromList(
        (await _publicOf(await X25519().newKeyPair())).bytes,
      );
      expect(
        () => NoiseK.open(
          responderStatic: responder,
          initiatorStaticPublic: impostor,
          prologue: prologue,
          message: message,
        ),
        throwsA(isA<NoiseException>()),
      );
    });

    test('changed prologue fails', () async {
      final message = await sealIt();
      expect(
        () => NoiseK.open(
          responderStatic: responder,
          initiatorStaticPublic: initiatorPublic,
          prologue: Uint8List.fromList([1, 2, 4]),
          message: message,
        ),
        throwsA(isA<NoiseException>()),
      );
    });

    test('every flipped byte fails authentication', () async {
      final message = await sealIt();
      for (var i = 0; i < message.length; i++) {
        final tampered = Uint8List.fromList(message)..[i] ^= 0x01;
        await expectLater(
          NoiseK.open(
            responderStatic: responder,
            initiatorStaticPublic: initiatorPublic,
            prologue: prologue,
            message: tampered,
          ),
          throwsA(isA<NoiseException>()),
          reason: 'byte $i',
        );
      }
    });

    test('plaintext limit is enforced on both sides', () async {
      final atLimit = Uint8List(noiseKMaxPlaintextLength);
      final sealed = await NoiseK.seal(
        initiatorStatic: initiator,
        responderStaticPublic: responderPublic,
        prologue: prologue,
        plaintext: atLimit,
      );
      expect(sealed.length, noiseKMaxMessageLength);

      await expectLater(
        NoiseK.seal(
          initiatorStatic: initiator,
          responderStaticPublic: responderPublic,
          prologue: prologue,
          plaintext: Uint8List(noiseKMaxPlaintextLength + 1),
        ),
        throwsArgumentError,
      );
      await expectLater(
        NoiseK.open(
          responderStatic: responder,
          initiatorStaticPublic: initiatorPublic,
          prologue: prologue,
          message: Uint8List(noiseKMaxMessageLength + 1),
        ),
        throwsA(isA<NoiseException>()),
      );
    });
  });
}
