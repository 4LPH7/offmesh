import 'dart:typed_data';

/// Encoded size: packetId(4) receivedAt(8), big-endian.
const int deliveryReceiptLength = 12;

class DeliveryReceiptFormatException implements Exception {
  const DeliveryReceiptFormatException(this.message);

  final String message;

  @override
  String toString() => 'DeliveryReceiptFormatException: $message';
}

/// Confirms that a whole message reached its recipient.
///
/// The codec carries no authenticity of its own. MeshNode sends the encoded receipt
/// as a Noise transport message on the session with the original sender, so only the
/// holder of that session can produce a receipt that decrypts.
class DeliveryReceipt {
  DeliveryReceipt({required this.packetId, required DateTime receivedAt})
    : receivedAt = receivedAt.toUtc() {
    if (packetId < 0 || packetId > 0xFFFFFFFF) {
      throw ArgumentError.value(packetId, 'packetId', 'must fit in 32 bits');
    }
    if (receivedAt.millisecondsSinceEpoch < 0) {
      throw ArgumentError.value(receivedAt, 'receivedAt', 'before 1970');
    }
  }

  /// Packet ID shared by every fragment of the acknowledged message.
  final int packetId;

  /// When the recipient reassembled and decrypted the message (UTC, ms precision).
  final DateTime receivedAt;

  Uint8List encode() {
    final out = Uint8List(deliveryReceiptLength);
    ByteData.sublistView(out)
      ..setUint32(0, packetId, Endian.big)
      ..setUint64(4, receivedAt.millisecondsSinceEpoch, Endian.big);
    return out;
  }

  static DeliveryReceipt decode(List<int> bytes) {
    if (bytes.length != deliveryReceiptLength) {
      throw DeliveryReceiptFormatException(
        'receipt must be $deliveryReceiptLength bytes, got ${bytes.length}',
      );
    }
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    // getUint64 wraps values of 2^63 and above to negative on the VM.
    final millis = data.getUint64(4, Endian.big);
    if (millis < 0 || millis > _maxDateMillis) {
      throw const DeliveryReceiptFormatException('receivedAt out of range');
    }
    return DeliveryReceipt(
      packetId: data.getUint32(0, Endian.big),
      receivedAt: DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true),
    );
  }
}

/// Largest instant DateTime can represent (8.64e15 ms after the epoch).
const int _maxDateMillis = 8640000000000000;
