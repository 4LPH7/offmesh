import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/transports/lan_frame.dart';

void main() {
  test('encodes a body behind a 2-byte big-endian length', () {
    final frame = encodeFrame(Uint8List.fromList([7, 8, 9]));

    expect(frame, [0, 3, 7, 8, 9]);
  });

  test('decodes a frame that arrives in one chunk', () {
    final decoder = FrameDecoder();

    final frames = decoder.add(encodeFrame(Uint8List.fromList([1, 2])));

    expect(frames, [
      [1, 2],
    ]);
  });

  test('reassembles a frame split across chunks', () {
    final decoder = FrameDecoder();
    final bytes = encodeFrame(Uint8List.fromList([1, 2, 3, 4]));

    expect(decoder.add(bytes.sublist(0, 3)), isEmpty);
    expect(decoder.add(bytes.sublist(3)), [
      [1, 2, 3, 4],
    ]);
  });

  test('returns several frames delivered in one chunk, in order', () {
    final decoder = FrameDecoder();
    final chunk = [
      ...encodeFrame(Uint8List.fromList([1])),
      ...encodeFrame(Uint8List.fromList([2, 2])),
    ];

    expect(decoder.add(chunk), [
      [1],
      [2, 2],
    ]);
  });

  test('refuses to encode a body over the frame limit', () {
    expect(
      () => encodeFrame(Uint8List(maxFrameLength + 1)),
      throwsArgumentError,
    );
  });

  test('a declared length over the limit is rejected before buffering it', () {
    final decoder = FrameDecoder();
    final header = Uint8List(2)
      ..buffer.asByteData().setUint16(0, maxFrameLength + 1);

    expect(() => decoder.add(header), throwsFormatException);
  });
}
