import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const int peerIdLength = 8;
const int x25519SeedLength = 32;

/// PeerID: the first 8 bytes of SHA-256 over the static X25519 public key.
Future<Uint8List> peerIdFor(List<int> publicKey) async {
  final digest = await Sha256().hash(publicKey);
  return Uint8List.fromList(digest.bytes.sublist(0, peerIdLength));
}

/// A device's long-term identity: one static X25519 key pair plus its PeerID.
class Identity {
  Identity._({
    required this.keyPair,
    required this.publicKey,
    required this.peerId,
  });

  final SimpleKeyPair keyPair;
  final Uint8List publicKey;
  final Uint8List peerId;

  static Future<Identity> generate() async {
    return fromKeyPair(await X25519().newKeyPair());
  }

  /// Rebuilds an identity from a stored 32-byte X25519 private seed.
  static Future<Identity> fromPrivateKey(List<int> seed) async {
    if (seed.length != x25519SeedLength) {
      throw ArgumentError('X25519 private key must be $x25519SeedLength bytes');
    }
    return fromKeyPair(await X25519().newKeyPairFromSeed(seed));
  }

  /// The 32-byte private seed, for writing to the secure store only.
  Future<Uint8List> privateSeed() async =>
      Uint8List.fromList(await keyPair.extractPrivateKeyBytes());

  static Future<Identity> fromKeyPair(SimpleKeyPair keyPair) async {
    final publicKey = Uint8List.fromList(
      (await keyPair.extractPublicKey()).bytes,
    );
    return Identity._(
      keyPair: keyPair,
      publicKey: publicKey,
      peerId: await peerIdFor(publicKey),
    );
  }
}
