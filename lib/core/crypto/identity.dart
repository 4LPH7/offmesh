import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const int peerIdLength = 8;

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

  static Future<Identity> fromKeyPair(SimpleKeyPair keyPair) async {
    final publicKey = Uint8List.fromList((await keyPair.extractPublicKey()).bytes);
    return Identity._(
      keyPair: keyPair,
      publicKey: publicKey,
      peerId: await peerIdFor(publicKey),
    );
  }
}
