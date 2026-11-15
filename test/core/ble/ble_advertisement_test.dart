import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/ble/ble_advertisement.dart';

void main() {
  final id = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);

  test('advertisement is 29 bytes, within the 31-byte legacy limit', () {
    final adv = encodeAdvertisement(id);
    expect(adv.length, advertisementLength);
    expect(adv.length, lessThanOrEqualTo(31));
  });

  test('parse returns the rotating ID that was encoded', () {
    expect(parseRotatingId(encodeAdvertisement(id)), id);
  });

  test('advertisement has only flags and service data, no name', () {
    final adv = encodeAdvertisement(id);
    final types = <int>[];
    var i = 0;
    while (i < adv.length) {
      types.add(adv[i + 1]);
      i += 1 + adv[i];
    }
    expect(types, [0x01, 0x21]);
  });

  test('a different service UUID is not parsed', () {
    final adv = encodeAdvertisement(id);
    adv[5] ^= 0xFF;
    expect(parseRotatingId(adv), isNull);
  });

  test('truncated or empty input returns null', () {
    final adv = encodeAdvertisement(id);
    expect(parseRotatingId(adv.sublist(0, 10)), isNull);
    expect(parseRotatingId(const []), isNull);
  });

  test('wrong ID length is rejected', () {
    expect(() => encodeAdvertisement(Uint8List(7)), throwsArgumentError);
  });
}
