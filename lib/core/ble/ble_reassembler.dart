import 'dart:collection';
import 'dart:typed_data';

import 'ble_segmenter.dart';

/// Thrown for a chunk that cannot belong to any frame. Links treat it as a protocol error.
class BleFramingException implements Exception {
  const BleFramingException(this.message);

  final String message;

  @override
  String toString() => 'BleFramingException: $message';
}

class _Partial {
  _Partial(this.total, this.createdAt)
    : parts = List<Uint8List?>.filled(total, null);

  final int total;
  final DateTime createdAt;
  final List<Uint8List?> parts;
  int received = 0;
}

/// Rebuilds sealed frames from chunks. Bounded memory: at most [maxInFlight] partial
/// frames (oldest evicted) and partials older than [timeout] are dropped.
class BleReassembler {
  BleReassembler({
    DateTime Function()? clock,
    this.timeout = const Duration(seconds: 10),
    this.maxInFlight = 32,
  }) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final Duration timeout;
  final int maxInFlight;
  final LinkedHashMap<int, _Partial> _partials = LinkedHashMap();

  int get inFlightCount => _partials.length;

  /// Returns the whole frame once its last chunk arrives, otherwise null.
  /// [maxChunkLength] is the link's ATT write limit (MTU - 3).
  Uint8List? add(Uint8List chunk, {required int maxChunkLength}) {
    if (chunk.length < bleChunkHeaderLength) {
      throw const BleFramingException('chunk shorter than its header');
    }
    if (chunk.length > maxChunkLength) {
      throw const BleFramingException('chunk longer than the link MTU');
    }
    final index = chunk[0];
    final total = chunk[1];
    if (total == 0) throw const BleFramingException('chunk total is zero');
    if (index >= total) {
      throw const BleFramingException('chunk index past total');
    }
    final messageId = ByteData.sublistView(chunk).getUint16(2, Endian.big);
    final now = _clock();
    _expire(now);

    var partial = _partials[messageId];
    if (partial != null && partial.total != total) {
      _partials.remove(messageId);
      return null;
    }
    if (partial == null) {
      if (_partials.length >= maxInFlight) {
        _partials.remove(_partials.keys.first);
      }
      partial = _Partial(total, now);
      _partials[messageId] = partial;
    }
    if (partial.parts[index] == null) {
      // Copied: the caller may reuse the buffer it passed in.
      partial.parts[index] = Uint8List.fromList(
        chunk.sublist(bleChunkHeaderLength),
      );
      partial.received++;
    }
    if (partial.received < partial.total) return null;

    _partials.remove(messageId);
    final frame = _concat(partial.parts);
    if (frame.length > maxBleFrameLength) {
      throw const BleFramingException('reassembled frame over the size limit');
    }
    return frame;
  }

  void _expire(DateTime now) {
    _partials.removeWhere((_, p) => now.difference(p.createdAt) > timeout);
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
