import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/ble/ble_reassembler.dart';
import 'package:offmesh/core/ble/ble_segmenter.dart';
import 'package:offmesh/core/crypto/unit_keys.dart';
import 'package:offmesh/core/protocol/sealed_envelope.dart';

Uint8List _bytes(int length, [int seed = 1]) =>
    Uint8List.fromList(List.generate(length, (i) => (i * 31 + seed) & 0xFF));

BleReassembler _reassembler([DateTime Function()? clock]) =>
    BleReassembler(clock: clock);

Uint8List? _feedAll(BleReassembler r, List<Uint8List> chunks, int mtu) {
  Uint8List? out;
  for (final c in chunks) {
    out = r.add(c, maxChunkLength: mtu - attOverhead) ?? out;
  }
  return out;
}

void main() {
  group('round trip', () {
    for (final mtu in [23, 64, 251, 517]) {
      for (final size in [1, 16, 17, 100, 512]) {
        test('frame of $size bytes at MTU $mtu', () {
          final frame = _bytes(size, mtu);
          final chunks = segmentFrame(frame, mtu, 7);
          for (final c in chunks) {
            expect(c.length, lessThanOrEqualTo(mtu - attOverhead));
          }
          final out = _feedAll(_reassembler(), chunks, mtu);
          expect(out, frame);
        });
      }
    }
  });

  test(
    '512-byte sealed frame is byte-identical after round trip at MTU 23',
    () async {
      final keys = await UnitKeys.derive(List<int>.filled(32, 9));
      final envelope = SealedEnvelope(keys.sealKey);
      final sealed = await envelope.seal(_bytes(512 - sealOverhead));
      expect(sealed.length, 512);

      final out = _feedAll(_reassembler(), segmentFrame(sealed, 23, 1), 23);
      expect(out, sealed);
      expect(await envelope.open(out!), await envelope.open(sealed));
    },
  );

  test('reordered chunks reassemble', () {
    final frame = _bytes(200);
    final chunks = segmentFrame(frame, 23, 3).reversed.toList();
    expect(_feedAll(_reassembler(), chunks, 23), frame);
  });

  test('duplicate chunk is ignored and the frame completes once', () {
    final frame = _bytes(60);
    final chunks = segmentFrame(frame, 23, 4);
    final r = _reassembler();
    expect(r.add(chunks[0], maxChunkLength: 20), isNull);
    expect(r.add(chunks[0], maxChunkLength: 20), isNull);
    Uint8List? out;
    for (var i = 1; i < chunks.length; i++) {
      out = r.add(chunks[i], maxChunkLength: 20) ?? out;
    }
    expect(out, frame);
    expect(r.inFlightCount, 0);
  });

  test('a missing chunk times out and never completes', () {
    var now = DateTime.utc(2026, 1, 1);
    final r = _reassembler(() => now);
    final chunks = segmentFrame(_bytes(60), 23, 5);
    expect(r.add(chunks[0], maxChunkLength: 20), isNull);
    now = now.add(const Duration(seconds: 11));
    for (var i = 1; i < chunks.length; i++) {
      expect(r.add(chunks[i], maxChunkLength: 20), isNull);
    }
    expect(r.inFlightCount, 1, reason: 'only the post-timeout partial remains');
  });

  test('oversize frame is rejected by the segmenter', () {
    expect(
      () => segmentFrame(_bytes(maxBleFrameLength + 1), 23, 0),
      throwsArgumentError,
    );
    expect(
      () => segmentFrame(_bytes(maxBleFrameLength), 517, 0),
      returnsNormally,
    );
  });

  test('bad MTU is rejected', () {
    expect(() => segmentFrame(_bytes(10), 22, 0), throwsArgumentError);
    expect(() => segmentFrame(_bytes(10), 518, 0), throwsArgumentError);
  });

  test('malformed chunks throw BleFramingException', () {
    final r = _reassembler();
    expect(
      () => r.add(Uint8List(3), maxChunkLength: 20),
      throwsA(isA<BleFramingException>()),
    );
    expect(
      () => r.add(Uint8List.fromList([0, 0, 0, 0, 9]), maxChunkLength: 20),
      throwsA(isA<BleFramingException>()),
      reason: 'total zero',
    );
    expect(
      () => r.add(Uint8List.fromList([2, 2, 0, 0, 9]), maxChunkLength: 20),
      throwsA(isA<BleFramingException>()),
      reason: 'index past total',
    );
    expect(
      () => r.add(Uint8List(30), maxChunkLength: 20),
      throwsA(isA<BleFramingException>()),
      reason: 'over MTU',
    );
  });
}
