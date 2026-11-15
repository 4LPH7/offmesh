import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../crypto/identity.dart';
import '../crypto/noise_xx.dart';
import '../protocol/delivery_ack.dart';
import '../protocol/fragmentation.dart';
import '../protocol/packet.dart';
import 'router.dart';
import 'transport.dart';

/// Protocol name mixed into every handshake, so peers on another version cannot connect.
final Uint8List meshPrologue = Uint8List.fromList(utf8.encode('offmesh/1'));

/// Bounds on state an unauthenticated peer can make us allocate.
const int maxPendingHandshakes = 32;
const int maxQueuedPerPeer = 64;

const int _handshakeOneLength = 32; // e
const int _handshakeTwoMinLength =
    96; // e, encrypted s, encrypted empty payload

class ReceivedMessage {
  const ReceivedMessage({required this.senderId, required this.plaintext});

  final Uint8List senderId;
  final Uint8List plaintext;
}

/// A receipt from [peerId]: the message sent with [DeliveryReceipt.packetId] arrived whole.
class DeliveryReceiptEvent {
  const DeliveryReceiptEvent({required this.peerId, required this.receipt});

  final Uint8List peerId;
  final DeliveryReceipt receipt;
}

class _QueuedMessage {
  const _QueuedMessage(this.plaintext, this.ttl, this.packetId);

  final Uint8List plaintext;
  final int ttl;
  final int packetId;
}

/// One device on the mesh: a router plus one Noise session per peer.
///
/// Messages to a peer are queued until the handshake with it completes. Handshake packets
/// are flooded like any other packet, so peers several hops away can still connect.
/// Relays forward ciphertext they cannot read.
///
/// Transport frames carry an explicit counter and a replay window, so lost or reordered
/// messages still decrypt. Header type, packetId and addresses are bound to each ciphertext.
class MeshNode {
  MeshNode({
    required this.identity,
    required List<MeshTransport> transports,
    Random? random,
    Pause? delay,
    DateTime Function()? clock,
    void Function(Object error, StackTrace stack)? onError,
  }) : _random = random ?? Random.secure(),
       _clock = clock ?? DateTime.now,
       _onError = onError {
    _router = MeshRouter(
      localId: identity.peerId,
      transports: transports,
      onDeliver: _onPacket,
      random: _random,
      delay: delay,
      clock: clock,
    );
  }

  final Identity identity;
  final Random _random;
  final DateTime Function() _clock;
  final void Function(Object error, StackTrace stack)? _onError;
  late final MeshRouter _router;
  Future<void> _inbound = Future<void>.value();
  Future<void> _outbound = Future<void>.value();

  final StreamController<ReceivedMessage> _inbox =
      StreamController<ReceivedMessage>.broadcast();
  final StreamController<DeliveryReceiptEvent> _receipts =
      StreamController<DeliveryReceiptEvent>.broadcast();
  final Map<String, NoiseSession> _sessions = {};
  final Map<String, NoiseHandshake> _initiators = {};
  final Map<String, NoiseHandshake> _responders = {};
  final Map<String, List<_QueuedMessage>> _queues = {};
  final Reassembler _reassembler = Reassembler();

  Uint8List get peerId => identity.peerId;

  Stream<ReceivedMessage> get messages => _inbox.stream;

  /// Receipts for messages this node sent; match them to the ID [sendText] returned.
  Stream<DeliveryReceiptEvent> get receipts => _receipts.stream;

  int get relaysSent => _router.relaysSent;

  int get relaysSuppressed => _router.relaysSuppressed;

  void start() => _router.start();

  Future<void> stop() => _router.stop();

  void addTransport(MeshTransport transport) => _router.addTransport(transport);

  Future<void> removeTransport(MeshTransport transport) =>
      _router.removeTransport(transport);

  /// Sends [plaintext] to [peerId], handshaking first if there is no session yet.
  ///
  /// Returns the message's packet ID; a [receipts] event with the same ID confirms delivery.
  Future<int> sendText(
    Uint8List peerId,
    Uint8List plaintext, {
    int ttl = maxTtl,
  }) async {
    final key = peerId.hex;
    final session = _sessions[key];
    final packetId = _nextPacketId();
    if (session != null) {
      await _sendEncrypted(peerId, session, plaintext, ttl, packetId);
      return packetId;
    }
    final queue = _queues.putIfAbsent(key, () => []);
    if (queue.length >= maxQueuedPerPeer) {
      throw StateError('too many messages waiting for $key');
    }
    queue.add(_QueuedMessage(plaintext, ttl, packetId));
    if (!_initiators.containsKey(key) && !_responders.containsKey(key)) {
      await _startHandshake(peerId);
    }
    return packetId;
  }

  /// Inbound packets are handled one at a time, so a message that follows a handshake
  /// message never runs before that handshake has finished.
  void _onPacket(Packet packet) {
    _inbound = _inbound
        .then((_) => _handle(packet))
        .catchError(
          (Object error, StackTrace stack) => _onError?.call(error, stack),
        );
  }

  Future<void> _handle(Packet packet) async {
    try {
      if (packet.type == PacketType.noiseTransport) {
        await _onTransport(packet);
      } else if (packet.type == PacketType.ack) {
        await _onReceipt(packet);
      } else if (packet.type == PacketType.noiseHandshake) {
        await _onHandshake(packet);
      }
    } on NoiseException {
      // A bad handshake or ciphertext is dropped; the sender can retry.
    }
  }

  Future<void> _startHandshake(Uint8List peerId) async {
    final initiator = await NoiseHandshake.initiator(
      staticKeyPair: identity.keyPair,
      prologue: meshPrologue,
      expectedResponderPeerId: peerId,
    );
    _rememberInitiator(peerId.hex, initiator);
    await _sendHandshake(peerId, await initiator.writeMessage(Uint8List(0)));
  }

  void _rememberInitiator(String key, NoiseHandshake handshake) {
    _initiators[key] = handshake;
    _evictOldest(_initiators);
  }

  void _rememberResponder(String key, NoiseHandshake handshake) {
    _responders[key] = handshake;
    _evictOldest(_responders);
  }

  static void _evictOldest(Map<String, NoiseHandshake> pending) {
    while (pending.length > maxPendingHandshakes) {
      pending.remove(pending.keys.first);
    }
  }

  /// Number of responder handshakes awaiting their final message (exposed for tests).
  int get pendingResponderCount => _responders.length;

  /// Handshake messages are told apart by length: message 1 is the bare ephemeral key,
  /// message 2 is the longest, message 3 is in between.
  Future<void> _onHandshake(Packet packet) async {
    final length = packet.payload.length;
    if (length == _handshakeOneLength) {
      await _onOpening(packet);
      return;
    }
    final key = packet.senderId.hex;
    if (length >= _handshakeTwoMinLength && _initiators.containsKey(key)) {
      await _onReply(packet);
      return;
    }
    final responder = _responders[key];
    if (responder != null) {
      await _onFinal(packet, responder);
    }
  }

  /// A peer dialled us: answer with message 2, unless we are dialling them too.
  Future<void> _onOpening(Packet packet) async {
    final key = packet.senderId.hex;
    if (_initiators.containsKey(key)) {
      // Simultaneous first contact: the lower PeerID stays initiator and ignores this.
      if (_compareIds(identity.peerId, packet.senderId) < 0) return;
      _initiators.remove(key);
    }
    final responder = await NoiseHandshake.responder(
      staticKeyPair: identity.keyPair,
      prologue: meshPrologue,
    );
    await responder.readMessage(packet.payload);
    final message2 = await responder.writeMessage(Uint8List(0));
    _rememberResponder(key, responder);
    await _sendHandshake(packet.senderId, message2);
  }

  Future<void> _onReply(Packet packet) async {
    final key = packet.senderId.hex;
    final initiator = _initiators[key]!;
    try {
      await initiator.readMessage(packet.payload);
    } on NoiseException {
      _initiators.remove(key);
      rethrow;
    }
    final message3 = await initiator.writeMessage(Uint8List(0));
    _initiators.remove(key);
    _sessions[key] = initiator.session;
    await _sendHandshake(packet.senderId, message3);
    await _flush(packet.senderId);
  }

  Future<void> _onFinal(Packet packet, NoiseHandshake responder) async {
    final key = packet.senderId.hex;
    try {
      await responder.readMessage(packet.payload);
    } on NoiseException {
      _responders.remove(key);
      rethrow;
    }
    _responders.remove(key);
    final session = responder.session;
    final claimedPeer = await peerIdFor(session.remoteStaticPublicKey);
    if (claimedPeer.hex != key) return;
    _sessions[key] = session;
    await _flush(packet.senderId);
  }

  Future<void> _onTransport(Packet packet) async {
    final complete = _reassembler.add(packet);
    if (complete == null) return;
    final session = _sessions[packet.senderId.hex];
    if (session == null) return;
    final plaintext = await session.decrypt(
      complete,
      associatedData: _bindingData(
        packet.type,
        packet.packetId,
        packet.senderId,
        packet.recipientId,
      ),
    );
    _inbox.add(
      ReceivedMessage(senderId: packet.senderId, plaintext: plaintext),
    );
    await _sendReceipt(packet.senderId, session, packet.packetId);
  }

  /// A receipt is one Noise transport message; never answered, so acks cannot loop.
  Future<void> _onReceipt(Packet packet) async {
    if (packet.fragTotal != 1) return;
    final session = _sessions[packet.senderId.hex];
    if (session == null) return;
    final receipt = DeliveryReceipt.decode(
      await session.decrypt(
        packet.payload,
        associatedData: _bindingData(
          packet.type,
          packet.packetId,
          packet.senderId,
          packet.recipientId,
        ),
      ),
    );
    _receipts.add(
      DeliveryReceiptEvent(peerId: packet.senderId, receipt: receipt),
    );
  }

  Future<void> _flush(Uint8List peerId) async {
    final queued = _queues.remove(peerId.hex);
    final session = _sessions[peerId.hex];
    if (queued == null || session == null) return;
    for (final message in queued) {
      await _sendEncrypted(
        peerId,
        session,
        message.plaintext,
        message.ttl,
        message.packetId,
      );
    }
  }

  Future<void> _sendEncrypted(
    Uint8List peerId,
    NoiseSession session,
    Uint8List plaintext,
    int ttl,
    int packetId,
  ) => _serially(() async {
    final ciphertext = await session.encrypt(
      plaintext,
      associatedData: _bindingData(
        PacketType.noiseTransport,
        packetId,
        identity.peerId,
        peerId,
      ),
    );
    final fragments = Fragmenter().fragment(
      type: PacketType.noiseTransport,
      ttl: ttl,
      packetId: packetId,
      senderId: identity.peerId,
      recipientId: peerId,
      data: ciphertext,
    );
    for (final fragment in fragments) {
      await _router.originateTo(fragment);
    }
  });

  /// Floods the receipt rather than unicasting it on a learned route: the sender of a
  /// route entry is not authenticated yet, so a neighbour could steer receipts away.
  Future<void> _sendReceipt(
    Uint8List peerId,
    NoiseSession session,
    int packetId,
  ) => _serially(() async {
    final receipt = DeliveryReceipt(packetId: packetId, receivedAt: _clock());
    final ackId = _nextPacketId();
    final payload = await session.encrypt(
      receipt.encode(),
      associatedData: _bindingData(
        PacketType.ack,
        ackId,
        identity.peerId,
        peerId,
      ),
    );
    await _router.originate(
      Packet(
        type: PacketType.ack,
        ttl: maxTtl,
        packetId: ackId,
        senderId: identity.peerId,
        recipientId: peerId,
        fragIdx: 0,
        fragTotal: 1,
        payload: payload,
      ),
    );
  });

  /// Runs encrypt-and-send jobs one at a time so the fragments of a message leave in order.
  /// Decryption does not depend on that order: each frame carries its own counter.
  Future<void> _serially(Future<void> Function() send) {
    final run = _outbound.then((_) => send());
    // The caller still gets [run]'s error; only the chain is kept usable for later sends.
    _outbound = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  Future<void> _sendHandshake(Uint8List recipient, Uint8List payload) {
    return _router.originate(
      Packet(
        type: PacketType.noiseHandshake,
        ttl: maxTtl,
        packetId: _nextPacketId(),
        senderId: identity.peerId,
        recipientId: recipient,
        fragIdx: 0,
        fragTotal: 1,
        payload: payload,
      ),
    );
  }

  int _nextPacketId() => _random.nextInt(0x100000000);

  /// Header fields authenticated with each transport and receipt ciphertext. TTL and the
  /// fragment index are left out: relays rewrite the first, and fragments differ in the second.
  static Uint8List _bindingData(
    PacketType type,
    int packetId,
    Uint8List senderId,
    Uint8List recipientId,
  ) {
    final out = Uint8List(1 + 4 + 8 + 8);
    final data = ByteData.sublistView(out);
    data.setUint8(0, type.code);
    data.setUint32(1, packetId, Endian.big);
    out.setRange(5, 13, senderId);
    out.setRange(13, 21, recipientId);
    return out;
  }

  static int _compareIds(List<int> a, List<int> b) {
    for (var i = 0; i < min(a.length, b.length); i++) {
      if (a[i] != b[i]) return a[i].compareTo(b[i]);
    }
    return a.length.compareTo(b.length);
  }
}
