import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/dtn/custody_envelope.dart';
import 'package:offmesh/core/dtn/envelope_store.dart';

const int _start = 1800000000;
final Uint8List _noPeer = Uint8List.fromList(List.filled(8, 0xaa));

class _Clock {
  int now = _start;
  int call() => now;
}

CustodyEnvelope _env(int n, {int copies = 6, int expiresIn = 3600}) {
  final id = Uint8List(custodyIdLength)
    ..[0] = n >> 8
    ..[1] = n & 0xff;
  return CustodyEnvelope(
    id: id,
    createdAt: _start,
    expiresAt: _start + expiresIn,
    copies: copies,
    recipientHint: Uint8List(custodyHintLength),
    ciphertext: Uint8List(48),
  );
}

Set<String> _keys(Iterable<Uint8List> ids) => {
  for (final id in ids) custodyIdKey(id),
};

void main() {
  group('copy splitting', () {
    test('peer gets floor(L/2), holder keeps ceil(L/2)', () {
      expect(splitCopies(1), (0, 1));
      expect(splitCopies(2), (1, 1));
      expect(splitCopies(3), (1, 2));
      expect(splitCopies(6), (3, 3));
      expect(splitCopies(5), (2, 3));
    });

    test('budget is conserved across any split', () {
      for (var l = 1; l <= custodyMaxCopies; l++) {
        final (give, keep) = splitCopies(l);
        expect(give + keep, l);
      }
    });
  });

  group('spray', () {
    test('a spray halves the budget on the holder and on the copy sent', () {
      final clock = _Clock();
      final store = EnvelopeStore(nowSeconds: clock.call)
        ..insert(_env(1, copies: 6));

      final sent = store.sprayFor(peerKeys: {}, peerPeerId: _noPeer);

      expect(sent.single.copies, 3);
      expect(store.heldIds().length, 1);
      expect(
        store.sprayFor(peerKeys: {}, peerPeerId: _noPeer).single.copies,
        1,
      ); // holder had 3, gives 1
    });

    test('ids the peer already holds are not sent again', () {
      final clock = _Clock();
      final store = EnvelopeStore(nowSeconds: clock.call)
        ..insert(_env(1))
        ..insert(_env(2));

      final sent = store.sprayFor(
        peerKeys: _keys([_env(1).id]),
        peerPeerId: _noPeer,
      );

      expect(sent.map((e) => e.id), [_env(2).id]);
    });

    test('an envelope with one copy left is never sprayed', () {
      final clock = _Clock();
      final store = EnvelopeStore(nowSeconds: clock.call)
        ..insert(_env(1, copies: 1));

      expect(store.sprayFor(peerKeys: {}, peerPeerId: _noPeer), isEmpty);
      expect(store.sprayFor(peerKeys: {}, peerPeerId: _noPeer), isEmpty);
    });

    test('a spray never sends more than the wire cap, and it decodes', () {
      final clock = _Clock();
      final store = EnvelopeStore(nowSeconds: clock.call)
        ..insert(_env(1, copies: custodyMaxCopies));

      final sent = store.sprayFor(peerKeys: {}, peerPeerId: _noPeer).single;

      expect(sent.copies, lessThanOrEqualTo(custodyMaxWireCopies));
      expect(
        CustodyEnvelope.decode(sent.encode(), nowSeconds: _start).copies,
        sent.copies,
      );
    });

    test('a duplicate with a higher budget does not raise the held one', () {
      final clock = _Clock();
      final store = EnvelopeStore(nowSeconds: clock.call)
        ..insert(_env(1, copies: 1));

      expect(store.insert(_env(1, copies: custodyMaxWireCopies)), isFalse);
      expect(store.sprayFor(peerKeys: {}, peerPeerId: _noPeer), isEmpty);
    });
  });

  group('expiry', () {
    test('expired envelopes are dropped on prune and not accepted', () {
      final clock = _Clock();
      final store = EnvelopeStore(nowSeconds: clock.call)
        ..insert(_env(1, expiresIn: 60));
      clock.now = _start + 60;

      store.pruneExpired();

      expect(store.length, 0);
      expect(store.insert(_env(2, expiresIn: 60)), isFalse);
    });
  });

  group('capacity', () {
    test('a full store evicts the envelope with the fewest copies', () {
      final clock = _Clock();
      final store = EnvelopeStore(nowSeconds: clock.call, capacity: 3)
        ..insert(_env(1, copies: 4))
        ..insert(_env(2, copies: 1))
        ..insert(_env(3, copies: 5));

      expect(store.insert(_env(4, copies: 3)), isTrue);

      expect(store.holds(_env(2).id), isFalse);
      expect(store.holds(_env(4).id), isTrue);
      expect(store.length, 3);
    });

    test('a newcomer with the fewest copies is refused, not stored', () {
      final clock = _Clock();
      final store = EnvelopeStore(nowSeconds: clock.call, capacity: 2)
        ..insert(_env(1, copies: 4))
        ..insert(_env(2, copies: 4));

      expect(store.insert(_env(3, copies: 1)), isFalse);
      expect(store.holds(_env(3).id), isFalse);
    });

    test('ties go to the earliest expiry, then the smaller id', () {
      final clock = _Clock();
      final store = EnvelopeStore(nowSeconds: clock.call, capacity: 2)
        ..insert(_env(1, copies: 2, expiresIn: 900))
        ..insert(_env(2, copies: 2, expiresIn: 300));

      expect(store.insert(_env(3, copies: 4)), isTrue);
      expect(store.holds(_env(2).id), isFalse);
      expect(store.holds(_env(1).id), isTrue);
    });

    test('equal copies and equal expiry: the smaller id is evicted first', () {
      final clock = _Clock();
      final store = EnvelopeStore(nowSeconds: clock.call, capacity: 2);
      final a = _env(1, copies: 2, expiresIn: 900);
      final b = _env(2, copies: 2, expiresIn: 900);
      store
        ..insert(a)
        ..insert(b);
      final lower = custodyIdKey(a.id).compareTo(custodyIdKey(b.id)) < 0
          ? a
          : b;
      final higher = identical(lower, a) ? b : a;

      expect(store.insert(_env(3, copies: 4)), isTrue);
      expect(store.holds(lower.id), isFalse);
      expect(store.holds(higher.id), isTrue);
    });

    test('the default cap is 256 envelopes', () {
      final clock = _Clock();
      final store = EnvelopeStore(nowSeconds: clock.call);
      for (var i = 0; i < 300; i++) {
        store.insert(_env(i));
      }
      expect(store.length, custodyStoreCapacity);
    });
  });

  group('delivered-once', () {
    test('a delivered id is not stored again', () {
      final clock = _Clock();
      final store = EnvelopeStore(nowSeconds: clock.call)
        ..insert(_env(1))
        ..markDelivered(_env(1).id);

      expect(store.holds(_env(1).id), isFalse);
      expect(store.insert(_env(1)), isFalse);
      expect(store.wasDelivered(_env(1).id), isTrue);
    });

    test('the delivered log forgets its oldest id at the cap', () {
      final clock = _Clock();
      final store = EnvelopeStore(nowSeconds: clock.call, deliveredCapacity: 2)
        ..markDelivered(_env(1).id)
        ..markDelivered(_env(2).id)
        ..markDelivered(_env(3).id);

      expect(store.wasDelivered(_env(1).id), isFalse);
      expect(store.wasDelivered(_env(3).id), isTrue);
    });
  });

  test('clear empties the store and the delivered log', () {
    final clock = _Clock();
    final store = EnvelopeStore(nowSeconds: clock.call)
      ..insert(_env(1))
      ..markDelivered(_env(2).id);

    store.clear();

    expect(store.length, 0);
    expect(store.wasDelivered(_env(2).id), isFalse);
  });

  test('random inserts never exceed the cap', () {
    final clock = _Clock();
    final store = EnvelopeStore(nowSeconds: clock.call, capacity: 8);
    final random = Random(3);
    for (var i = 0; i < 500; i++) {
      store.insert(_env(i, copies: 1 + random.nextInt(custodyMaxCopies)));
      expect(store.length, lessThanOrEqualTo(8));
    }
  });
}
