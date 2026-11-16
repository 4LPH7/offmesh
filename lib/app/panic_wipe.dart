import 'channel_store.dart';
import 'secret_store.dart';
import 'identity_store.dart';
import 'posture_store.dart';
import 'unit_store.dart';

/// Every key this app writes to the secret store. Add a key here when a store adds one.
const List<String> storedSecretKeys = [
  unitKey,
  identityKey,
  postureKey,
  channelsKey,
];

/// Deletes every stored key. A failed delete does not stop the others; the first
/// failure is rethrown once all keys have been tried, so no key is left behind by a
/// single error.
Future<void> wipeStoredSecrets(SecretStore store) async {
  var failed = false;
  for (final key in storedSecretKeys) {
    try {
      await store.delete(key);
    } catch (_) {
      failed = true;
    }
  }
  if (failed) throw StateError('could not delete every stored key');
}
