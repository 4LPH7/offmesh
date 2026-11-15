import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/ble/ble_reassembler.dart';
import 'package:offmesh/core/ble/ble_segmenter.dart';

Uint8List _frame(int length) =>
    Uint8List.fromList(List<int>.generate(length, (i) => (i * 7 + 3) & 0xFF));

void main() {
  late DateTime now;
  late BleReassembler reassembler;

  setUp(() {
    now = DateTime.utc(2026, 11, 15);
    reassembler = BleReassembler(
      clock: () => now,
      timeout: const Duration(seconds: 10),
    );
  });

  Uint8List chunk(int index, int total, int id, List<int> data) =>
      Uint8List.fromList([index, total, id >> 8, id & 0xFF, ...data]);

  test('whole frame returned once every chunk arrives, in any order', () {
    final frame = _frame(40);
    final chunks = segmentFrame(frame, 23, 0x1234);
    expect(chunks.length, greaterThan(2));

    Uint8List? out;
    for (final c in chunks.reversed) {
      out = reassembler.add(c, maxChunkLength: 20);
    }
    expect(out, frame);
  });

  test('a duplicate chunk is ignored', () {
    final frame = _frame(30);
    final chunks = segmentFrame(frame, 23, 9);
    expect(reassembler.add(chunks[0], maxChunkLength: 20), isNull);
    expect(reassembler.add(chunks[0], maxChunkLength: 20), isNull);
    expect(reassembler.add(chunks[1], maxChunkLength: 20), frame);
  });

  test('a missing chunk times out and the late chunk starts nothing', () {
    final frame = _frame(30);
    final chunks = segmentFrame(frame, 23, 5);
    expect(reassembler.add(chunks[0], maxChunkLength: 20), isNull);

    now = now.add(const Duration(seconds: 11));
    expect(reassembler.add(chunks[1], maxChunkLength: 20), isNull);
    expect(
      reassembler.inFlightCount,
      1,
      reason: 'only the new partial remains',
    );
  });

  test('a total that disagrees with the partial drops that partial', () {
    expect(reassembler.add(chunk(0, 2, 1, [1]), maxChunkLength: 20), isNull);
    expect(reassembler.add(chunk(1, 3, 1, [2]), maxChunkLength: 20), isNull);
    expect(reassembler.inFlightCount, 0);
  });

  test('the oldest partial is evicted once maxInFlight is reached', () {
    reassembler = BleReassembler(clock: () => now, maxInFlight: 2);
    expect(reassembler.add(chunk(0, 2, 1, [1]), maxChunkLength: 20), isNull);
    expect(reassembler.add(chunk(0, 2, 2, [1]), maxChunkLength: 20), isNull);
    expect(reassembler.add(chunk(0, 2, 3, [1]), maxChunkLength: 20), isNull);
    expect(reassembler.inFlightCount, 2);
    expect(
      reassembler.add(chunk(1, 2, 1, [2]), maxChunkLength: 20),
      isNull,
      reason: 'message 1 was evicted',
    );
  });

  test('a chunk shorter than its header is rejected', () {
    expect(
      () => reassembler.add(Uint8List.fromList([0, 1, 0]), maxChunkLength: 20),
      throwsA(isA<BleFramingException>()),
    );
  });

  test('a chunk total of zero, or an index past the total, is rejected', () {
    expect(
      () => reassembler.add(chunk(0, 0, 1, [1]), maxChunkLength: 20),
      throwsA(isA<BleFramingException>()),
    );
    expect(
      () => reassembler.add(chunk(2, 2, 1, [1]), maxChunkLength: 20),
      throwsA(isA<BleFramingException>()),
    );
  });

  test('a chunk longer than the link write limit is rejected', () {
    expect(
      () => reassembler.add(
        chunk(0, 1, 1, List.filled(30, 1)),
        maxChunkLength: 20,
      ),
      throwsA(isA<BleFramingException>()),
    );
  });

  test('a completed frame over the 512-byte limit is rejected', () {
    final big = List.filled(300, 1);
    expect(reassembler.add(chunk(0, 2, 1, big), maxChunkLength: 400), isNull);
    expect(
      () => reassembler.add(chunk(1, 2, 1, big), maxChunkLength: 400),
      throwsA(isA<BleFramingException>()),
    );
  });

  test('the buffer passed in can be reused after add', () {
    final frame = _frame(30);
    final chunks = segmentFrame(frame, 23, 7);
    final scratch = Uint8List.fromList(chunks[0]);
    expect(reassembler.add(scratch, maxChunkLength: 20), isNull);
    scratch.fillRange(0, scratch.length, 0xEE);
    expect(reassembler.add(chunks[1], maxChunkLength: 20), frame);
  });
}
