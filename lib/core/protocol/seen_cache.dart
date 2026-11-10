import 'dart:collection';

import 'packet.dart';

const int defaultSeenCapacity = 2048;
const Duration defaultSeenWindow = Duration(seconds: 300);

/// Remembers recently forwarded packets so a flooded mesh does not relay them twice.
///
/// Keyed on (sender, packetId, fragIdx): fragments of one message share a packetId,
/// so keying on packetId alone would drop every fragment after the first.
class SeenCache {
  SeenCache({
    this.capacity = defaultSeenCapacity,
    this.window = defaultSeenWindow,
    required DateTime Function() clock,
  }) : _clock = clock;

  final int capacity;
  final Duration window;
  final DateTime Function() _clock;

  final LinkedHashMap<String, DateTime> _seen = LinkedHashMap();

  int get length => _seen.length;

  /// Returns true if this packet was seen within [window]; otherwise records it and returns false.
  bool isDuplicate(Packet packet) {
    final now = _clock();
    _dropExpired(now);

    final key = '${packet.senderId.hex}:${packet.packetId}:${packet.fragIdx}';
    if (_seen.containsKey(key)) return true;

    if (_seen.length >= capacity) {
      _seen.remove(_seen.keys.first);
    }
    _seen[key] = now;
    return false;
  }

  void _dropExpired(DateTime now) {
    while (_seen.isNotEmpty && now.difference(_seen.values.first) > window) {
      _seen.remove(_seen.keys.first);
    }
  }
}
