import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/dtn/custody_envelope.dart';
import 'package:offmesh/core/dtn/envelope_store.dart';

const int _now = 1800000000;

Uint8List _hint(int n) => Uint8List.fromList(List.filled(8, n));

CustodyEnvelope _env(int n, {required int copies, required int hintByte}) {
  final id = Uint8List(custodyIdLength)..[0] = n;
  return CustodyEnvelope(
    id: id,
    createdAt: _now,
    expiresAt: _now + 3600,
    copies: copies,
    recipientHint: _hint(hintByte),
    ciphertext: Uint8List(48),
  );
}

EnvelopeStore _store() => EnvelopeStore(nowSeconds: () => _now);

Set<String> _keysOf(List<Uint8List> ids) => {
  for (final id in ids) custodyIdKey(id),
};

void main() {
  test('advertised IDs include delivered ones, once each, capped at 256', () {
    final store = _store()
      ..insert(_env(1, copies: 3, hintByte: 9))
      ..markDelivered(_env(2, copies: 3, hintByte: 9).id);

    final advertised = store.advertisedIds();

    expect(advertised.map(custodyIdKey).toSet(), {
      custodyIdKey(_env(1, copies: 3, hintByte: 9).id),
      custodyIdKey(_env(2, copies: 3, hintByte: 9).id),
    });
    expect(advertised.length, 2);
  });

  test('a peer that advertises an envelope is not sent it again', () {
    final carrier = _store()..insert(_env(1, copies: 4, hintByte: 9));
    final peerAdvertises = _keysOf([_env(1, copies: 4, hintByte: 9).id]);

    final sent = carrier.sprayFor(
      peerKeys: peerAdvertises,
      peerPeerId: _hint(7),
    );

    expect(sent, isEmpty);
    expect(carrier.heldIds().length, 1);
  });

  test('a carrier sprays copies to a non-recipient, conserving the budget', () {
    final sender = _store()..insert(_env(1, copies: 6, hintByte: 9));

    final sent = sender.sprayFor(peerKeys: {}, peerPeerId: _hint(7));

    expect(sent.single.copies, 3);
    expect(sender.heldIds().length, 1);
    final kept = sender.sprayFor(peerKeys: {}, peerPeerId: _hint(7));
    expect(kept.single.copies, 1);
  });

  test('an envelope is handed whole to the peer named by its hint', () {
    final sender = _store()..insert(_env(1, copies: 1, hintByte: 9));

    final sent = sender.sprayFor(peerKeys: {}, peerPeerId: _hint(9));

    expect(sent.single.copies, 1);
    expect(sender.holds(_env(1, copies: 1, hintByte: 9).id), isTrue);
  });

  test(
    'two-round exchange: the recipient gets the envelope once and it is not re-sent',
    () {
      final sender = _store()..insert(_env(1, copies: 6, hintByte: 9));
      final recipient = _store();
      const recipientHint = 9;

      // Round 1: the sender meets the recipient directly.
      final first = sender.sprayFor(
        peerKeys: _keysOf(recipient.advertisedIds()),
        peerPeerId: _hint(recipientHint),
      );
      expect(first.length, 1);
      expect(recipient.insert(first.single), isTrue);
      recipient.markDelivered(first.single.id);

      // Round 2: the recipient advertises the delivered id, so nothing goes again.
      final second = sender.sprayFor(
        peerKeys: _keysOf(recipient.advertisedIds()),
        peerPeerId: _hint(recipientHint),
      );
      expect(second, isEmpty);
      expect(recipient.length, 0);
    },
  );

  test('a second copy of a delivered envelope from a carrier is refused', () {
    final recipient = _store();
    final copy = _env(1, copies: 3, hintByte: 9);
    recipient.markDelivered(copy.id);

    expect(recipient.insert(copy), isFalse);
    expect(recipient.wasDelivered(copy.id), isTrue);
  });

  test('clear forgets delivered IDs too', () {
    final store = _store()..markDelivered(_env(1, copies: 1, hintByte: 9).id);
    store.clear();
    expect(store.advertisedIds(), isEmpty);
  });
}
