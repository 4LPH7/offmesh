import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Noise building blocks shared by the XX handshake and the one-way K pattern:
/// CipherState, SymmetricState, HKDF and the transport counter limit.
const int noiseKeyLength = 32;
const int noiseTagLength = 16;

/// Refuse to use a transport session past this many messages (nonce safety ceiling).
const int maxSessionMessages = 1 << 32;

class NoiseException implements Exception {
  const NoiseException(this.message);

  final String message;

  @override
  String toString() => 'NoiseException: $message';
}

Future<Uint8List> noiseSha256(List<int> data) async =>
    Uint8List.fromList((await Sha256().hash(data)).bytes);

Future<Uint8List> noiseHmac(List<int> key, List<int> data) async {
  final mac = await Hmac.sha256().calculateMac(data, secretKey: SecretKey(key));
  return Uint8List.fromList(mac.bytes);
}

/// Noise HKDF with two outputs (HMAC-based, as the spec defines it).
Future<(Uint8List, Uint8List)> noiseHkdf2(
  List<int> chainingKey,
  List<int> inputKeyMaterial,
) async {
  final temp = await noiseHmac(chainingKey, inputKeyMaterial);
  final out1 = await noiseHmac(temp, const [0x01]);
  final out2 = await noiseHmac(temp, [...out1, 0x02]);
  return (out1, out2);
}

Uint8List noiseNonceBytes(int counter) {
  final data = ByteData(12);
  data.setUint32(4, counter & 0xFFFFFFFF, Endian.little);
  data.setUint32(8, counter >> 32, Endian.little);
  return data.buffer.asUint8List();
}

/// One direction of transport encryption. Empty key means "no encryption yet".
class NoiseCipherState {
  NoiseCipherState([this._key]);

  final SecretKey? _key;
  int _nonce = 0;

  /// Reserves the next counter. Each counter is used for one encryption under this key.
  int takeCounter() {
    if (_nonce >= maxSessionMessages) {
      throw const NoiseException('session message limit reached; re-handshake');
    }
    return _nonce++;
  }

  Future<Uint8List> encrypt(List<int> associatedData, List<int> plaintext) =>
      encryptAt(takeCounter(), associatedData, plaintext);

  /// Encrypts under an explicit [counter]. The caller must never reuse one.
  Future<Uint8List> encryptAt(
    int counter,
    List<int> associatedData,
    List<int> plaintext,
  ) async {
    final key = _key;
    if (key == null) return Uint8List.fromList(plaintext);
    final box = await noiseAead.encrypt(
      plaintext,
      secretKey: key,
      nonce: noiseNonceBytes(counter),
      aad: associatedData,
    );
    return Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
  }

  /// Decrypts with the next implicit counter. The counter advances only on success.
  Future<Uint8List> decrypt(
    List<int> associatedData,
    List<int> ciphertext,
  ) async {
    final counter = _nonce;
    final plaintext = await decryptAt(counter, associatedData, ciphertext);
    _nonce = counter + 1;
    return plaintext;
  }

  /// Authenticates [ciphertext] under an explicit [counter]. Keeps no state.
  Future<Uint8List> decryptAt(
    int counter,
    List<int> associatedData,
    List<int> ciphertext,
  ) async {
    final key = _key;
    if (key == null) return Uint8List.fromList(ciphertext);
    if (ciphertext.length < noiseTagLength) {
      throw const NoiseException('ciphertext shorter than the auth tag');
    }
    final split = ciphertext.length - noiseTagLength;
    final box = SecretBox(
      ciphertext.sublist(0, split),
      nonce: noiseNonceBytes(counter),
      mac: Mac(ciphertext.sublist(split)),
    );
    try {
      return Uint8List.fromList(
        await noiseAead.decrypt(box, secretKey: key, aad: associatedData),
      );
    } on SecretBoxAuthenticationError {
      throw const NoiseException('message failed authentication');
    }
  }
}

final Chacha20 noiseAead = Chacha20.poly1305Aead();

class NoiseSymmetricState {
  NoiseSymmetricState._(this._handshakeHash, this._chainingKey);

  Uint8List _handshakeHash;
  Uint8List _chainingKey;
  NoiseCipherState _cipher = NoiseCipherState();

  static Future<NoiseSymmetricState> start(String protocolName) async {
    final name = utf8.encode(protocolName);
    final hash = name.length <= noiseKeyLength
        ? Uint8List.fromList([
            ...name,
            ...List.filled(noiseKeyLength - name.length, 0),
          ])
        : await noiseSha256(name);
    return NoiseSymmetricState._(hash, Uint8List.fromList(hash));
  }

  Future<void> mixHash(List<int> data) async {
    _handshakeHash = await noiseSha256([..._handshakeHash, ...data]);
  }

  Future<void> mixKey(List<int> inputKeyMaterial) async {
    final (chaining, key) = await noiseHkdf2(_chainingKey, inputKeyMaterial);
    _chainingKey = chaining;
    _cipher = NoiseCipherState(SecretKey(key.sublist(0, noiseKeyLength)));
  }

  Future<Uint8List> encryptAndHash(List<int> plaintext) async {
    final ciphertext = await _cipher.encrypt(_handshakeHash, plaintext);
    await mixHash(ciphertext);
    return ciphertext;
  }

  Future<Uint8List> decryptAndHash(List<int> ciphertext) async {
    final plaintext = await _cipher.decrypt(_handshakeHash, ciphertext);
    await mixHash(ciphertext);
    return plaintext;
  }

  /// Returns (initiator-to-responder, responder-to-initiator) cipher states.
  Future<(NoiseCipherState, NoiseCipherState)> split() async {
    final (first, second) = await noiseHkdf2(_chainingKey, const []);
    return (
      NoiseCipherState(SecretKey(first.sublist(0, noiseKeyLength))),
      NoiseCipherState(SecretKey(second.sublist(0, noiseKeyLength))),
    );
  }

  Uint8List get handshakeHash => _handshakeHash;
}
