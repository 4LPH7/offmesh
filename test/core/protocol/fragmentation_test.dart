import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/protocol/fragmentation.dart';
import 'package:offmesh/core/protocol/packet.dart';

Uint8List _bytes(int length, {int seed = 0}) =>
    Uint8List.fromList(List.generate(length, (i) => (i * 7 + seed) & 0xFF));

Uint8List _id(int fill) => Uint8List.fromList(List.filled(8, fill));

List<Packet> _split(
  Uint8List data, {
  int maxPayload = 220,
  int packetId = 1,
  int fill = 0x11,
}) {
  return Fragmenter(maxPayload: maxPayload).fragment(
    type: PacketType.noiseTransport,
    ttl: 7,
    packetId: packetId,
    senderId: _id(fill),
    recipientId: _id(0x22),
    data: data,
  );
}

void main() {
  group('Fragmenter', () {
    test('splits 500 bytes at 220 into three fragments of 220, 220 and 60', () {
      final packets = _split(_bytes(500));

      expect(packets.map((p) => p.payload.length), [220, 220, 60]);
      expect(packets.map((p) => p.fragIdx), [0, 1, 2]);
      expect(packets.every((p) => p.fragTotal == 3), isTrue);
    });

    test('a payload that fits produces one fragment with fragTotal 1', () {
      final packets = _split(_bytes(10));

      expect(packets, hasLength(1));
      expect(packets.single.fragTotal, 1);
    });

    test('an empty payload still produces one empty fragment', () {
      final packets = _split(Uint8List(0));

      expect(packets, hasLength(1));
      expect(packets.single.payload, isEmpty);
    });

    test('honours a smaller max payload from the transport (BLE MTU)', () {
      final packets = _split(_bytes(50), maxPayload: 20);

      expect(packets.map((p) => p.payload.length), [20, 20, 10]);
    });

    test('rejects a payload that needs more than 255 fragments', () {
      expect(() => _split(_bytes(220 * 255 + 1)), throwsArgumentError);
    });

    test('rejects a max payload outside 1..220', () {
      expect(() => Fragmenter(maxPayload: 0), throwsArgumentError);
      expect(() => Fragmenter(maxPayload: 221), throwsArgumentError);
    });
  });

  group('Reassembler', () {
    test('rebuilds the original bytes when fragments arrive in order', () {
      final data = _bytes(500);
      final reassembler = Reassembler();

      Uint8List? result;
      for (final packet in _split(data)) {
        result = reassembler.add(packet);
      }

      expect(result, data);
    });

    test('rebuilds the original bytes when fragments arrive out of order', () {
      final data = _bytes(500);
      final reassembler = Reassembler();
      final packets = _split(data).reversed.toList();

      Uint8List? result;
      for (final packet in packets) {
        result = reassembler.add(packet);
      }

      expect(result, data);
    });

    test('returns null until the last fragment arrives', () {
      final reassembler = Reassembler();
      final packets = _split(_bytes(500));

      expect(reassembler.add(packets[0]), isNull);
      expect(reassembler.add(packets[1]), isNull);
      expect(reassembler.add(packets[2]), isNotNull);
    });

    test('a duplicate fragment does not complete a message early', () {
      final reassembler = Reassembler();
      final packets = _split(_bytes(500));

      reassembler.add(packets[0]);
      reassembler.add(packets[0]);

      expect(reassembler.add(packets[1]), isNull);
    });

    test('a single-fragment packet is returned immediately', () {
      final reassembler = Reassembler();

      expect(reassembler.add(_split(_bytes(5)).single), _bytes(5));
    });

    test('keeps at most 32 incomplete messages, evicting the oldest', () {
      final reassembler = Reassembler();
      // Start 33 two-fragment messages from different senders; each is incomplete.
      for (var sender = 0; sender < 33; sender++) {
        reassembler.add(
          _split(_bytes(300), packetId: sender + 1, fill: sender)[0],
        );
      }

      // Message from sender 0 was evicted, so its second fragment cannot complete it.
      final second = _split(_bytes(300), packetId: 1, fill: 0)[1];
      expect(reassembler.add(second), isNull);
      expect(reassembler.inFlightCount, lessThanOrEqualTo(32));
    });

    test('a fragment that disagrees on fragTotal drops that message', () {
      final reassembler = Reassembler();
      final good = _split(_bytes(500));
      reassembler.add(good[0]);

      final conflicting = Packet(
        type: PacketType.noiseTransport,
        ttl: 7,
        packetId: 1,
        senderId: _id(0x11),
        recipientId: _id(0x22),
        fragIdx: 1,
        fragTotal: 2,
        payload: _bytes(10),
      );

      expect(reassembler.add(conflicting), isNull);
      expect(reassembler.add(good[1]), isNull);
    });
  });
}
