import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'noise_primitives.dart';

/// Noise_K_25519_ChaChaPoly_SHA256, used as a single write (pattern `-> e, es, ss`).
///
/// The initiator must already hold the responder's static key (from the roster); the
/// responder learns the initiator from the `ss` step. The message is one-way: there is
/// no reply and no handshake round trip.
///
/// Lost properties, compared with the XX session in `noise_xx.dart`:
///   - No forward secrecy. Compromise of the responder's static key opens every
///     message ever sealed to it.
///   - No sender identity beyond the initiator's static key. The envelope has no sender
///     field; the recipient learns the sender only by trying roster keys.
///   - No replay protection here. Replays are caught only by the envelope id in the DTN
///     store and by the delivered-once log.
const String noiseKProtocolName = 'Noise_K_25519_ChaChaPoly_SHA256';

/// Longest ciphertext (ephemeral key + AEAD body) a K message may carry.
const int noiseKMaxMessageLength = 512;

const int _ephemeralLength = noiseKeyLength;

/// Longest plaintext that fits [noiseKMaxMessageLength] after the ephemeral key and tag.
const int noiseKMaxPlaintextLength =
    noiseKMaxMessageLength - _ephemeralLength - noiseTagLength;

/// One-way K encryption. Stateless; each call is independent.
class NoiseK {
  const NoiseK._();

  /// Seals [plaintext] from [initiatorStatic] to [responderStaticPublic].
  ///
  /// [prologue] is mixed into the hash before any key, so the caller can bind header
  /// fields to the ciphertext. [ephemeral] is for test vectors only; leave it null.
  static Future<Uint8List> seal({
    required SimpleKeyPair initiatorStatic,
    required Uint8List responderStaticPublic,
    required Uint8List prologue,
    required List<int> plaintext,
    SimpleKeyPair? ephemeral,
  }) async {
    if (plaintext.length > noiseKMaxPlaintextLength) {
      throw ArgumentError.value(
        plaintext.length,
        'plaintext',
        'exceeds $noiseKMaxPlaintextLength bytes',
      );
    }
    final initiatorPublic = await _publicKeyOf(initiatorStatic);
    final symmetric = await _start(
      prologue,
      initiatorPublic,
      responderStaticPublic,
    );

    final e = ephemeral ?? await X25519().newKeyPair();
    final ePublic = await _publicKeyOf(e);
    await symmetric.mixHash(ePublic); // e
    await symmetric.mixKey(await _dh(e, responderStaticPublic)); // es
    await symmetric.mixKey(
      await _dh(initiatorStatic, responderStaticPublic),
    ); // ss
    final body = await symmetric.encryptAndHash(plaintext);
    return Uint8List.fromList([...ePublic, ...body]);
  }

  /// Opens a message sealed to [responderStatic] by [initiatorStaticPublic].
  ///
  /// Throws [NoiseException] for wrong length, wrong keys, a changed prologue, or any
  /// flipped bit. Nothing is returned unless the AEAD tag verifies.
  static Future<Uint8List> open({
    required SimpleKeyPair responderStatic,
    required Uint8List initiatorStaticPublic,
    required Uint8List prologue,
    required Uint8List message,
  }) async {
    if (message.length < _ephemeralLength + noiseTagLength ||
        message.length > noiseKMaxMessageLength) {
      throw const NoiseException('K message length out of range');
    }
    final responderPublic = await _publicKeyOf(responderStatic);
    final symmetric = await _start(
      prologue,
      initiatorStaticPublic,
      responderPublic,
    );

    final remoteEphemeral = Uint8List.fromList(
      message.sublist(0, _ephemeralLength),
    );
    await symmetric.mixHash(remoteEphemeral); // e
    await symmetric.mixKey(await _dh(responderStatic, remoteEphemeral)); // es
    await symmetric.mixKey(
      await _dh(responderStatic, initiatorStaticPublic),
    ); // ss
    return symmetric.decryptAndHash(message.sublist(_ephemeralLength));
  }

  /// Shared start: protocol name, prologue, then the pre-messages `-> s` and `<- s`.
  static Future<NoiseSymmetricState> _start(
    Uint8List prologue,
    Uint8List initiatorPublic,
    Uint8List responderPublic,
  ) async {
    final symmetric = await NoiseSymmetricState.start(noiseKProtocolName);
    await symmetric.mixHash(prologue);
    await symmetric.mixHash(initiatorPublic);
    await symmetric.mixHash(responderPublic);
    return symmetric;
  }

  static Future<Uint8List> _publicKeyOf(SimpleKeyPair keyPair) async =>
      Uint8List.fromList((await keyPair.extractPublicKey()).bytes);

  static Future<Uint8List> _dh(
    SimpleKeyPair local,
    List<int> remotePublicKey,
  ) async {
    final secret = await X25519().sharedSecretKey(
      keyPair: local,
      remotePublicKey: SimplePublicKey(
        remotePublicKey,
        type: KeyPairType.x25519,
      ),
    );
    return Uint8List.fromList(await secret.extractBytes());
  }
}
