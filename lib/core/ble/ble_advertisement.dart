import 'dart:typed_data';

import '../crypto/rotating_id.dart';

/// Fixed custom service UUID (provisional until the spike confirms the scan filter).
/// Stored big-endian here; advertisements carry it little-endian.
const List<int> offmeshServiceUuid = [
  0x4f,
  0x66,
  0x66,
  0x4d,
  0x65,
  0x73,
  0x68,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x01,
];

const int _flagsType = 0x01;
const int _serviceDataType = 0x21; // Service Data, 128-bit UUID
const int _flagsValue = 0x06; // LE General Discoverable, BR/EDR not supported

/// Legacy advertisement: flags (3) + service data (2 + 16 + 8) = 29 bytes, within 31.
const int advertisementLength = 3 + 2 + 16 + rotatingIdLength;

/// Builds the advertisement: the rotating ID under [offmeshServiceUuid] and nothing else.
Uint8List encodeAdvertisement(Uint8List rotatingIdBytes) {
  if (rotatingIdBytes.length != rotatingIdLength) {
    throw ArgumentError('rotating ID must be $rotatingIdLength bytes');
  }
  final out = Uint8List(advertisementLength);
  out[0] = 2;
  out[1] = _flagsType;
  out[2] = _flagsValue;
  out[3] = 1 + 16 + rotatingIdLength;
  out[4] = _serviceDataType;
  for (var i = 0; i < 16; i++) {
    out[5 + i] = offmeshServiceUuid[15 - i];
  }
  out.setRange(21, 21 + rotatingIdLength, rotatingIdBytes);
  return out;
}

/// Returns the rotating ID from an advertisement or raw scan bytes, or null when the
/// service data for [offmeshServiceUuid] is absent or malformed. Other AD structures are skipped.
Uint8List? parseRotatingId(List<int> advertisement) {
  var i = 0;
  while (i < advertisement.length) {
    final length = advertisement[i];
    if (length == 0) break;
    final end = i + 1 + length;
    if (end > advertisement.length) return null;
    if (advertisement[i + 1] == _serviceDataType &&
        length == 1 + 16 + rotatingIdLength &&
        _uuidMatches(advertisement, i + 2)) {
      return Uint8List.fromList(
        advertisement.sublist(i + 2 + 16, i + 2 + 16 + rotatingIdLength),
      );
    }
    i = end;
  }
  return null;
}

bool _uuidMatches(List<int> bytes, int start) {
  for (var i = 0; i < 16; i++) {
    if (bytes[start + i] != offmeshServiceUuid[15 - i]) return false;
  }
  return true;
}
