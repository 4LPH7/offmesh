import 'dart:typed_data';

/// Wire format version. Packets with any other version are rejected.
const int protocolVersion = 2;

/// Largest payload carried by one packet (LAN default; BLE uses less per MTU).
const int maxPayloadLength = 220;

/// Largest TTL a packet may carry; each relay hop decrements it.
const int maxTtl = 7;

const int _idLength = 8;

enum PacketType {
  announce(0x01),
  noiseHandshake(0x02),
  noiseTransport(0x03),
  ack(0x04);

  const PacketType(this.code);

  final int code;

  static PacketType? fromCode(int code) {
    for (final type in values) {
      if (type.code == code) return type;
    }
    return null;
  }
}

class PacketFormatException implements Exception {
  const PacketFormatException(this.message);

  final String message;

  @override
  String toString() => 'PacketFormatException: $message';
}

/// One wire packet: a 26-byte header followed by up to [maxPayloadLength] bytes.
///
/// Header layout (big-endian multi-byte fields):
/// version(1) type(1) ttl(1) packetId(4) senderId(8) recipientId(8)
/// fragIdx(1) fragTotal(1) length(1).
class Packet {
  Packet({
    required this.type,
    required this.ttl,
    required this.packetId,
    required Uint8List senderId,
    required Uint8List recipientId,
    required this.fragIdx,
    required this.fragTotal,
    required Uint8List payload,
  })  : senderId = Uint8List.fromList(senderId),
        recipientId = Uint8List.fromList(recipientId),
        payload = Uint8List.fromList(payload) {
    _require(ttl >= 0 && ttl <= maxTtl, 'ttl out of range');
    _require(packetId >= 0 && packetId <= 0xFFFFFFFF, 'packetId out of range');
    _require(senderId.length == _idLength, 'senderId must be 8 bytes');
    _require(recipientId.length == _idLength, 'recipientId must be 8 bytes');
    _require(fragTotal >= 1 && fragTotal <= 255, 'fragTotal must be 1..255');
    _require(fragIdx >= 0 && fragIdx < fragTotal, 'fragIdx must be below fragTotal');
    _require(this.payload.length <= maxPayloadLength, 'payload exceeds $maxPayloadLength bytes');
  }

  static const int headerLength = 26;

  static final Uint8List broadcastId = Uint8List.fromList(List.filled(_idLength, 0xFF));

  final PacketType type;
  final int ttl;
  final int packetId;
  final Uint8List senderId;
  final Uint8List recipientId;
  final int fragIdx;
  final int fragTotal;
  final Uint8List payload;

  bool get isBroadcast => _bytesEqual(recipientId, broadcastId);

  Uint8List encode() {
    final out = Uint8List(headerLength + payload.length);
    final data = ByteData.sublistView(out);
    data.setUint8(0, protocolVersion);
    data.setUint8(1, type.code);
    data.setUint8(2, ttl);
    data.setUint32(3, packetId, Endian.big);
    out.setRange(7, 15, senderId);
    out.setRange(15, 23, recipientId);
    data.setUint8(23, fragIdx);
    data.setUint8(24, fragTotal);
    data.setUint8(25, payload.length);
    out.setRange(headerLength, out.length, payload);
    return out;
  }

  static Packet decode(Uint8List bytes) {
    if (bytes.length < headerLength) {
      throw const PacketFormatException('truncated header');
    }
    final data = ByteData.sublistView(bytes);
    if (data.getUint8(0) != protocolVersion) {
      throw const PacketFormatException('unsupported version');
    }
    final type = PacketType.fromCode(data.getUint8(1));
    if (type == null) {
      throw const PacketFormatException('unknown packet type');
    }
    final declaredLength = data.getUint8(25);
    if (bytes.length != headerLength + declaredLength) {
      throw const PacketFormatException('length field disagrees with frame size');
    }
    try {
      return Packet(
        type: type,
        ttl: data.getUint8(2),
        packetId: data.getUint32(3, Endian.big),
        senderId: Uint8List.sublistView(bytes, 7, 15),
        recipientId: Uint8List.sublistView(bytes, 15, 23),
        fragIdx: data.getUint8(23),
        fragTotal: data.getUint8(24),
        payload: Uint8List.sublistView(bytes, headerLength),
      );
    } on ArgumentError catch (error) {
      throw PacketFormatException('${error.message}');
    }
  }
}

extension BytesHex on Uint8List {
  String get hex => map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

void _require(bool ok, String message) {
  if (!ok) throw ArgumentError(message);
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
