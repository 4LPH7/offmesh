import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/crypto/unit_keys.dart';

/// RFC 5869 HKDF-SHA256 written out with plain HMAC, so the test does not trust the
/// library's Hkdf to check itself. Empty salt means a zero-filled 32-byte salt.
Future<List<int>> _referenceHkdf(List<int> ikm, String info) async {
  final hmac = Hmac.sha256();
  final prk = await hmac.calculateMac(
    ikm,
    secretKey: SecretKey(List.filled(32, 0)),
  );
  final t1 = await hmac.calculateMac([
    ...utf8.encode(info),
    1,
  ], secretKey: SecretKey(prk.bytes));
  return t1.bytes;
}

void main() {
  final secret = List<int>.generate(32, (i) => i);

  test('matches an independent RFC 5869 computation', () async {
    final keys = await UnitKeys.derive(secret);
    expect(keys.sealKey, await _referenceHkdf(secret, 'offmesh/seal/v1'));
    expect(keys.idKey, await _referenceHkdf(secret, 'offmesh/id/v1'));
  });

  test(
    'keys are 32 bytes, differ from each other and from the secret',
    () async {
      final keys = await UnitKeys.derive(secret);
      expect(keys.sealKey.length, unitKeyLength);
      expect(keys.idKey.length, unitKeyLength);
      expect(keys.sealKey, isNot(keys.idKey));
      expect(keys.sealKey, isNot(secret));
      expect(keys.idKey, isNot(secret));
    },
  );

  test('a different secret gives different keys', () async {
    final a = await UnitKeys.derive(secret);
    final b = await UnitKeys.derive(List<int>.generate(32, (i) => i + 1));
    expect(a.sealKey, isNot(b.sealKey));
    expect(a.idKey, isNot(b.idKey));
  });

  test('rejects a secret shorter than 32 bytes', () {
    expect(() => UnitKeys.derive(List.filled(31, 7)), throwsArgumentError);
  });
}
