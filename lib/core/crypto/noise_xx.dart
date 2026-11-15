import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'identity.dart';
import 'replay_window.dart';
import 'noise_primitives.dart';

export 'noise_primitives.dart' show NoiseException, maxSessionMessages;

/// Explicit transport counter that prefixes every transport frame.
const int _counterLength = 8;

/// Noise_XX_25519_ChaChaPoly_SHA256: mutual authentication, forward secrecy,
/// neither side knows the other's static key beforehand.
const String noiseProtocolName = 'Noise_XX_25519_ChaChaPoly_SHA256';

const int _encryptedStaticLength = noiseKeyLength + noiseTagLength;

/// Post-handshake encrypted channel to one peer.
///
/// Transport frames are `counter(8, big-endian) || ciphertext || tag`. The counter travels
/// in the clear, so a frame can be decrypted when earlier frames were lost or reordered.
/// Authenticated data is bound to the frame: a frame opens only with the same bytes that
/// were passed to [encrypt]. A frame that fails authentication changes no receive state.
class NoiseSession {
  NoiseSession._({
    required NoiseCipherState send,
    required NoiseCipherState receive,
    required this.handshakeHash,
    required this.remoteStaticPublicKey,
  }) : _send = send,
       _receive = receive;

  final NoiseCipherState _send;
  final NoiseCipherState _receive;
  final ReplayWindow _replay = ReplayWindow();
  final Uint8List handshakeHash;
  final Uint8List remoteStaticPublicKey;

  Future<Uint8List> encrypt(
    List<int> plaintext, {
    List<int> associatedData = const [],
  }) async {
    final counter = _send.takeCounter();
    final body = await _send.encryptAt(counter, associatedData, plaintext);
    final frame = Uint8List(_counterLength + body.length);
    ByteData.sublistView(frame).setUint64(0, counter, Endian.big);
    frame.setRange(_counterLength, frame.length, body);
    return frame;
  }

  Future<Uint8List> decrypt(
    List<int> frame, {
    List<int> associatedData = const [],
  }) async {
    if (frame.length < _counterLength + noiseTagLength) {
      throw const NoiseException('transport frame too short');
    }
    final bytes = Uint8List.fromList(frame);
    final counter = ByteData.sublistView(bytes).getUint64(0, Endian.big);
    if (counter < 0 || counter >= maxSessionMessages) {
      throw const NoiseException('transport counter out of range');
    }
    if (!_replay.accepts(counter)) {
      throw const NoiseException('transport message replayed or too old');
    }
    final plaintext = await _receive.decryptAt(
      counter,
      associatedData,
      bytes.sublist(_counterLength),
    );
    // Recorded only now: a concurrent copy of this frame may have been accepted meanwhile.
    if (!_replay.accept(counter)) {
      throw const NoiseException('transport message replayed or too old');
    }
    return plaintext;
  }
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
    required NoiseSymmetricState symmetric,
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
  final NoiseSymmetricState _symmetric;
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
    final symmetric = await NoiseSymmetricState.start(noiseProtocolName);
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
    _requireLength(message, noiseKeyLength);
    _remoteEphemeral = Uint8List.fromList(message.sublist(0, noiseKeyLength));
    await _symmetric.mixHash(_remoteEphemeral!);
    return _symmetric.decryptAndHash(message.sublist(noiseKeyLength));
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
    _requireLength(message, noiseKeyLength + _encryptedStaticLength);
    final ephemeral = await _ensureEphemeral();
    _remoteEphemeral = Uint8List.fromList(message.sublist(0, noiseKeyLength));
    await _symmetric.mixHash(_remoteEphemeral!);
    await _symmetric.mixKey(await _dh(ephemeral, _remoteEphemeral!)); // ee
    final remoteStatic = await _symmetric.decryptAndHash(
      message.sublist(noiseKeyLength, noiseKeyLength + _encryptedStaticLength),
    );
    _remoteStatic = remoteStatic;
    await _checkResponderPeerId(remoteStatic);
    await _symmetric.mixKey(await _dh(ephemeral, remoteStatic)); // es
    return _symmetric.decryptAndHash(
      message.sublist(noiseKeyLength + _encryptedStaticLength),
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
