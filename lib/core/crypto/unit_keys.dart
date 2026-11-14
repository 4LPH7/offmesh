import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Shortest unit secret accepted (bytes).
const int minUnitSecretBytes = 32;

/// Length of each derived key (bytes).
const int unitKeyLength = 32;

final List<int> _sealInfo = utf8.encode('offmesh/seal/v1');
final List<int> _idInfo = utf8.encode('offmesh/id/v1');

/// Keys derived from the shared unit secret. Each serves one purpose only, so the
/// seal key never doubles as the rotating-ID key and neither is the raw secret.
class UnitKeys {
  const UnitKeys._(this.sealKey, this.idKey);

  /// Key for `SealedEnvelope`.
  final Uint8List sealKey;

  /// Key for rotating discovery IDs (`rotatingId`, `RosterResolver`).
  final Uint8List idKey;

  /// HKDF-SHA256 with an empty salt and a distinct info label per key.
  static Future<UnitKeys> derive(List<int> unitSecret) async {
    if (unitSecret.length < minUnitSecretBytes) {
      throw ArgumentError(
        'unitSecret must be at least $minUnitSecretBytes bytes',
      );
    }
    return UnitKeys._(
      await _expand(unitSecret, _sealInfo),
      await _expand(unitSecret, _idInfo),
    );
  }

  static Future<Uint8List> _expand(List<int> secret, List<int> info) async {
    final key = await Hkdf(hmac: Hmac.sha256(), outputLength: unitKeyLength)
        .deriveKey(
          secretKey: SecretKey(List<int>.of(secret)),
          nonce: const <int>[],
          info: info,
        );
    return Uint8List.fromList(await key.extractBytes());
  }
}
