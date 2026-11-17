import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/app/custody_courier.dart';
import 'package:offmesh/core/crypto/identity.dart';
import 'package:offmesh/core/protocol/packet.dart';

/// Three phones whose couriers hand frames straight to each other.
Future<(Map<String, CustodyCourier>, List<String>, List<(String, String)>)>
_unit() async {
  final ids = [for (var i = 0; i < 3; i++) await Identity.generate()];
  final hex = [for (final id in ids) id.peerId.hex];
  final keys = {for (final id in ids) id.peerId.hex: id.publicKey};
  final couriers = <String, CustodyCourier>{};
  final inbox = <(String, String)>[];
  for (final id in ids) {
    final me = id.peerId.hex;
    couriers[me] = CustodyCourier(
      keyPair: id.keyPair,
      peerId: id.peerId,
      send: (peer, frame) => couriers[peer]!.handle(me, frame),
      rosterKeys: () => keys.values.toList(),
      keyOf: (peer) => keys[peer],
      onMessage: (sender, text) => inbox.add((sender, text)),
    );
  }
  return (couriers, hex, inbox);
}

void main() {
  test('frames are told apart from chat text', () {
    expect(CustodyCourier.isFrame([0xFF, 0x44, 0x01]), isTrue);
    expect(CustodyCourier.isFrame(Uint8List.fromList('hi'.codeUnits)), isFalse);
    expect(CustodyCourier.isFrame([0xFF, 0x44]), isFalse);
  });

  test(
    'A to C through B, who meets C later; C\'s list stops B carrying',
    () async {
      final (c, ids, inbox) = await _unit();
      final [a, b, cc] = ids;

      await c[a]!.tick({b});
      await c[b]!.tick({a});
      expect(await c[a]!.hold(cc, 'over'), isTrue);
      expect(c[b]!.store.length, 1, reason: 'B carries a copy');
      expect(inbox, isEmpty);

      // A and B part; B later links with C.
      await c[b]!.tick({cc});
      await c[cc]!.tick({b});
      expect(inbox, [(a, 'over')]);
      expect(c[b]!.store.length, 0, reason: 'C listed it as delivered');

      // A second meeting does not deliver it twice.
      await c[cc]!.tick({b, a});
      expect(inbox.length, 1);
    },
  );

  test('a malformed frame is dropped', () async {
    final (c, ids, inbox) = await _unit();
    await c[ids[0]]!.handle(ids[1], Uint8List.fromList([0xFF, 0x44, 0x02, 1]));
    await c[ids[0]]!.handle(ids[1], Uint8List.fromList([0xFF, 0x44, 0x09]));
    expect(inbox, isEmpty);
  });
}
