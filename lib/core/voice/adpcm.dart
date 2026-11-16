import 'dart:typed_data';

/// IMA ADPCM, 4 bits per sample. Each block carries its own starting state, so a lost
/// block never corrupts the next one.
///
/// Block layout: predictor int16 LE (2) | step index (1) | reserved 0 (1) | nibbles, two
/// samples per byte, low nibble first.
const int adpcmHeaderLength = 4;

const List<int> _indexTable = [
  -1, -1, -1, -1, 2, 4, 6, 8, //
  -1, -1, -1, -1, 2, 4, 6, 8,
];

const List<int> _stepTable = [
  7,
  8,
  9,
  10,
  11,
  12,
  13,
  14,
  16,
  17,
  19,
  21,
  23,
  25,
  28,
  31,
  34,
  37,
  41,
  45, //
  50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230,
  253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963,
  1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327,
  3660,
  4026,
  4428,
  4871,
  5358,
  5894,
  6484,
  7132,
  7845,
  8630,
  9493,
  10442,
  11487,
  12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
];

class AdpcmFormatException implements Exception {
  const AdpcmFormatException(this.message);

  final String message;

  @override
  String toString() => 'AdpcmFormatException: $message';
}

/// Encoder state carried from one block to the next.
class AdpcmEncoder {
  int _predictor = 0;
  int _index = 0;

  /// Encodes [pcm]; an odd sample count leaves the last high nibble zero.
  Uint8List encode(Int16List pcm) {
    final out = Uint8List(adpcmHeaderLength + (pcm.length + 1) ~/ 2);
    ByteData.sublistView(out)
      ..setInt16(0, _predictor, Endian.little)
      ..setUint8(2, _index);
    for (var i = 0; i < pcm.length; i++) {
      final nibble = _encodeSample(pcm[i]);
      final at = adpcmHeaderLength + i ~/ 2;
      out[at] |= i.isEven ? nibble : nibble << 4;
    }
    return out;
  }

  int _encodeSample(int sample) {
    final step = _stepTable[_index];
    var diff = sample - _predictor;
    var nibble = 0;
    if (diff < 0) {
      nibble = 8;
      diff = -diff;
    }
    var delta = step >> 3;
    var mask = 4;
    var tempStep = step;
    for (var i = 0; i < 3; i++) {
      if (diff >= tempStep) {
        nibble |= mask;
        diff -= tempStep;
        delta += tempStep;
      }
      mask >>= 1;
      tempStep >>= 1;
    }
    _predictor = _clampSample(
      (nibble & 8) != 0 ? _predictor - delta : _predictor + delta,
    );
    _index = (_index + _indexTable[nibble]).clamp(0, _stepTable.length - 1);
    return nibble;
  }
}

/// Decodes one block made by [AdpcmEncoder.encode] into [sampleCount] samples.
Int16List decodeAdpcm(Uint8List block, int sampleCount) {
  if (block.length < adpcmHeaderLength) {
    throw const AdpcmFormatException('block shorter than its header');
  }
  if (block.length - adpcmHeaderLength < (sampleCount + 1) ~/ 2) {
    throw const AdpcmFormatException('block shorter than its samples');
  }
  final header = ByteData.sublistView(block);
  var predictor = header.getInt16(0, Endian.little);
  var index = header.getUint8(2);
  if (index >= _stepTable.length) {
    throw const AdpcmFormatException('step index out of range');
  }
  final out = Int16List(sampleCount);
  for (var i = 0; i < sampleCount; i++) {
    final byte = block[adpcmHeaderLength + i ~/ 2];
    final nibble = i.isEven ? byte & 0x0F : byte >> 4;
    final step = _stepTable[index];
    var delta = step >> 3;
    if ((nibble & 4) != 0) delta += step;
    if ((nibble & 2) != 0) delta += step >> 1;
    if ((nibble & 1) != 0) delta += step >> 2;
    predictor = _clampSample(
      (nibble & 8) != 0 ? predictor - delta : predictor + delta,
    );
    index = (index + _indexTable[nibble]).clamp(0, _stepTable.length - 1);
    out[i] = predictor;
  }
  return out;
}

int _clampSample(int value) => value.clamp(-32768, 32767);
