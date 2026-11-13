import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'identity.dart';

/// Noise_XX_25519_ChaChaPoly_SHA256: mutual authentication, forward secrecy,
/// neither side knows the other's static key beforehand.
const String noiseProtocolName = 'Noise_XX_25519_ChaChaPoly_SHA256';

const int _keyLength = 32;
const int _tagLength = 16;
const int _encryptedStaticLength = _keyLength + _tagLength;

/// Refuse to use a transport session past this many messages (nonce safety ceiling).
const int maxSessionMessages = 1 << 32;

class NoiseException implements Exception {
  const NoiseException(this.message);

  final String message;

  @override
  String toString() => 'NoiseException: $message';
}

Future<Uint8List> _sha256(List<int> data) async =>
    Uint8List.fromList((await Sha256().hash(data)).bytes);

Future<Uint8List> _hmac(List<int> key, List<int> data) async {
  final mac = await Hmac.sha256().calculateMac(data, secretKey: SecretKey(key));
  return Uint8List.fromList(mac.bytes);
}

/// Noise HKDF with two outputs (HMAC-based, as the spec defines it).
Future<(Uint8List, Uint8List)> _hkdf2(
  List<int> chainingKey,
  List<int> inputKeyMaterial,
) async {
  final temp = await _hmac(chainingKey, inputKeyMaterial);
  final out1 = await _hmac(temp, const [0x01]);
  final out2 = await _hmac(temp, [...out1, 0x02]);
  return (out1, out2);
}

Uint8List _nonceBytes(int counter) {
  final data = ByteData(12);
  data.setUint32(4, counter & 0xFFFFFFFF, Endian.little);
  data.setUint32(8, counter >> 32, Endian.little);
  return data.buffer.asUint8List();
}

/// One direction of transport encryption. Empty key means "no encryption yet".
class _CipherState {
  _CipherState([this._key]);

  final SecretKey? _key;
  int _nonce = 0;

  Future<Uint8List> encrypt(
    List<int> associatedData,
    List<int> plaintext,
  ) async {
    final key = _key;
    if (key == null) return Uint8List.fromList(plaintext);
    final box = await _aead.encrypt(
      plaintext,
      secretKey: key,
      nonce: _nextNonce(),
      aad: associatedData,
    );
    return Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
  }

  Future<Uint8List> decrypt(
    List<int> associatedData,
    List<int> ciphertext,
  ) async {
    final key = _key;
    if (key == null) return Uint8List.fromList(ciphertext);
    if (ciphertext.length < _tagLength) {
      throw const NoiseException('ciphertext shorter than the auth tag');
    }
    final split = ciphertext.length - _tagLength;
    final box = SecretBox(
      ciphertext.sublist(0, split),
      nonce: _nextNonce(),
      mac: Mac(ciphertext.sublist(split)),
    );
    try {
      return Uint8List.fromList(
        await _aead.decrypt(box, secretKey: key, aad: associatedData),
      );
    } on SecretBoxAuthenticationError {
      throw const NoiseException('message failed authentication');
    }
  }

  List<int> _nextNonce() {
    if (_nonce >= maxSessionMessages) {
      throw const NoiseException('session message limit reached; re-handshake');
    }
    return _nonceBytes(_nonce++);
  }
}

final Chacha20 _aead = Chacha20.poly1305Aead();

class _SymmetricState {
  _SymmetricState._(this._handshakeHash, this._chainingKey);

  Uint8List _handshakeHash;
  Uint8List _chainingKey;
  _CipherState _cipher = _CipherState();

  static Future<_SymmetricState> start() async {
    final name = utf8.encode(noiseProtocolName);
    final hash = name.length <= _keyLength
        ? Uint8List.fromList([
            ...name,
            ...List.filled(_keyLength - name.length, 0),
          ])
        : await _sha256(name);
    return _SymmetricState._(hash, Uint8List.fromList(hash));
  }

  Future<void> mixHash(List<int> data) async {
    _handshakeHash = await _sha256([..._handshakeHash, ...data]);
  }

  Future<void> mixKey(List<int> inputKeyMaterial) async {
    final (chaining, key) = await _hkdf2(_chainingKey, inputKeyMaterial);
    _chainingKey = chaining;
    _cipher = _CipherState(SecretKey(key.sublist(0, _keyLength)));
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
  Future<(_CipherState, _CipherState)> split() async {
    final (first, second) = await _hkdf2(_chainingKey, const []);
    return (
      _CipherState(SecretKey(first.sublist(0, _keyLength))),
      _CipherState(SecretKey(second.sublist(0, _keyLength))),
    );
  }

  Uint8List get handshakeHash => _handshakeHash;
}

/// Post-handshake encrypted channel to one peer.
class NoiseSession {
  NoiseSession._({
    required _CipherState send,
    required _CipherState receive,
    required this.handshakeHash,
    required this.remoteStaticPublicKey,
  }) : _send = send,
       _receive = receive;

  final _CipherState _send;
  final _CipherState _receive;
  final Uint8List handshakeHash;
  final Uint8List remoteStaticPublicKey;

  Future<Uint8List> encrypt(List<int> plaintext) =>
      _send.encrypt(const [], plaintext);

  Future<Uint8List> decrypt(List<int> ciphertext) =>
      _receive.decrypt(const [], ciphertext);
}

enum _Role { initiator, responder }

/// One side of the three-message XX handshake.
///
///   -> e
///   <- e, ee, s, es
///   -> s, se
class NoiseHandshake {
  NoiseHandshake._({
    required _Role role,
    required SimpleKeyPair staticKeyPair,
    required Uint8List staticPublicKey,
    required SimpleKeyPair? ephemeralKeyPair,
    required _SymmetricState symmetric,
    required Uint8List? expectedResponderPeerId,
  }) : _role = role,
       _staticKeyPair = staticKeyPair,
       _staticPublicKey = staticPublicKey,
       _ephemeralKeyPair = ephemeralKeyPair,
       _symmetric = symmetric,
       _expectedResponderPeerId = expectedResponderPeerId;

  final _Role _role;
  final SimpleKeyPair _staticKeyPair;
  final Uint8List _staticPublicKey;
  SimpleKeyPair? _ephemeralKeyPair;
  final _SymmetricState _symmetric;
  final Uint8List? _expectedResponderPeerId;

  Uint8List? _remoteEphemeral;
  Uint8List? _remoteStatic;
  NoiseSession? _session;
  int _step = 0;

  /// Dial a peer. [expectedResponderPeerId] (if given) must match the responder's
  /// static key; it is checked right after message 2, before we reveal our own key.
  /// [ephemeralKeyPair] is for test vectors only; leave it null in production.
  static Future<NoiseHandshake> initiator({
    required SimpleKeyPair staticKeyPair,
    required Uint8List prologue,
    SimpleKeyPair? ephemeralKeyPair,
    Uint8List? expectedResponderPeerId,
  }) async {
    return _create(
      role: _Role.initiator,
      staticKeyPair: staticKeyPair,
      prologue: prologue,
      ephemeralKeyPair: ephemeralKeyPair,
      expectedResponderPeerId: expectedResponderPeerId,
    );
  }

  static Future<NoiseHandshake> responder({
    required SimpleKeyPair staticKeyPair,
    required Uint8List prologue,
    SimpleKeyPair? ephemeralKeyPair,
  }) async {
    return _create(
      role: _Role.responder,
      staticKeyPair: staticKeyPair,
      prologue: prologue,
      ephemeralKeyPair: ephemeralKeyPair,
      expectedResponderPeerId: null,
    );
  }

  static Future<NoiseHandshake> _create({
    required _Role role,
    required SimpleKeyPair staticKeyPair,
    required Uint8List prologue,
    required SimpleKeyPair? ephemeralKeyPair,
    required Uint8List? expectedResponderPeerId,
  }) async {
    final symmetric = await _SymmetricState.start();
    await symmetric.mixHash(prologue);
    final publicKey = Uint8List.fromList(
      (await staticKeyPair.extractPublicKey()).bytes,
    );
    return NoiseHandshake._(
      role: role,
      staticKeyPair: staticKeyPair,
      staticPublicKey: publicKey,
      ephemeralKeyPair: ephemeralKeyPair,
      symmetric: symmetric,
      expectedResponderPeerId: expectedResponderPeerId,
    );
  }

  bool get isComplete => _session != null;

  NoiseSession get session {
    final current = _session;
    if (current == null) throw const NoiseException('handshake not complete');
    return current;
  }

  /// Produces the next outgoing handshake message, carrying [payload] encrypted.
  Future<Uint8List> writeMessage(Uint8List payload) async {
    if (isComplete || _isInitiatorStep() != (_role == _Role.initiator)) {
      throw const NoiseException('not this side\'s turn to write');
    }
    final message = switch (_step) {
      0 => await _writeMessage1(payload),
      1 => await _writeMessage2(payload),
      _ => await _writeMessage3(payload),
    };
    _step++;
    return message;
  }

  /// Consumes the next incoming handshake message and returns its decrypted payload.
  Future<Uint8List> readMessage(Uint8List message) async {
    if (isComplete || _isInitiatorStep() == (_role == _Role.initiator)) {
      throw const NoiseException('not this side\'s turn to read');
    }
    final payload = switch (_step) {
      0 => await _readMessage1(message),
      1 => await _readMessage2(message),
      _ => await _readMessage3(message),
    };
    _step++;
    return payload;
  }

  /// Handshake messages 0 and 2 come from the initiator, message 1 from the responder.
  bool _isInitiatorStep() => _step.isEven;

  Future<Uint8List> _writeMessage1(Uint8List payload) async {
    final ephemeral = await _ensureEphemeral();
    final ephemeralPublic = await _publicKeyOf(ephemeral);
    await _symmetric.mixHash(ephemeralPublic);
    final encryptedPayload = await _symmetric.encryptAndHash(payload);
    return Uint8List.fromList([...ephemeralPublic, ...encryptedPayload]);
  }

  Future<Uint8List> _readMessage1(Uint8List message) async {
    _requireLength(message, _keyLength);
    _remoteEphemeral = Uint8List.fromList(message.sublist(0, _keyLength));
    await _symmetric.mixHash(_remoteEphemeral!);
    return _symmetric.decryptAndHash(message.sublist(_keyLength));
  }

  Future<Uint8List> _writeMessage2(Uint8List payload) async {
    final ephemeral = await _ensureEphemeral();
    final ephemeralPublic = await _publicKeyOf(ephemeral);
    await _symmetric.mixHash(ephemeralPublic);
    await _symmetric.mixKey(await _dh(ephemeral, _remoteEphemeral!)); // ee
    final encryptedStatic = await _symmetric.encryptAndHash(
      _staticPublicKey,
    ); // s
    await _symmetric.mixKey(await _dh(_staticKeyPair, _remoteEphemeral!)); // es
    final encryptedPayload = await _symmetric.encryptAndHash(payload);
    return Uint8List.fromList([
      ...ephemeralPublic,
      ...encryptedStatic,
      ...encryptedPayload,
    ]);
  }

  Future<Uint8List> _readMessage2(Uint8List message) async {
    _requireLength(message, _keyLength + _encryptedStaticLength);
    final ephemeral = await _ensureEphemeral();
    _remoteEphemeral = Uint8List.fromList(message.sublist(0, _keyLength));
    await _symmetric.mixHash(_remoteEphemeral!);
    await _symmetric.mixKey(await _dh(ephemeral, _remoteEphemeral!)); // ee
    final remoteStatic = await _symmetric.decryptAndHash(
      message.sublist(_keyLength, _keyLength + _encryptedStaticLength),
    );
    _remoteStatic = remoteStatic;
    await _checkResponderPeerId(remoteStatic);
    await _symmetric.mixKey(await _dh(ephemeral, remoteStatic)); // es
    return _symmetric.decryptAndHash(
      message.sublist(_keyLength + _encryptedStaticLength),
    );
  }

  Future<Uint8List> _writeMessage3(Uint8List payload) async {
    final encryptedStatic = await _symmetric.encryptAndHash(
      _staticPublicKey,
    ); // s
    await _symmetric.mixKey(await _dh(_staticKeyPair, _remoteEphemeral!)); // se
    final encryptedPayload = await _symmetric.encryptAndHash(payload);
    await _finishHandshake();
    return Uint8List.fromList([...encryptedStatic, ...encryptedPayload]);
  }

  Future<Uint8List> _readMessage3(Uint8List message) async {
    _requireLength(message, _encryptedStaticLength);
    final remoteStatic = await _symmetric.decryptAndHash(
      message.sublist(0, _encryptedStaticLength),
    );
    _remoteStatic = remoteStatic;
    await _symmetric.mixKey(
      await _dh(_ensureEphemeralSync(), remoteStatic),
    ); // se
    final payload = await _symmetric.decryptAndHash(
      message.sublist(_encryptedStaticLength),
    );
    await _finishHandshake();
    return payload;
  }

  Future<void> _finishHandshake() async {
    final (first, second) = await _symmetric.split();
    final isInitiator = _role == _Role.initiator;
    _session = NoiseSession._(
      send: isInitiator ? first : second,
      receive: isInitiator ? second : first,
      handshakeHash: Uint8List.fromList(_symmetric.handshakeHash),
      remoteStaticPublicKey: _remoteStatic!,
    );
  }

  Future<void> _checkResponderPeerId(Uint8List responderStatic) async {
    final expected = _expectedResponderPeerId;
    if (expected == null) return;
    final actual = await peerIdFor(responderStatic);
    if (!_bytesEqual(actual, expected)) {
      throw const NoiseException(
        'responder identity does not match the dialled PeerID',
      );
    }
  }

  Future<SimpleKeyPair> _ensureEphemeral() async {
    final existing = _ephemeralKeyPair;
    if (existing != null) return existing;
    final generated = await X25519().newKeyPair();
    _ephemeralKeyPair = generated;
    return generated;
  }

  SimpleKeyPair _ensureEphemeralSync() {
    final existing = _ephemeralKeyPair;
    if (existing == null) throw const NoiseException('missing ephemeral key');
    return existing;
  }

  Future<Uint8List> _publicKeyOf(SimpleKeyPair keyPair) async =>
      Uint8List.fromList((await keyPair.extractPublicKey()).bytes);

  Future<Uint8List> _dh(SimpleKeyPair local, List<int> remotePublicKey) async {
    final secret = await X25519().sharedSecretKey(
      keyPair: local,
      remotePublicKey: SimplePublicKey(
        remotePublicKey,
        type: KeyPairType.x25519,
      ),
    );
    return Uint8List.fromList(await secret.extractBytes());
  }

  static void _requireLength(Uint8List message, int minimum) {
    if (message.length < minimum) {
      throw const NoiseException('handshake message too short');
    }
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
