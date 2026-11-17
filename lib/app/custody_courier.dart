import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../core/crypto/identity.dart';
import '../core/dtn/custody_envelope.dart';
import '../core/dtn/custody_seal.dart';
import '../core/dtn/envelope_store.dart';

/// First two bytes of a store-and-forward frame inside a 1:1 Noise message. Chat text
/// is UTF-8, which never contains 0xFF, so the two cannot be confused.
const List<int> courierMagic = [0xFF, 0x44];

/// How often a linked member is offered our held-ID list, and the least time between
/// two lists to the same member (so a list answering a list does not loop).
const Duration courierOfferEvery = Duration(seconds: 60);
const Duration courierReplyGap = Duration(seconds: 10);

/// Store-and-forward between unit members. A message whose receipt does not come back is
/// sealed with Noise K to the recipient and held; every linked member is offered the
/// held IDs, and the one that lacks an envelope gets a copy (spray and wait). The
/// recipient opens it, and its delivered IDs tell carriers to stop.
///
/// Frames travel inside the per-pair Noise sessions, so only linked unit members see
/// them. The store is memory-only and is cleared by panic wipe.
class CustodyCourier {
  CustodyCourier({
    required this.keyPair,
    required this.peerId,
    required this.send,
    required this.rosterKeys,
    required this.keyOf,
    required this.onMessage,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    store = EnvelopeStore(nowSeconds: _now);
  }

  final SimpleKeyPair keyPair;
  final Uint8List peerId;

  /// Sends a frame to a linked member over its Noise session.
  final Future<void> Function(String peerHex, Uint8List frame) send;

  /// Static keys of every roster member, and the key of one member by PeerID hex.
  final List<Uint8List> Function() rosterKeys;
  final Uint8List? Function(String peerHex) keyOf;

  /// A message for this phone, from the member with [senderHex]. [packetId] is the one
  /// the sender first sent it under, so a copy that also came directly can be dropped.
  final void Function(String senderHex, int packetId, String text) onMessage;

  final DateTime Function() _clock;
  late final EnvelopeStore store;
  final Map<String, DateTime> _lastOffer = {};
  Set<String> _linked = const {};

  int _now() => _clock().millisecondsSinceEpoch ~/ 1000;

  static bool isFrame(List<int> plaintext) =>
      plaintext.length > courierMagic.length &&
      plaintext[0] == courierMagic[0] &&
      plaintext[1] == courierMagic[1];

  /// Seals [text] (sent first as [packetId]) to [recipientHex] and pushes it to every
  /// linked member. Returns the envelope ID, or null when it was not held.
  Future<Uint8List?> hold(
    String recipientHex,
    int packetId,
    String text,
  ) async {
    final key = keyOf(recipientHex);
    if (key == null) return null;
    final header = ByteData(4)..setUint32(0, packetId);
    final envelope = await sealCustody(
      sender: keyPair,
      recipientPublic: key,
      plaintext: [...header.buffer.asUint8List(), ...utf8.encode(text)],
      nowSeconds: _now(),
    );
    if (!store.insert(envelope)) return null;
    await _push(envelope);
    return envelope.id;
  }

  /// The recipient confirmed [id] some other way: stop carrying it.
  void delivered(List<int> id) => store.markDelivered(id);

  /// Sends one new envelope to every linked member at once: whole to its recipient,
  /// half its copies to a carrier. Other held envelopes are left out.
  Future<void> _push(CustodyEnvelope envelope, {String? except}) async {
    final newKey = custodyIdKey(envelope.id);
    for (final peer in _linked) {
      if (peer == except) continue;
      final others = {
        for (final id in store.advertisedIds())
          if (custodyIdKey(id) != newKey) custodyIdKey(id),
      };
      for (final out in store.sprayFor(
        peerKeys: others,
        peerPeerId: _bytes(peer),
      )) {
        await _sendFrame(peer, dtnKindEnvelope, out.encode());
      }
    }
  }

  /// Offers held IDs to members that just linked, and to every member once a minute.
  Future<void> tick(Set<String> linked) async {
    _linked = linked;
    _lastOffer.removeWhere((peer, _) => !linked.contains(peer));
    for (final peer in linked) {
      final last = _lastOffer[peer];
      if (last == null || _clock().difference(last) >= courierOfferEvery) {
        await _offer(peer, force: true);
      }
    }
  }

  Future<void> _offer(String peer, {required bool force}) async {
    final last = _lastOffer[peer];
    if (!force && last != null && _clock().difference(last) < courierReplyGap) {
      return;
    }
    _lastOffer[peer] = _clock();
    await _sendFrame(peer, dtnKindIdList, encodeIdList(store.advertisedIds()));
  }

  /// Handles a frame from linked member [fromHex]. Malformed frames are dropped.
  Future<void> handle(String fromHex, Uint8List plaintext) async {
    try {
      final (kind, body) = parseDtnFrame(
        Uint8List.sublistView(plaintext, courierMagic.length),
      );
      if (kind == dtnKindIdList) {
        await _onIdList(fromHex, decodeIdList(body));
      } else {
        await _onEnvelope(
          fromHex,
          CustodyEnvelope.decode(body, nowSeconds: _now()),
        );
      }
    } on CustodyFormatException {
      // Dropped: a malformed or expired frame.
    }
  }

  Future<void> _onIdList(String fromHex, List<Uint8List> ids) async {
    final from = _bytes(fromHex);
    final keys = {for (final id in ids) custodyIdKey(id)};
    // The recipient listing an ID it was meant to get means it has it: stop carrying.
    for (final id in store.heldIds()) {
      if (keys.contains(custodyIdKey(id)) && _addressedTo(id, from)) {
        store.markDelivered(id);
      }
    }
    for (final envelope in store.sprayFor(peerKeys: keys, peerPeerId: from)) {
      await _sendFrame(fromHex, dtnKindEnvelope, envelope.encode());
    }
    // Answer with our own list so the member can send what we lack.
    await _offer(fromHex, force: false);
  }

  bool _addressedTo(Uint8List id, Uint8List peer) {
    final envelope = store.lookup(id);
    return envelope != null &&
        custodyIdKey(envelope.recipientHint) == custodyIdKey(peer);
  }

  Future<void> _onEnvelope(String fromHex, CustodyEnvelope envelope) async {
    if (store.wasDelivered(envelope.id) || store.holds(envelope.id)) return;
    if (custodyIdKey(envelope.recipientHint) != custodyIdKey(peerId)) {
      if (store.insert(envelope)) await _push(envelope, except: fromHex);
      return;
    }
    final opened = await openCustodyFrom(
      envelope: envelope,
      recipient: keyPair,
      rosterPublicKeys: rosterKeys(),
    );
    if (opened == null || opened.$2.length < 4) return;
    store.markDelivered(envelope.id);
    // Tell the carrier at once, so it stops carrying this envelope.
    await _offer(fromHex, force: true);
    final (senderKey, body) = opened;
    onMessage(
      custodyIdKey(await peerIdFor(senderKey)),
      ByteData.sublistView(body).getUint32(0),
      utf8.decode(body.sublist(4), allowMalformed: true),
    );
  }

  Future<void> _sendFrame(String peer, int kind, Uint8List body) async {
    try {
      await send(
        peer,
        Uint8List.fromList([...courierMagic, ...dtnFrame(kind, body)]),
      );
    } on StateError {
      // The member's queue is full; the next offer tries again.
    }
  }

  void clear() {
    store.clear();
    _lastOffer.clear();
    _linked = const {};
  }

  static Uint8List _bytes(String hex) => Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}
