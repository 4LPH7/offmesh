import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Unit key length (ChaCha20-Poly1305 key).
const int sealKeyLength = 32;

/// Random nonce prepended to every sealed frame.
const int sealNonceLength = 12;

/// Poly1305 tag appended to every sealed frame.
const int sealTagLength = 16;

/// Bytes a sealed frame adds on top of its plaintext.
const int sealOverhead = sealNonceLength + sealTagLength;

/// Associated data binding every sealed frame to this protocol and version.
final Uint8List _domainLabel = Uint8List.fromList(
  utf8.encode('offmesh/seal/v1'),
);

final Chacha20 _aead = Chacha20.poly1305Aead();

/// Thrown when a frame cannot be opened; callers drop the frame.
class SealedEnvelopeException implements Exception {
  const SealedEnvelopeException(this.message);

  final String message;

  @override
  String toString() => 'SealedEnvelopeException: $message';
}

/// Seals whole wire frames (header and payload) under the shared unit key.
///
/// Frame layout: nonce(12) || ciphertext || tag(16).
// ponytail: random 96-bit nonces; rotate the unit key before 2^32 frames
// (NIST SP 800-38D bound) to keep nonce-collision odds below 2^-32.
class SealedEnvelope {
  /// [nonceSource] is for tests only; production uses a secure RNG.
  SealedEnvelope(List<int> unitKey, {List<int> Function()? nonceSource})
    : _key = SecretKey(Uint8List.fromList(_checkedKey(unitKey))),
      _nonceSource = nonceSource ?? _secureNonce;

  final SecretKey _key;
  final List<int> Function() _nonceSource;

  static List<int> _checkedKey(List<int> key) {
    if (key.length != sealKeyLength) {
      throw ArgumentError.value(
        key.length,
        'unitKey',
        'must be $sealKeyLength bytes',
      );
    }
    return key;
  }

  static final Random _random = Random.secure();

  static List<int> _secureNonce() =>
      List<int>.generate(sealNonceLength, (_) => _random.nextInt(256));

  Future<Uint8List> seal(List<int> plaintext) async {
    final nonce = _nonceSource();
    if (nonce.length != sealNonceLength) {
      throw StateError('nonce source must return $sealNonceLength bytes');
    }
    final box = await _aead.encrypt(
      plaintext,
      secretKey: _key,
      nonce: nonce,
      aad: _domainLabel,
    );
    return Uint8List.fromList([...nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  /// Returns the plaintext, or throws [SealedEnvelopeException].
  Future<Uint8List> open(List<int> frame) async {
    if (frame.length < sealOverhead) {
      throw const SealedEnvelopeException('frame shorter than seal overhead');
    }
    final tagStart = frame.length - sealTagLength;
    final box = SecretBox(
      frame.sublist(sealNonceLength, tagStart),
      nonce: frame.sublist(0, sealNonceLength),
      mac: Mac(frame.sublist(tagStart)),
    );
    try {
      return Uint8List.fromList(
        await _aead.decrypt(box, secretKey: _key, aad: _domainLabel),
      );
    } on SecretBoxAuthenticationError {
      throw const SealedEnvelopeException('frame failed authentication');
    }
  }
}
