import 'dart:typed_data';

/// Largest frame body on a LAN socket. A mesh packet is at most 26 + 220 bytes, so this
/// leaves room and still caps what a hostile peer can make us buffer.
const int maxFrameLength = 512;

const int _headerLength = 2;

/// Prefixes [body] with its length as a 2-byte big-endian integer.
Uint8List encodeFrame(Uint8List body) {
  if (body.length > maxFrameLength) {
    throw ArgumentError.value(body.length, 'body', 'exceeds $maxFrameLength bytes');
  }
  final out = Uint8List(_headerLength + body.length);
  out.buffer.asByteData().setUint16(0, body.length, Endian.big);
  out.setRange(_headerLength, out.length, body);
  return out;
}

/// Reassembles length-prefixed frames from an arbitrarily chunked byte stream.
class FrameDecoder {
  final List<int> _buffer = [];

  /// Appends [chunk] and returns every frame body that is now complete.
  List<Uint8List> add(List<int> chunk) {
    _buffer.addAll(chunk);
    final frames = <Uint8List>[];
    while (_buffer.length >= _headerLength) {
      final length = (_buffer[0] << 8) | _buffer[1];
      if (length > maxFrameLength) {
        throw const FormatException('frame length exceeds the limit');
      }
      if (_buffer.length < _headerLength + length) break;
      frames.add(Uint8List.fromList(_buffer.sublist(_headerLength, _headerLength + length)));
      _buffer.removeRange(0, _headerLength + length);
    }
    return frames;
  }
}
