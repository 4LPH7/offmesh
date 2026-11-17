import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../crypto/unit_keys.dart' show minUnitSecretBytes;

/// Length of the room ID a relay sees.
const int rendezvousIdLength = 16;

/// Whole UTC days since 1970. The room changes at 00:00 UTC.
int epochDay(DateTime time) =>
    time.toUtc().millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;

/// The relay room for this unit on [day]: HKDF-SHA256 over the unit secret, so only unit
/// members can compute it, and it changes every day so the relay cannot follow a unit
/// from one day to the next. Phones whose clocks sit on opposite sides of midnight UTC
/// land in different rooms until both pass it.
Future<Uint8List> rendezvousId(List<int> unitSecret, int day) async {
  if (unitSecret.length < minUnitSecretBytes) {
    throw ArgumentError(
      'unitSecret must be at least $minUnitSecretBytes bytes',
    );
  }
  if (day < 0) throw ArgumentError.value(day, 'day', 'must be >= 0');
  final derived =
      await Hkdf(
        hmac: Hmac.sha256(),
        outputLength: rendezvousIdLength,
      ).deriveKey(
        secretKey: SecretKey(List<int>.of(unitSecret)),
        nonce: const <int>[],
        info: utf8.encode('offmesh/rendezvous/v1/$day'),
      );
  return Uint8List.fromList(await derived.extractBytes());
}
