import 'dart:typed_data';

import 'custody_envelope.dart';

/// Envelopes held in memory for store-and-forward. Nothing is written to disk.
const int custodyStoreCapacity = 256;

/// Delivered-ID log size. Older IDs are forgotten first.
const int custodyDeliveredCapacity = 256;

/// Splits a copy budget for one spray: the peer gets floor(L/2), the holder keeps
/// ceil(L/2). Returns (give, keep).
(int, int) splitCopies(int copies) => (copies ~/ 2, copies - copies ~/ 2);

/// Bounded in-memory custody store with deterministic eviction.
///
/// Not thread-safe; callers run it on the one isolate that owns the mesh.
class EnvelopeStore {
  EnvelopeStore({
    required int Function() nowSeconds,
    this.capacity = custodyStoreCapacity,
    this.deliveredCapacity = custodyDeliveredCapacity,
  }) : _nowSeconds = nowSeconds;

  final int Function() _nowSeconds;
  final int capacity;
  final int deliveredCapacity;

  // Insertion-ordered maps keep iteration and eviction deterministic.
  final Map<String, CustodyEnvelope> _held = {};
  final Map<String, Uint8List> _delivered = {};

  int get length => _held.length;

  /// IDs currently held, in insertion order.
  List<Uint8List> heldIds() => [for (final e in _held.values) e.id];

  bool holds(List<int> id) => _held.containsKey(custodyIdKey(id));

  /// IDs to advertise on contact: held first, then delivered, at most
  /// [custodyMaxIdsPerList]. A peer that sees its own delivered ID here does not get
  /// the envelope again.
  List<Uint8List> advertisedIds() {
    final all = [...heldIds(), ..._delivered.values];
    return all.length <= custodyMaxIdsPerList
        ? all
        : all.sublist(0, custodyMaxIdsPerList);
  }

  /// Stores [envelope]. Returns false when it was not kept: expired, already held or
  /// delivered, or the weakest envelope when the store is full.
  ///
  /// Eviction when full removes the envelope with the fewest copies left; ties go to the
  /// earliest expiry, then to the smaller ID. The new envelope competes too.
  bool insert(CustodyEnvelope envelope) {
    pruneExpired();
    if (envelope.isExpiredAt(_nowSeconds())) return false;
    final key = custodyIdKey(envelope.id);
    if (_held.containsKey(key) || _delivered.containsKey(key)) return false;
    if (_held.length < capacity) {
      _held[key] = envelope;
      return true;
    }
    final victim = _weakest([..._held.values, envelope]);
    final victimKey = custodyIdKey(victim.id);
    if (victimKey == key) return false;
    _held.remove(victimKey);
    _held[key] = envelope;
    return true;
  }

  void pruneExpired() {
    final now = _nowSeconds();
    _held.removeWhere((_, envelope) => envelope.isExpiredAt(now));
  }

  /// Envelopes to hand to a peer on contact.
  ///
  /// [peerKeys] are the peer's advertised IDs (held and delivered), so nothing is sent
  /// twice. An envelope whose recipient hint equals [peerPeerId] goes to that peer whole
  /// (copies set to 1) and keeps its local copy. Otherwise only envelopes with at least
  /// two copies are sprayed: the peer gets floor(L/2) and the holder keeps ceil(L/2).
  // ponytail: the split is committed before the send is confirmed, so a link that dies
  // mid-send loses those copies. Confirm-then-split waits on a transport ack.
  // ponytail: a delivered envelope stays held until it expires. Purging on the peer's
  // delivered list would reclaim the cap sooner.
  List<CustodyEnvelope> sprayFor({
    required Set<String> peerKeys,
    required Uint8List peerPeerId,
  }) {
    pruneExpired();
    final outgoing = <CustodyEnvelope>[];
    for (final entry in _held.entries.toList()) {
      final envelope = entry.value;
      if (peerKeys.contains(entry.key)) continue;
      if (_sameBytes(envelope.recipientHint, peerPeerId)) {
        outgoing.add(envelope.withCopies(1));
        continue;
      }
      if (envelope.copies < 2) continue;
      final (give, keep) = splitCopies(envelope.copies);
      _held[entry.key] = envelope.withCopies(keep);
      outgoing.add(envelope.withCopies(give));
    }
    return outgoing;
  }

  /// Records that [id] reached its recipient and was opened. Drops any held copy.
  /// Returns false if it was already recorded.
  bool markDelivered(List<int> id) {
    final key = custodyIdKey(id);
    _held.remove(key);
    if (_delivered.containsKey(key)) return false;
    _delivered[key] = Uint8List.fromList(id);
    if (_delivered.length > deliveredCapacity) {
      _delivered.remove(_delivered.keys.first);
    }
    return true;
  }

  bool wasDelivered(List<int> id) => _delivered.containsKey(custodyIdKey(id));

  /// The held envelope with [id], or null. Read-only: the copy budget is unchanged.
  CustodyEnvelope? lookup(List<int> id) => _held[custodyIdKey(id)];

  /// Drops every envelope and delivered ID. Intended for panic wipe.
  void clear() {
    _held.clear();
    _delivered.clear();
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static CustodyEnvelope _weakest(List<CustodyEnvelope> candidates) {
    final sorted = [...candidates]
      ..sort((a, b) {
        final byCopies = a.copies.compareTo(b.copies);
        if (byCopies != 0) return byCopies;
        final byExpiry = a.expiresAt.compareTo(b.expiresAt);
        if (byExpiry != 0) return byExpiry;
        return custodyIdKey(a.id).compareTo(custodyIdKey(b.id));
      });
    return sorted.first;
  }
}
