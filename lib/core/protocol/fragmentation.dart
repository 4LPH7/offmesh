import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'packet.dart';

const int _maxFragmentsPerMessage = 255;

/// Splits one application payload into packets that fit the transport's MTU.
class Fragmenter {
  Fragmenter({this.maxPayload = maxPayloadLength}) {
    if (maxPayload < 1 || maxPayload > maxPayloadLength) {
      throw ArgumentError.value(maxPayload, 'maxPayload', 'must be 1..$maxPayloadLength');
    }
  }

  /// Per-transport limit. LAN uses [maxPayloadLength]; BLE uses the negotiated MTU minus headers.
  final int maxPayload;

  List<Packet> fragment({
    required PacketType type,
    required int ttl,
    required int packetId,
    required Uint8List senderId,
    required Uint8List recipientId,
    required Uint8List data,
  }) {
    final count = data.isEmpty ? 1 : (data.length + maxPayload - 1) ~/ maxPayload;
    if (count > _maxFragmentsPerMessage) {
      throw ArgumentError('payload needs $count fragments; the limit is $_maxFragmentsPerMessage');
    }
    return List.generate(count, (index) {
      final start = index * maxPayload;
      final end = math.min(start + maxPayload, data.length);
      return Packet(
        type: type,
        ttl: ttl,
        packetId: packetId,
        senderId: senderId,
        recipientId: recipientId,
        fragIdx: index,
        fragTotal: count,
        payload: Uint8List.sublistView(data, start, end),
      );
    }, growable: false);
  }
}

class _PartialMessage {
  _PartialMessage(this.fragTotal) : parts = List<Uint8List?>.filled(fragTotal, null);

  final int fragTotal;
  final List<Uint8List?> parts;
  int received = 0;
}

/// Rebuilds messages from fragments. Keeps at most [maxInFlight] incomplete messages,
/// evicting the oldest, so a flood of partial messages cannot exhaust memory.
class Reassembler {
  Reassembler({this.maxInFlight = 32});

  final int maxInFlight;
  final LinkedHashMap<String, _PartialMessage> _partials = LinkedHashMap();

  int get inFlightCount => _partials.length;

  /// Returns the full payload once every fragment has arrived, otherwise null.
  Uint8List? add(Packet packet) {
    if (packet.fragTotal == 1) return Uint8List.fromList(packet.payload);

    final key = '${packet.senderId.hex}:${packet.packetId}';
    var partial = _partials[key];
    if (partial != null && partial.fragTotal != packet.fragTotal) {
      // Fragments disagree about the message size: treat the message as hostile and drop it.
      _partials.remove(key);
      return null;
    }
    if (partial == null) {
      if (_partials.length >= maxInFlight) {
        _partials.remove(_partials.keys.first);
      }
      partial = _PartialMessage(packet.fragTotal);
      _partials[key] = partial;
    }
    if (partial.parts[packet.fragIdx] == null) {
      partial.parts[packet.fragIdx] = packet.payload;
      partial.received++;
    }
    if (partial.received < partial.fragTotal) return null;

    _partials.remove(key);
    return _concat(partial.parts);
  }

  static Uint8List _concat(List<Uint8List?> parts) {
    final total = parts.fold<int>(0, (sum, part) => sum + part!.length);
    final out = Uint8List(total);
    var offset = 0;
    for (final part in parts) {
      out.setRange(offset, offset + part!.length, part);
      offset += part.length;
    }
    return out;
  }
}
