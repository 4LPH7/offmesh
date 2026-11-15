import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/crypto/noise_k.dart';
import 'package:offmesh/core/dtn/custody_envelope.dart';
import 'package:offmesh/core/dtn/custody_seal.dart';
import 'package:offmesh/core/protocol/sealed_envelope.dart';
import 'package:offmesh/transports/lan_frame.dart';

const int _now = 1800000000;

Future<Uint8List> _publicOf(SimpleKeyPair pair) async =>
    Uint8List.fromList((await pair.extractPublicKey()).bytes);

CustodyEnvelope _copyWithExpiry(CustodyEnvelope e, int expiresAt) =>
    CustodyEnvelope(
      id: e.id,
      createdAt: e.createdAt,
      expiresAt: expiresAt,
      copies: e.copies,
      recipientHint: e.recipientHint,
      ciphertext: e.ciphertext,
    );

void main() {
  late SimpleKeyPair sender;
  late SimpleKeyPair recipient;
  late SimpleKeyPair outsider;
  late SimpleKeyPair other;
  late Uint8List senderPublic;
  late Uint8List recipientPublic;
  late Uint8List outsiderPublic;

  setUp(() async {
    sender = await X25519().newKeyPair();
    recipient = await X25519().newKeyPair();
    outsider = await X25519().newKeyPair();
    other = await X25519().newKeyPair();
    senderPublic = await _publicOf(sender);
    recipientPublic = await _publicOf(recipient);
    outsiderPublic = await _publicOf(outsider);
  });

  Future<CustodyEnvelope> sealForRecipient({int copies = custodyMaxCopies}) =>
      sealCustody(
        sender: sender,
        recipientPublic: recipientPublic,
        plaintext: 'hold at the gate'.codeUnits,
        nowSeconds: _now,
        copies: copies,
        random: null,
      );

  test(
    'the recipient opens an envelope, finding the sender in the roster',
    () async {
      final envelope = await sealForRecipient();
      final plain = await openCustody(
        envelope: envelope,
        recipient: recipient,
        rosterPublicKeys: [outsiderPublic, senderPublic],
      );
      expect(plain, 'hold at the gate'.codeUnits);
    },
  );

  test('a sender outside the roster cannot be opened', () async {
    final envelope = await sealForRecipient();
    final plain = await openCustody(
      envelope: envelope,
      recipient: recipient,
      rosterPublicKeys: [outsiderPublic],
    );
    expect(plain, isNull);
  });

  test('an envelope for another member is not opened', () async {
    final envelope = await sealForRecipient();
    final plain = await openCustody(
      envelope: envelope,
      recipient: other,
      rosterPublicKeys: [senderPublic],
    );
    expect(plain, isNull);
  });

  test('an edited expiry breaks authentication (header is bound)', () async {
    final envelope = await sealForRecipient();
    final extended = _copyWithExpiry(envelope, envelope.expiresAt + 60);
    final plain = await openCustody(
      envelope: extended,
      recipient: recipient,
      rosterPublicKeys: [senderPublic],
    );
    expect(plain, isNull);
  });

  test('the copy budget can change without breaking authentication', () async {
    final envelope = await sealForRecipient(copies: 6);
    final sprayed = envelope.withCopies(3);
    final plain = await openCustody(
      envelope: sprayed,
      recipient: recipient,
      rosterPublicKeys: [senderPublic],
    );
    expect(plain, 'hold at the gate'.codeUnits);
  });

  test('lifetime is capped at 72 hours and copies default to 6', () async {
    final envelope = await sealCustody(
      sender: sender,
      recipientPublic: recipientPublic,
      plaintext: const [1],
      nowSeconds: _now,
      lifetimeSeconds: 365 * 24 * 3600,
    );
    expect(envelope.expiresAt - envelope.createdAt, custodyMaxLifetimeSeconds);
    expect(envelope.copies, 6);
  });

  test('a copy budget of 0 or 7 is refused at seal time', () async {
    for (final copies in [0, 7]) {
      await expectLater(sealForRecipient(copies: copies), throwsArgumentError);
    }
  });

  group('DTN frame over the sealed link', () {
    test('an envelope frame round trips through SealedEnvelope', () async {
      // A frame on the wire carries a budget a spray could have handed over.
      final envelope = await sealForRecipient(copies: custodyMaxWireCopies);
      final frame = dtnFrame(dtnKindEnvelope, envelope.encode());
      final key = Uint8List(32)..[0] = 9;
      final sealer = SealedEnvelope(key);
      final sealed = await sealer.seal(frame);
      final opened = await sealer.open(sealed);

      final (kind, body) = parseDtnFrame(opened);
      expect(kind, dtnKindEnvelope);
      final decoded = CustodyEnvelope.decode(body, nowSeconds: _now);
      expect(decoded.id, envelope.id);
    });

    test(
      'a full-size envelope does not fit one LAN frame, so it must be fragmented',
      () async {
        // Documented limit, not a pass for transport: the 547-byte envelope plus the
        // 28-byte seal is larger than maxFrameLength. docs/dtn_tests.md and the plan list
        // this as an open decision.
        final big = await sealCustody(
          sender: sender,
          recipientPublic: recipientPublic,
          plaintext: Uint8List(noiseKMaxPlaintextLength),
          nowSeconds: _now,
        );
        final frame = dtnFrame(dtnKindEnvelope, big.encode());
        final sealed = await SealedEnvelope(Uint8List(32)).seal(frame);
        expect(big.encode().length, custodyMaxEnvelopeLength);
        expect(sealed.length, greaterThan(maxFrameLength));
      },
    );

    test('unknown kinds and empty frames are refused', () {
      expect(
        () => parseDtnFrame(const []),
        throwsA(isA<CustodyFormatException>()),
      );
      expect(
        () => parseDtnFrame(const [0x7f, 1, 2]),
        throwsA(isA<CustodyFormatException>()),
      );
    });
  });
}
