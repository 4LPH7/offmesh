import 'package:offmesh/app/secret_store.dart';
import 'package:offmesh/core/crypto/identity.dart';

const String identityKey = 'identity.x25519.v1';

/// Startup cannot continue: the stored identity is unusable. Never carries key bytes.
class IdentityStoreException implements Exception {
  const IdentityStoreException(this.message);

  final String message;

  @override
  String toString() => 'IdentityStoreException: $message';
}

class IdentityStore {
  /// Loads the device identity, creating and storing one on first launch.
  /// A present but malformed value throws and is left untouched, since
  /// replacing it would change this device's PeerID. Write errors propagate.
  static Future<Identity> loadOrCreate(SecretStore store) async {
    final List<int>? seed;
    try {
      seed = await store.read(identityKey);
    } on FormatException {
      throw const IdentityStoreException('stored identity is not valid base64');
    }
    if (seed == null) {
      final identity = await Identity.generate();
      await store.write(identityKey, await identity.privateSeed());
      return identity;
    }
    if (seed.length != x25519SeedLength) {
      throw IdentityStoreException(
        'stored identity has ${seed.length} bytes, expected $x25519SeedLength',
      );
    }
    return Identity.fromPrivateKey(seed);
  }
}
