import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../crypto/unit_keys.dart' show minUnitSecretBytes;

/// Bytes on the wire that name a channel, inside the link seal. Derived, never the name.
const int channelTagLength = 8;
const int channelNonceLength = 12;
const int channelMacLength = 16;

/// Sender counter carried inside the ciphertext, for the per-sender replay window.
const int channelCounterLength = 8;

/// Bytes a channel message adds on top of its text.
const int channelOverhead =
    channelTagLength +
    channelNonceLength +
    channelCounterLength +
    channelMacLength;

/// Longest channel name, in UTF-8 bytes after trimming and lower-casing.
const int maxChannelNameBytes = 24;

final Chacha20 _aead = Chacha20.poly1305Aead();
final Random _random = Random.secure();

class ChannelFormatException implements Exception {
  const ChannelFormatException(this.message);

  final String message;

  @override
  String toString() => 'ChannelFormatException: $message';
}

/// Names compare case-insensitively and ignore surrounding spaces.
String normalizeChannelName(String name) {
  final clean = name.trim().toLowerCase();
  if (clean.isEmpty) {
    throw const ChannelFormatException('channel name is empty');
  }
  if (utf8.encode(clean).length > maxChannelNameBytes) {
    throw const ChannelFormatException(
      'channel name is longer than $maxChannelNameBytes bytes',
    );
  }
  return clean;
}

/// A channel's key and wire tag, both derived from the unit secret and the channel name,
/// so every unit member who types the same name lands on the same channel and nobody
/// outside the unit can open it.
///
/// Limit: the key is shared by the whole channel. A member can open every message on it
/// and could write one that claims another member's sender ID; per-sender signatures are
/// not built.
class ChannelKey {
  const ChannelKey._(this.name, this.key, this.tag);

  final String name;
  final Uint8List key;
  final Uint8List tag;

  String get tagHex =>
      tag.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// HKDF-SHA256, empty salt, separate info labels for the key and the tag.
  static Future<ChannelKey> derive(List<int> unitSecret, String name) async {
    if (unitSecret.length < minUnitSecretBytes) {
      throw ArgumentError(
        'unitSecret must be at least $minUnitSecretBytes bytes',
      );
    }
    final clean = normalizeChannelName(name);
    final key = await _hkdf(unitSecret, 'offmesh/channel/v1/$clean', 32);
    final tag = await _hkdf(
      unitSecret,
      'offmesh/channel-tag/v1/$clean',
      channelTagLength,
    );
    return ChannelKey._(clean, key, tag);
  }

  static Future<Uint8List> _hkdf(
    List<int> secret,
    String info,
    int length,
  ) async {
    final derived = await Hkdf(hmac: Hmac.sha256(), outputLength: length)
        .deriveKey(
          secretKey: SecretKey(List<int>.of(secret)),
          nonce: const <int>[],
          info: utf8.encode(info),
        );
    return Uint8List.fromList(await derived.extractBytes());
  }
}

/// A decrypted channel message.
class ChannelPlaintext {
  const ChannelPlaintext(this.counter, this.text);

  final int counter;
  final Uint8List text;
}

/// The channel tag at the start of [blob], or null when it is too short to be one.
Uint8List? channelTagOf(List<int> blob) => blob.length < channelOverhead
    ? null
    : Uint8List.fromList(blob.sublist(0, channelTagLength));

/// tag(8) || nonce(12) || encrypt(counter(8) || text) || mac(16).
/// The sender ID is bound as associated data, so a non-member cannot move a message to
/// another sender, and a relay cannot change it without failing the tag check.
Future<Uint8List> sealChannelMessage(
  ChannelKey channel, {
  required Uint8List senderId,
  required int counter,
  required List<int> text,
  List<int> Function()? nonceSource,
}) async {
  if (counter < 0) throw ArgumentError.value(counter, 'counter');
  final nonce =
      nonceSource?.call() ??
      List<int>.generate(channelNonceLength, (_) => _random.nextInt(256));
  if (nonce.length != channelNonceLength) {
    throw StateError('nonce must be $channelNonceLength bytes');
  }
  final plain = Uint8List(channelCounterLength + text.length);
  ByteData.sublistView(plain).setUint64(0, counter, Endian.big);
  plain.setRange(channelCounterLength, plain.length, text);
  final box = await _aead.encrypt(
    plain,
    secretKey: SecretKey(channel.key),
    nonce: nonce,
    aad: _associatedData(channel.tag, senderId),
  );
  return Uint8List.fromList([
    ...channel.tag,
    ...nonce,
    ...box.cipherText,
    ...box.mac.bytes,
  ]);
}

/// Opens a blob made by [sealChannelMessage]. Throws [ChannelFormatException] when it is
/// short, for another channel, or fails authentication.
Future<ChannelPlaintext> openChannelMessage(
  ChannelKey channel,
  List<int> blob, {
  required Uint8List senderId,
}) async {
  if (blob.length < channelOverhead) {
    throw const ChannelFormatException('channel message too short');
  }
  final tag = blob.sublist(0, channelTagLength);
  for (var i = 0; i < channelTagLength; i++) {
    if (tag[i] != channel.tag[i]) {
      throw const ChannelFormatException('message is for another channel');
    }
  }
  final nonceEnd = channelTagLength + channelNonceLength;
  final macStart = blob.length - channelMacLength;
  final box = SecretBox(
    blob.sublist(nonceEnd, macStart),
    nonce: blob.sublist(channelTagLength, nonceEnd),
    mac: Mac(blob.sublist(macStart)),
  );
  final List<int> plain;
  try {
    plain = await _aead.decrypt(
      box,
      secretKey: SecretKey(channel.key),
      aad: _associatedData(channel.tag, senderId),
    );
  } on SecretBoxAuthenticationError {
    throw const ChannelFormatException('channel message failed authentication');
  }
  final bytes = Uint8List.fromList(plain);
  final counter = ByteData.sublistView(bytes).getUint64(0, Endian.big);
  if (counter < 0) {
    throw const ChannelFormatException('counter out of range');
  }
  return ChannelPlaintext(
    counter,
    Uint8List.sublistView(bytes, channelCounterLength),
  );
}

List<int> _associatedData(List<int> tag, List<int> senderId) => [
  ...utf8.encode('offmesh/channel-msg/v1'),
  ...tag,
  ...senderId,
];
