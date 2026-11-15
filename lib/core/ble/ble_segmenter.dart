import 'dart:typed_data';

/// ATT header bytes subtracted from the MTU for every write or notification.
const int attOverhead = 3;

/// Smallest ATT MTU (BLE default) and largest (BLE 4.2 maximum).
const int minAttMtu = 23;
const int maxAttMtu = 517;

/// Chunk header: index (u8), total (u8), message id (u16, big-endian).
const int bleChunkHeaderLength = 4;

/// The header's chunk count is one byte, so one frame spans at most this many chunks.
const int maxChunksPerFrame = 255;

/// Largest sealed frame accepted. Matches the LAN frame cap.
const int maxBleFrameLength = 512;

/// Data bytes one chunk can carry at [mtu].
int chunkDataLength(int mtu) {
  if (mtu < minAttMtu || mtu > maxAttMtu) {
    throw ArgumentError.value(mtu, 'mtu', 'must be $minAttMtu..$maxAttMtu');
  }
  return mtu - attOverhead - bleChunkHeaderLength;
}

/// Splits one sealed frame into chunks that each fit a single ATT write at [mtu].
List<Uint8List> segmentFrame(Uint8List frame, int mtu, int messageId) {
  if (frame.isEmpty) throw ArgumentError('frame is empty');
  if (frame.length > maxBleFrameLength) {
    throw ArgumentError(
      'frame is ${frame.length} bytes; the limit is $maxBleFrameLength',
    );
  }
  final data = chunkDataLength(mtu);
  final count = (frame.length + data - 1) ~/ data;
  if (count > maxChunksPerFrame) {
    throw ArgumentError(
      'frame needs $count chunks; the limit is $maxChunksPerFrame',
    );
  }
  return List<Uint8List>.generate(count, (index) {
    final start = index * data;
    final end = start + data < frame.length ? start + data : frame.length;
    final chunk = Uint8List(bleChunkHeaderLength + end - start)
      ..[0] = index
      ..[1] = count;
    ByteData.sublistView(chunk).setUint16(2, messageId & 0xFFFF, Endian.big);
    chunk.setRange(bleChunkHeaderLength, chunk.length, frame, start);
    return chunk;
  }, growable: false);
}
