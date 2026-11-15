import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/dtn/custody_envelope.dart';

const int _now = 1800000000;

CustodyEnvelope _envelope({
  int createdAt = _now,
  int lifetime = 3600,
  int copies = custodyMaxWireCopies,
  int ciphertextLength = 60,
  int seed = 1,
}) {
  final random = Random(seed);
  return CustodyEnvelope(
    id: newCustodyId(random),
    createdAt: createdAt,
    expiresAt: createdAt + lifetime,
    copies: copies,
    recipientHint: Uint8List(custodyHintLength),
    ciphertext: Uint8List.fromList(
      List<int>.generate(ciphertextLength, (i) => i),
    ),
  );
}

void main() {
  group('CustodyEnvelope codec', () {
    test('round trip keeps every field', () {
      final original = _envelope(copies: 3, ciphertextLength: 512);
      final decoded = CustodyEnvelope.decode(
        original.encode(),
        nowSeconds: _now,
      );
      expect(decoded.id, original.id);
      expect(decoded.createdAt, original.createdAt);
      expect(decoded.expiresAt, original.expiresAt);
      expect(decoded.copies, 3);
      expect(decoded.ciphertext, original.ciphertext);
    });

    test('maximum envelope is 547 bytes', () {
      expect(
        _envelope(ciphertextLength: 512).encode().length,
        custodyMaxEnvelopeLength,
      );
    });

    test('refuses copy budget 0 and 7', () {
      for (final copies in [0, 7]) {
        final bytes = _envelope(copies: copies).encode();
        expect(
          () => CustodyEnvelope.decode(bytes, nowSeconds: _now),
          throwsA(isA<CustodyFormatException>()),
        );
      }
    });

    test('refuses a copy budget above the wire cap', () {
      for (
        var copies = custodyMaxWireCopies + 1;
        copies <= custodyMaxCopies;
        copies++
      ) {
        final bytes = _envelope(copies: copies).encode();
        expect(
          () => CustodyEnvelope.decode(bytes, nowSeconds: _now),
          throwsA(isA<CustodyFormatException>()),
          reason: 'copies $copies',
        );
      }
    });

    test('accepts a copy budget at the wire cap', () {
      final bytes = _envelope(copies: custodyMaxWireCopies).encode();
      expect(
        CustodyEnvelope.decode(bytes, nowSeconds: _now).copies,
        custodyMaxWireCopies,
      );
    });

    test('refuses lifetime over 72 hours', () {
      final bytes = _envelope(lifetime: custodyMaxLifetimeSeconds + 1).encode();
      expect(
        () => CustodyEnvelope.decode(bytes, nowSeconds: _now),
        throwsA(isA<CustodyFormatException>()),
      );
    });

    test('accepts exactly 72 hours', () {
      final bytes = _envelope(lifetime: custodyMaxLifetimeSeconds).encode();
      expect(
        CustodyEnvelope.decode(bytes, nowSeconds: _now).expiresAt,
        _now + custodyMaxLifetimeSeconds,
      );
    });

    test('refuses creation time far in the future', () {
      final bytes = _envelope(
        createdAt: _now + custodyMaxClockSkewSeconds + 1,
      ).encode();
      expect(
        () => CustodyEnvelope.decode(bytes, nowSeconds: _now),
        throwsA(isA<CustodyFormatException>()),
      );
    });

    test('refuses an envelope already expired', () {
      final bytes = _envelope(lifetime: 60).encode();
      expect(
        () => CustodyEnvelope.decode(bytes, nowSeconds: _now + 60),
        throwsA(isA<CustodyFormatException>()),
      );
    });

    test('refuses ciphertext over 512 bytes and under the K minimum', () {
      final oversized = Uint8List(custodyHeaderLength + 513);
      ByteData.sublistView(oversized)
        ..setUint32(16, _now, Endian.big)
        ..setUint32(20, _now + 60, Endian.big)
        ..setUint8(24, 1)
        ..setUint16(33, 513, Endian.big);
      expect(
        () => CustodyEnvelope.decode(oversized, nowSeconds: _now),
        throwsA(isA<CustodyFormatException>()),
      );

      final tiny = _envelope(ciphertextLength: 47).encode();
      expect(
        () => CustodyEnvelope.decode(tiny, nowSeconds: _now),
        throwsA(isA<CustodyFormatException>()),
      );
    });

    test('refuses trailing bytes', () {
      final bytes = [..._envelope().encode(), 0];
      expect(
        () => CustodyEnvelope.decode(bytes, nowSeconds: _now),
        throwsA(isA<CustodyFormatException>()),
      );
    });

    test('withCopies keeps the rest of the envelope', () {
      final original = _envelope(copies: 4);
      final changed = original.withCopies(2);
      expect(changed.copies, 2);
      expect(changed.id, original.id);
      expect(changed.ciphertext, original.ciphertext);
    });
  });

  group('held-ID list codec', () {
    test('round trip and cap of 256', () {
      final ids = [for (var i = 0; i < 256; i++) newCustodyId(Random(i))];
      expect(decodeIdList(encodeIdList(ids)).length, 256);
      expect(() => encodeIdList([...ids, newCustodyId()]), throwsArgumentError);
    });

    test('refuses count above the cap and a length mismatch', () {
      final over = Uint8List(2 + 257 * custodyIdLength)
        ..buffer.asByteData().setUint16(0, 257, Endian.big);
      expect(() => decodeIdList(over), throwsA(isA<CustodyFormatException>()));
      final short = encodeIdList([newCustodyId()]);
      expect(
        () => decodeIdList(short.sublist(0, short.length - 1)),
        throwsA(isA<CustodyFormatException>()),
      );
    });
  });

  test('decoders throw only CustodyFormatException on mutated input', () {
    final random = Random(20260222);
    final seeds = [
      _envelope(copies: 3, ciphertextLength: 100).encode(),
      encodeIdList([newCustodyId(random), newCustodyId(random)]),
    ];
    for (var round = 0; round < 10000; round++) {
      final seed = seeds[round % seeds.length];
      final mutated = Uint8List.fromList(seed);
      final flips = 1 + random.nextInt(4);
      for (var f = 0; f < flips; f++) {
        mutated[random.nextInt(mutated.length)] = random.nextInt(256);
      }
      final cut = random.nextBool()
          ? mutated
          : mutated.sublist(0, random.nextInt(mutated.length + 1));
      try {
        if (round % seeds.length == 0) {
          CustodyEnvelope.decode(cut, nowSeconds: _now);
        } else {
          decodeIdList(cut);
        }
      } on CustodyFormatException {
        // expected for malformed input
      }
    }
  });
}
