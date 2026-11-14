import 'dart:math';
import 'dart:typed_data';

import 'package:offmesh/app/secret_store.dart';
import 'package:offmesh/core/provisioning/unit_roster.dart';

/// One key holds secret and roster together, so a re-import replaces both at once.
const String unitKey = 'unit.roster.v1';

/// The stored unit is unusable. Never carries key bytes.
class UnitStoreException implements Exception {
  const UnitStoreException(this.message);

  final String message;

  @override
  String toString() => 'UnitStoreException: $message';
}

class UnitStore {
  /// The stored unit, or null when this phone is not provisioned. A present but
  /// malformed value throws and is left untouched for the operator to re-import over.
  static Future<UnitRoster?> load(SecretStore store) async {
    final Uint8List? bytes;
    try {
      bytes = await store.read(unitKey);
    } on FormatException {
      throw const UnitStoreException('stored unit is not valid base64');
    }
    if (bytes == null) return null;
    try {
      return UnitRoster.decode(bytes);
    } on RosterFormatException catch (e) {
      throw UnitStoreException('stored unit is damaged: ${e.message}');
    }
  }

  static Future<void> save(SecretStore store, UnitRoster roster) =>
      store.write(unitKey, roster.encode());

  /// A fresh 32-byte unit secret from the platform CSPRNG.
  static Uint8List generateSecret([Random? random]) {
    final rng = random ?? Random.secure();
    return Uint8List.fromList(
      List.generate(unitSecretLength, (_) => rng.nextInt(256)),
    );
  }
}
