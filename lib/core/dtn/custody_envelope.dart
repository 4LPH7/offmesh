import 'dart:math';
import 'dart:typed_data';

import '../crypto/noise_k.dart' show noiseKMaxMessageLength;

/// Random envelope identifier length (bytes).
const int custodyIdLength = 16;

/// Recipient hint length: the recipient's PeerID (first 8 bytes of SHA-256 of its static key).
const int custodyHintLength = 8;

/// Longest lifetime an envelope may claim, measured from creation.
const int custodyMaxLifetimeSeconds = 72 * 3600;

/// Largest copy budget; also the default a new envelope starts with.
const int custodyMaxCopies = 6;

/// Largest copy budget that may arrive on the wire. A spray hands a peer floor(L/2) of
/// at most [custodyMaxCopies], and a direct delivery hands over 1, so no honest sender
/// sends more than this. [CustodyEnvelope.decode] refuses anything above it.
const int custodyMaxWireCopies = custodyMaxCopies ~/ 2;

/// Most envelope IDs one held-ID list may carry.
const int custodyMaxIdsPerList = 256;

/// How far in the future a creation time may sit before the envelope is refused.
const int custodyMaxClockSkewSeconds = 600;

/// Smallest K message: ephemeral key (32) plus AEAD tag (16).
const int _minCiphertextLength = 48;

/// Fixed header: id(16) created(4) expires(4) copies(1) hint(8) ciphertextLength(2).
const int custodyHeaderLength =
    custodyIdLength + 4 + 4 + 1 + custodyHintLength + 2;

/// Largest envelope: header plus the largest K message.
const int custodyMaxEnvelopeLength =
    custodyHeaderLength + noiseKMaxMessageLength;

final Random _secureRandom = Random.secure();

class CustodyFormatException implements Exception {
  const CustodyFormatException(this.message);

  final String message;

  @override
  String toString() => 'CustodyFormatException: $message';
}

/// Hex key for an ID, usable as a map key and for set comparisons.
String custodyIdKey(List<int> id) =>
    id.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// A new random envelope ID.
Uint8List newCustodyId([Random? random]) {
  final source = random ?? _secureRandom;
  return Uint8List.fromList(
    List<int>.generate(custodyIdLength, (_) => source.nextInt(256)),
  );
}

/// One store-and-forward envelope.
///
/// The ciphertext is a K message sealed to the recipient's static key. The envelope names
/// the recipient by PeerID (the hint) so a carrier holding one copy can hand it to that
/// member. The sender is not named. Carriers are unit members and already read sealed
/// headers (see docs/mission_plan.md 4.5), so the hint adds no exposure beyond that.
///
/// Wire layout, all integers big-endian:
///   id(16) || createdAt(u32, Unix s) || expiresAt(u32, Unix s) || copies(u8)
///   || recipientHint(8) || ciphertextLength(u16) || ciphertext
class CustodyEnvelope {
  CustodyEnvelope({
    required this.id,
    required this.createdAt,
    required this.expiresAt,
    required this.copies,
    required this.recipientHint,
    required this.ciphertext,
  });

  final Uint8List id;
  final int createdAt;
  final int expiresAt;
  final int copies;
  final Uint8List recipientHint;
  final Uint8List ciphertext;

  /// The same envelope with a different copy budget (immutable update).
  CustodyEnvelope withCopies(int newCopies) => CustodyEnvelope(
    id: id,
    createdAt: createdAt,
    expiresAt: expiresAt,
    copies: newCopies,
    recipientHint: recipientHint,
    ciphertext: ciphertext,
  );

  bool isExpiredAt(int nowSeconds) => nowSeconds >= expiresAt;

  Uint8List encode() {
    final out = Uint8List(custodyHeaderLength + ciphertext.length);
    final view = ByteData.sublistView(out);
    out.setRange(0, custodyIdLength, id);
    view.setUint32(16, createdAt, Endian.big);
    view.setUint32(20, expiresAt, Endian.big);
    view.setUint8(24, copies);
    out.setRange(25, 25 + custodyHintLength, recipientHint);
    view.setUint16(33, ciphertext.length, Endian.big);
    out.setRange(custodyHeaderLength, out.length, ciphertext);
    return out;
  }

  /// Parses and validates an envelope received from a peer.
  ///
  /// Refuses bad lengths, a copy budget outside 1..[custodyMaxWireCopies], a lifetime over
  /// [custodyMaxLifetimeSeconds], a creation time more than [custodyMaxClockSkewSeconds]
  /// ahead of [nowSeconds], and an envelope already expired at [nowSeconds].
  ///
  /// Residual risk: the copies byte is outside the K prologue, so a carrier can rewrite
  /// it. The cap bounds how far one hop can inflate a budget. It does not authenticate
  /// the byte, so a carrier holding 1 copy can still raise it to the cap.
  static CustodyEnvelope decode(List<int> bytes, {required int nowSeconds}) {
    if (bytes.length < custodyHeaderLength) {
      throw const CustodyFormatException('envelope shorter than header');
    }
    final data = Uint8List.fromList(bytes);
    final view = ByteData.sublistView(data);
    final ciphertextLength = view.getUint16(33, Endian.big);
    if (ciphertextLength < _minCiphertextLength ||
        ciphertextLength > noiseKMaxMessageLength) {
      throw const CustodyFormatException('ciphertext length out of range');
    }
    if (data.length != custodyHeaderLength + ciphertextLength) {
      throw const CustodyFormatException('envelope length mismatch');
    }
    final copies = view.getUint8(24);
    if (copies < 1 || copies > custodyMaxWireCopies) {
      throw const CustodyFormatException('copy budget out of range');
    }
    final createdAt = view.getUint32(16, Endian.big);
    final expiresAt = view.getUint32(20, Endian.big);
    if (expiresAt <= createdAt ||
        expiresAt - createdAt > custodyMaxLifetimeSeconds) {
      throw const CustodyFormatException('lifetime out of range');
    }
    if (createdAt > nowSeconds + custodyMaxClockSkewSeconds) {
      throw const CustodyFormatException('creation time in the future');
    }
    if (nowSeconds >= expiresAt) {
      throw const CustodyFormatException('envelope already expired');
    }
    return CustodyEnvelope(
      id: Uint8List.sublistView(data, 0, custodyIdLength),
      createdAt: createdAt,
      expiresAt: expiresAt,
      copies: copies,
      recipientHint: Uint8List.sublistView(data, 25, 25 + custodyHintLength),
      ciphertext: Uint8List.sublistView(data, custodyHeaderLength),
    );
  }
}

/// Encodes a held-ID list: count(u16 BE) || ids (16 bytes each).
Uint8List encodeIdList(List<Uint8List> ids) {
  if (ids.length > custodyMaxIdsPerList) {
    throw ArgumentError.value(
      ids.length,
      'ids',
      'more than $custodyMaxIdsPerList',
    );
  }
  final out = Uint8List(2 + ids.length * custodyIdLength);
  ByteData.sublistView(out).setUint16(0, ids.length, Endian.big);
  for (var i = 0; i < ids.length; i++) {
    if (ids[i].length != custodyIdLength) {
      throw ArgumentError.value(
        ids[i].length,
        'ids[$i]',
        'not $custodyIdLength bytes',
      );
    }
    out.setRange(
      2 + i * custodyIdLength,
      2 + (i + 1) * custodyIdLength,
      ids[i],
    );
  }
  return out;
}

/// Decodes a held-ID list, refusing counts over [custodyMaxIdsPerList] and any length
/// that does not match the count exactly.
List<Uint8List> decodeIdList(List<int> bytes) {
  if (bytes.length < 2) {
    throw const CustodyFormatException('ID list shorter than count');
  }
  final data = Uint8List.fromList(bytes);
  final count = ByteData.sublistView(data).getUint16(0, Endian.big);
  if (count > custodyMaxIdsPerList) {
    throw const CustodyFormatException('ID list longer than the cap');
  }
  if (data.length != 2 + count * custodyIdLength) {
    throw const CustodyFormatException('ID list length mismatch');
  }
  return [
    for (var i = 0; i < count; i++)
      Uint8List.fromList(
        data.sublist(2 + i * custodyIdLength, 2 + (i + 1) * custodyIdLength),
      ),
  ];
}
