import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../crypto/identity.dart';
import '../crypto/noise_k.dart';
import '../crypto/noise_primitives.dart' show NoiseException;
import 'custody_envelope.dart';

final List<int> _prologueLabel = utf8.encode('offmesh/dtn/v1');

/// Prologue binding an envelope's header to its K ciphertext.
///
/// A carrier that edits the id, times or recipient hint breaks authentication. The copy
/// budget is left out because it changes at every hop.
Uint8List dtnPrologue(
  List<int> id,
  int createdAt,
  int expiresAt,
  List<int> recipientHint,
) {
  final times = ByteData(8)
    ..setUint32(0, createdAt, Endian.big)
    ..setUint32(4, expiresAt, Endian.big);
  return Uint8List.fromList([
    ..._prologueLabel,
    ...id,
    ...times.buffer.asUint8List(),
    ...recipientHint,
  ]);
}

/// Seals [plaintext] from [sender] to the roster member whose static key is
/// [recipientPublic], as a new custody envelope created at [nowSeconds].
///
/// The lifetime is capped at [custodyMaxLifetimeSeconds]. [copies] must be
/// 1..[custodyMaxCopies].
Future<CustodyEnvelope> sealCustody({
  required SimpleKeyPair sender,
  required Uint8List recipientPublic,
  required List<int> plaintext,
  required int nowSeconds,
  int lifetimeSeconds = custodyMaxLifetimeSeconds,
  int copies = custodyMaxCopies,
  Random? random,
}) async {
  if (copies < 1 || copies > custodyMaxCopies) {
    throw ArgumentError.value(copies, 'copies', 'must be 1..$custodyMaxCopies');
  }
  if (lifetimeSeconds <= 0) {
    throw ArgumentError.value(
      lifetimeSeconds,
      'lifetimeSeconds',
      'must be positive',
    );
  }
  final id = newCustodyId(random);
  final hint = await peerIdFor(recipientPublic);
  final expiresAt =
      nowSeconds +
      (lifetimeSeconds < custodyMaxLifetimeSeconds
          ? lifetimeSeconds
          : custodyMaxLifetimeSeconds);
  final ciphertext = await NoiseK.seal(
    initiatorStatic: sender,
    responderStaticPublic: recipientPublic,
    prologue: dtnPrologue(id, nowSeconds, expiresAt, hint),
    plaintext: plaintext,
  );
  return CustodyEnvelope(
    id: id,
    createdAt: nowSeconds,
    expiresAt: expiresAt,
    copies: copies,
    recipientHint: hint,
    ciphertext: ciphertext,
  );
}

/// Opens [envelope] if it is addressed to [recipient] and sealed by one of
/// [rosterPublicKeys]. Returns the plaintext, or null when the hint names someone else or
/// no roster key opens it. The sender is found by trying roster keys, since K names none.
Future<Uint8List?> openCustody({
  required CustodyEnvelope envelope,
  required SimpleKeyPair recipient,
  required List<Uint8List> rosterPublicKeys,
}) async => (await openCustodyFrom(
  envelope: envelope,
  recipient: recipient,
  rosterPublicKeys: rosterPublicKeys,
))?.$2;

/// Like [openCustody], but also returns the roster key that sealed the envelope.
Future<(Uint8List, Uint8List)?> openCustodyFrom({
  required CustodyEnvelope envelope,
  required SimpleKeyPair recipient,
  required List<Uint8List> rosterPublicKeys,
}) async {
  final recipientPublic = Uint8List.fromList(
    (await recipient.extractPublicKey()).bytes,
  );
  final ownHint = await peerIdFor(recipientPublic);
  if (custodyIdKey(ownHint) != custodyIdKey(envelope.recipientHint)) {
    return null;
  }
  final prologue = dtnPrologue(
    envelope.id,
    envelope.createdAt,
    envelope.expiresAt,
    envelope.recipientHint,
  );
  for (final sender in rosterPublicKeys) {
    try {
      return (
        sender,
        await NoiseK.open(
          responderStatic: recipient,
          initiatorStaticPublic: sender,
          prologue: prologue,
          message: envelope.ciphertext,
        ),
      );
    } on NoiseException {
      continue;
    }
  }
  return null;
}

/// DTN message kinds carried inside a sealed link frame.
const int dtnKindIdList = 0x01;
const int dtnKindEnvelope = 0x02;

/// Wraps a body in a one-byte kind tag.
Uint8List dtnFrame(int kind, List<int> body) =>
    Uint8List.fromList([kind, ...body]);

/// Splits a DTN frame into (kind, body). Throws [CustodyFormatException] on an empty
/// frame or an unknown kind.
(int, Uint8List) parseDtnFrame(List<int> frame) {
  if (frame.isEmpty) {
    throw const CustodyFormatException('empty DTN frame');
  }
  final kind = frame[0];
  if (kind != dtnKindIdList && kind != dtnKindEnvelope) {
    throw const CustodyFormatException('unknown DTN kind');
  }
  return (kind, Uint8List.fromList(frame.sublist(1)));
}
