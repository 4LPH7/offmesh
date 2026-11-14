import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/protocol/delivery_ack.dart';

void main() {
  final at = DateTime.utc(2026, 11, 13, 8, 30, 15, 123);

  test('round-trips packetId and receivedAt in 12 big-endian bytes', () {
    final bytes = DeliveryReceipt(
      packetId: 0xDEADBEEF,
      receivedAt: at,
    ).encode();

    expect(bytes, hasLength(deliveryReceiptLength));
    expect(bytes.sublist(0, 4), [0xDE, 0xAD, 0xBE, 0xEF]);
    final decoded = DeliveryReceipt.decode(bytes);
    expect(decoded.packetId, 0xDEADBEEF);
    expect(decoded.receivedAt, at);
  });

  test('accepts the packetId boundaries', () {
    for (final id in [0, 0xFFFFFFFF]) {
      final bytes = DeliveryReceipt(packetId: id, receivedAt: at).encode();
      expect(DeliveryReceipt.decode(bytes).packetId, id);
    }
  });

  test('rejects any length other than 12', () {
    for (final length in [0, 11, 13]) {
      expect(
        () => DeliveryReceipt.decode(Uint8List(length)),
        throwsA(isA<DeliveryReceiptFormatException>()),
      );
    }
  });

  test('rejects a timestamp DateTime cannot hold, including the top bit', () {
    for (final high in [0x80, 0x7F]) {
      final bytes = Uint8List(deliveryReceiptLength)..[4] = high;
      expect(
        () => DeliveryReceipt.decode(bytes),
        throwsA(isA<DeliveryReceiptFormatException>()),
      );
    }
  });

  test('refuses to build a receipt with an out-of-range field', () {
    expect(
      () => DeliveryReceipt(packetId: -1, receivedAt: at),
      throwsArgumentError,
    );
    expect(
      () => DeliveryReceipt(packetId: 0x100000000, receivedAt: at),
      throwsArgumentError,
    );
    expect(
      () => DeliveryReceipt(packetId: 1, receivedAt: DateTime.utc(1969)),
      throwsArgumentError,
    );
  });
}
