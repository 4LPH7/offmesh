import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/crypto/identity.dart';
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

Future<SimpleKeyPair> _keyPairFromSeed(String seedHex) =>
    X25519().newKeyPairFromSeed(_hex(seedHex));

Map<String, dynamic> _vector() {
  final file = File(
    'test/core/crypto/vectors/noise_xx_25519_chachapoly_sha256.json',
  );
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

Future<({NoiseHandshake initiator, NoiseHandshake responder})> _pair({
  Uint8List? expectedResponderPeerId,
}) async {
  final vector = _vector();
  final initiator = await NoiseHandshake.initiator(
    staticKeyPair: await _keyPairFromSeed(vector['init_static'] as String),
    ephemeralKeyPair: await _keyPairFromSeed(
      vector['init_ephemeral'] as String,
    ),
    prologue: _hex(vector['init_prologue'] as String),
    expectedResponderPeerId: expectedResponderPeerId,
  );
  final responder = await NoiseHandshake.responder(
    staticKeyPair: await _keyPairFromSeed(vector['resp_static'] as String),
    ephemeralKeyPair: await _keyPairFromSeed(
      vector['resp_ephemeral'] as String,
    ),
    prologue: _hex(vector['resp_prologue'] as String),
  );
  return (initiator: initiator, responder: responder);
}

/// Runs the three handshake messages on a fresh pair and returns it complete.
Future<({NoiseHandshake initiator, NoiseHandshake responder})> _completedPair({
  Uint8List? expectedResponderPeerId,
}) async {
  final pair = await _pair(expectedResponderPeerId: expectedResponderPeerId);
  final msg1 = await pair.initiator.writeMessage(Uint8List(0));
  await pair.responder.readMessage(msg1);
  final msg2 = await pair.responder.writeMessage(Uint8List(0));
  await pair.initiator.readMessage(msg2);
  final msg3 = await pair.initiator.writeMessage(Uint8List(0));
  await pair.responder.readMessage(msg3);
  return pair;
}

/// Runs the vector's handshake using the vector's own payloads, so keys match the vector.
Future<({NoiseHandshake initiator, NoiseHandshake responder})>
_vectorCompletedPair() async {
  final messages = (_vector()['messages'] as List).cast<Map<String, dynamic>>();
  final pair = await _pair();
  final writers = [pair.initiator, pair.responder, pair.initiator];
  final readers = [pair.responder, pair.initiator, pair.responder];
  for (var i = 0; i < 3; i++) {
    final wire = await writers[i].writeMessage(
      _hex(messages[i]['payload'] as String),
    );
    await readers[i].readMessage(wire);
  }
  return pair;
}

void main() {
  group('Noise XX known-answer vector (cacophony)', () {
    test('handshake messages match the published ciphertexts', () async {
      final messages = (_vector()['messages'] as List)
          .cast<Map<String, dynamic>>();
      final pair = await _pair();
      // Handshake messages 0..2: initiator, responder, initiator.
      final writers = [pair.initiator, pair.responder, pair.initiator];
      final readers = [pair.responder, pair.initiator, pair.responder];

      for (var i = 0; i < 3; i++) {
        final payload = _hex(messages[i]['payload'] as String);
        final wire = await writers[i].writeMessage(payload);
        expect(
          _toHex(wire),
          messages[i]['ciphertext'],
          reason: 'handshake message $i',
        );
        final received = await readers[i].readMessage(wire);
        expect(
          _toHex(received),
          messages[i]['payload'],
          reason: 'handshake payload $i',
        );
      }
    });

    test(
      'transport messages match the published ciphertexts in both directions',
      () async {
        final messages = (_vector()['messages'] as List)
            .cast<Map<String, dynamic>>();
        final pair = await _vectorCompletedPair();
        // The vector alternates strictly by index: even = initiator, odd = responder.
        for (var i = 3; i < 6; i++) {
          final sender = i.isEven ? pair.initiator : pair.responder;
          final receiver = i.isEven ? pair.responder : pair.initiator;
          final wire = await sender.session.encrypt(
            _hex(messages[i]['payload'] as String),
          );
          expect(
            _toHex(wire),
            messages[i]['ciphertext'],
            reason: 'transport message $i',
          );
          final plain = await receiver.session.decrypt(wire);
          expect(
            _toHex(plain),
            messages[i]['payload'],
            reason: 'transport payload $i',
          );
        }
      },
    );

    test('both sides end with the published handshake hash', () async {
      final expected = _vector()['handshake_hash'];
      final pair = await _vectorCompletedPair();

      expect(_toHex(pair.initiator.session.handshakeHash), expected);
      expect(_toHex(pair.responder.session.handshakeHash), expected);
    });
  });

  group('Noise XX security checks', () {
    test(
      'initiator rejects the responder when its static key is not the dialled PeerID',
      () async {
        final pair = await _pair(expectedResponderPeerId: Uint8List(8));
        final msg1 = await pair.initiator.writeMessage(Uint8List(0));
        await pair.responder.readMessage(msg1);
        final msg2 = await pair.responder.writeMessage(Uint8List(0));

        await expectLater(
          pair.initiator.readMessage(msg2),
          throwsA(isA<NoiseException>()),
        );
      },
    );

    test(
      'initiator accepts the responder when the dialled PeerID matches',
      () async {
        final responderPublic = await (await _keyPairFromSeed(
          _vector()['resp_static'] as String,
        )).extractPublicKey();
        final expected = await peerIdFor(responderPublic.bytes);
        final pair = await _pair(expectedResponderPeerId: expected);
        final msg1 = await pair.initiator.writeMessage(Uint8List(0));
        await pair.responder.readMessage(msg1);
        final msg2 = await pair.responder.writeMessage(Uint8List(0));

        await expectLater(pair.initiator.readMessage(msg2), completes);
      },
    );

    test('a tampered handshake message fails to authenticate', () async {
      final pair = await _pair();
      final msg1 = await pair.initiator.writeMessage(Uint8List(0));
      await pair.responder.readMessage(msg1);
      final msg2 = await pair.responder.writeMessage(Uint8List(0));
      msg2[msg2.length - 1] ^= 0x01;

      await expectLater(
        pair.initiator.readMessage(msg2),
        throwsA(isA<NoiseException>()),
      );
    });

    test(
      'a truncated handshake message is rejected, not read out of bounds',
      () async {
        final pair = await _pair();

        await expectLater(
          pair.responder.readMessage(Uint8List(10)),
          throwsA(isA<NoiseException>()),
        );
      },
    );

    test('the session is unavailable before the handshake completes', () async {
      final pair = await _pair();

      expect(() => pair.initiator.session, throwsA(isA<NoiseException>()));
    });

    test('a transport ciphertext cannot be replayed', () async {
      final pair = await _completedPair();
      final wire = await pair.initiator.session.encrypt(
        Uint8List.fromList([1, 2, 3]),
      );
      await pair.responder.session.decrypt(wire);

      await expectLater(
        pair.responder.session.decrypt(wire),
        throwsA(isA<NoiseException>()),
      );
    });
  });

  group('Identity', () {
    test(
      'PeerID is the first 8 bytes of SHA-256 of the static public key',
      () async {
        final identity = await Identity.generate();
        final digest = await Sha256().hash(identity.publicKey);

        expect(identity.peerId, digest.bytes.sublist(0, 8));
        expect(identity.peerId.length, 8);
      },
    );

    test('the same key always yields the same PeerID', () async {
      final keyPair = await _keyPairFromSeed(
        _vector()['init_static'] as String,
      );
      final a = await Identity.fromKeyPair(keyPair);
      final b = await Identity.fromKeyPair(keyPair);

      expect(a.peerId, b.peerId);
    });

    test('two generated identities have different PeerIDs', () async {
      final a = await Identity.generate();
      final b = await Identity.generate();

      expect(a.peerId, isNot(b.peerId));
    });
  });
}
