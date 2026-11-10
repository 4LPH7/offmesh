import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/protocol/packet.dart';
import 'package:offmesh/core/protocol/seen_cache.dart';

Packet _packet({int packetId = 1, int fragIdx = 0, int sender = 0x11}) {
  return Packet(
    type: PacketType.announce,
    ttl: 7,
    packetId: packetId,
    senderId: Uint8List.fromList(List.filled(8, sender)),
    recipientId: Packet.broadcastId,
    fragIdx: fragIdx,
    fragTotal: 3,
    payload: Uint8List(0),
  );
}

void main() {
  late DateTime now;
  DateTime clock() => now;

  setUp(() => now = DateTime.utc(2026, 11, 10));

  test('the first sighting is new and a repeat is a duplicate', () {
    final cache = SeenCache(clock: clock);

    expect(cache.isDuplicate(_packet()), isFalse);
    expect(cache.isDuplicate(_packet()), isTrue);
  });

  test('each fragment of one message is new, so no fragment is dropped', () {
    final cache = SeenCache(clock: clock);

    expect(cache.isDuplicate(_packet(fragIdx: 0)), isFalse);
    expect(cache.isDuplicate(_packet(fragIdx: 1)), isFalse);
    expect(cache.isDuplicate(_packet(fragIdx: 2)), isFalse);
  });

  test('the same packet id from a different sender is not a duplicate', () {
    final cache = SeenCache(clock: clock);

    cache.isDuplicate(_packet(sender: 0x11));

    expect(cache.isDuplicate(_packet(sender: 0x22)), isFalse);
  });

  test('a sighting expires after the 300 second window', () {
    final cache = SeenCache(clock: clock);
    cache.isDuplicate(_packet());

    now = now.add(const Duration(seconds: 301));

    expect(cache.isDuplicate(_packet()), isFalse);
  });

  test('a sighting is still a duplicate just before it expires', () {
    final cache = SeenCache(clock: clock);
    cache.isDuplicate(_packet());

    now = now.add(const Duration(seconds: 299));

    expect(cache.isDuplicate(_packet()), isTrue);
  });

  test('evicts the oldest entry when full', () {
    final cache = SeenCache(capacity: 2, clock: clock);
    cache.isDuplicate(_packet(packetId: 1));
    cache.isDuplicate(_packet(packetId: 2));
    cache.isDuplicate(_packet(packetId: 3));

    expect(cache.length, 2);
    expect(cache.isDuplicate(_packet(packetId: 1)), isFalse);
  });
}
