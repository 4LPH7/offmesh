import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/protocol/packet.dart';

Packet _sample({
  PacketType type = PacketType.noiseTransport,
  int ttl = 7,
  List<int> payload = const [1, 2, 3],
  int fragIdx = 0,
  int fragTotal = 1,
}) {
  return Packet(
    type: type,
    ttl: ttl,
    packetId: 0xA1B2C3D4,
    senderId: Uint8List.fromList(List.filled(8, 0x11)),
    recipientId: Uint8List.fromList(List.filled(8, 0x22)),
    fragIdx: fragIdx,
    fragTotal: fragTotal,
    payload: Uint8List.fromList(payload),
  );
}

void main() {
  group('Packet round trip', () {
    test('encodes and decodes every field unchanged', () {
      final original = _sample();

      final decoded = Packet.decode(original.encode());

      expect(decoded.type, PacketType.noiseTransport);
      expect(decoded.ttl, 7);
      expect(decoded.packetId, 0xA1B2C3D4);
      expect(decoded.senderId, everyElement(0x11));
      expect(decoded.recipientId, everyElement(0x22));
      expect(decoded.fragIdx, 0);
      expect(decoded.fragTotal, 1);
      expect(decoded.payload, [1, 2, 3]);
    });

    test('header is exactly 26 bytes before the payload', () {
      final bytes = _sample(payload: const []).encode();

      expect(bytes.length, Packet.headerLength);
      expect(Packet.headerLength, 26);
    });

    test('encoded size is header plus payload', () {
      final bytes = _sample(payload: List.filled(100, 0x5A)).encode();

      expect(bytes.length, 26 + 100);
    });
  });

  group('Packet.decode rejects malformed input', () {
    test('truncated header', () {
      expect(
        () => Packet.decode(Uint8List(25)),
        throwsA(isA<PacketFormatException>()),
      );
    });

    test('unknown protocol version', () {
      final bytes = _sample().encode()..[0] = 0x09;

      expect(() => Packet.decode(bytes), throwsA(isA<PacketFormatException>()));
    });

    test('unknown packet type', () {
      final bytes = _sample().encode()..[1] = 0x7F;

      expect(() => Packet.decode(bytes), throwsA(isA<PacketFormatException>()));
    });

    test('TTL above the maximum of 7', () {
      final bytes = _sample().encode()..[2] = 8;

      expect(() => Packet.decode(bytes), throwsA(isA<PacketFormatException>()));
    });

    test('declared length disagrees with actual bytes', () {
      final bytes = _sample().encode();
      final truncated = bytes.sublist(0, bytes.length - 1);

      expect(
        () => Packet.decode(truncated),
        throwsA(isA<PacketFormatException>()),
      );
    });

    test('payload over 220 bytes is rejected at decode', () {
      final bytes = Uint8List(26 + 221)
        ..[0] = 2
        ..[1] = PacketType.noiseTransport.code
        ..[2] = 1
        ..[25] = 221;

      expect(() => Packet.decode(bytes), throwsA(isA<PacketFormatException>()));
    });

    test('zero fragment total is rejected', () {
      final bytes = _sample().encode()..[24] = 0;

      expect(() => Packet.decode(bytes), throwsA(isA<PacketFormatException>()));
    });

    test('fragment index at or past the total is rejected', () {
      final bytes = _sample(fragTotal: 2, fragIdx: 0).encode()..[23] = 2;

      expect(() => Packet.decode(bytes), throwsA(isA<PacketFormatException>()));
    });
  });

  group('Packet construction', () {
    test('rejects a payload over 220 bytes', () {
      expect(() => _sample(payload: List.filled(221, 0)), throwsArgumentError);
    });

    test('a broadcast recipient is all 0xFF', () {
      final packet = Packet(
        type: PacketType.announce,
        ttl: 7,
        packetId: 1,
        senderId: Uint8List(8),
        recipientId: Packet.broadcastId,
        fragIdx: 0,
        fragTotal: 1,
        payload: Uint8List(0),
      );

      expect(packet.isBroadcast, isTrue);
      expect(_sample().isBroadcast, isFalse);
    });

    test('payload is copied, so later mutation of the input has no effect', () {
      final input = Uint8List.fromList([1, 2, 3]);
      final packet = Packet(
        type: PacketType.noiseTransport,
        ttl: 1,
        packetId: 1,
        senderId: Uint8List(8),
        recipientId: Uint8List(8),
        fragIdx: 0,
        fragTotal: 1,
        payload: input,
      );

      input[0] = 99;

      expect(packet.payload, [1, 2, 3]);
    });
  });
}
