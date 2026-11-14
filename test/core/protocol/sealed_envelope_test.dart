import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/protocol/packet.dart';
import 'package:offmesh/core/protocol/sealed_envelope.dart';

final Uint8List _unitKey = Uint8List.fromList(List.generate(32, (i) => i));
final Uint8List _senderId = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
final Uint8List _recipientId = Uint8List.fromList([
  9,
  10,
  11,
  12,
  13,
  14,
  15,
  16,
]);

Uint8List _frame() => Packet(
  type: PacketType.noiseTransport,
  ttl: 5,
  packetId: 0xA1B2C3D4,
  senderId: _senderId,
  recipientId: _recipientId,
  fragIdx: 0,
  fragTotal: 1,
  payload: Uint8List.fromList([0x41, 0x42, 0x43]),
).encode();

bool _containsRun(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length && match; j++) {
      match = haystack[i + j] == needle[j];
    }
    if (match) return true;
  }
  return false;
}

void main() {
  final envelope = SealedEnvelope(_unitKey);

  test('round trips a real packet frame', () async {
    final frame = _frame();

    final sealed = await envelope.seal(frame);
    final decoded = Packet.decode(await envelope.open(sealed));

    expect(sealed.length, frame.length + sealOverhead);
    expect(sealOverhead, 32);
    expect(decoded.ttl, 5);
    expect(decoded.packetId, 0xA1B2C3D4);
    expect(decoded.senderId, _senderId);
    expect(decoded.recipientId, _recipientId);
    expect(decoded.payload, [0x41, 0x42, 0x43]);
  });

  test('header fields do not appear in cleartext', () async {
    final frame = _frame();
    final sealed = await envelope.seal(frame);

    expect(_containsRun(sealed, _senderId), isFalse);
    expect(_containsRun(sealed, _recipientId), isFalse);
    expect(
      _containsRun(sealed, frame.sublist(0, Packet.headerLength)),
      isFalse,
    );
  });

  test('two seals of the same plaintext differ', () async {
    final frame = _frame();

    final first = await envelope.seal(frame);
    final second = await envelope.seal(frame);

    expect(first, isNot(equals(second)));
    expect(first.sublist(0, 12), isNot(equals(second.sublist(0, 12))));
  });

  test('wrong key fails', () async {
    final sealed = await envelope.seal(_frame());
    final otherKey = Uint8List.fromList(List.filled(32, 0x55));

    expect(
      SealedEnvelope(otherKey).open(sealed),
      throwsA(isA<SealedEnvelopeException>()),
    );
  });

  test('every single flipped bit fails', () async {
    final sealed = await envelope.seal(_frame());

    for (var byte = 0; byte < sealed.length; byte++) {
      for (var bit = 0; bit < 8; bit++) {
        final tampered = Uint8List.fromList(sealed);
        tampered[byte] ^= 1 << bit;
        await expectLater(
          envelope.open(tampered),
          throwsA(isA<SealedEnvelopeException>()),
          reason: 'byte $byte bit $bit',
        );
      }
    }
  });

  test('truncated and empty frames fail', () async {
    final sealed = await envelope.seal(_frame());

    for (final length in [0, 1, sealOverhead - 1, sealed.length - 1]) {
      await expectLater(
        envelope.open(sealed.sublist(0, length)),
        throwsA(isA<SealedEnvelopeException>()),
        reason: 'length $length',
      );
    }
  });

  test('empty plaintext round trips at exactly the overhead', () async {
    final sealed = await envelope.seal(const []);

    expect(sealed.length, sealOverhead);
    expect(await envelope.open(sealed), isEmpty);
  });

  test('rejects bad key lengths', () {
    for (final length in [0, 16, 31, 33]) {
      expect(
        () => SealedEnvelope(Uint8List(length)),
        throwsArgumentError,
        reason: 'length $length',
      );
    }
  });

  test('rejects a nonce source with the wrong length', () {
    final bad = SealedEnvelope(_unitKey, nonceSource: () => List.filled(8, 0));

    expect(bad.seal(_frame()), throwsStateError);
  });

  test('injected nonce lands at the front of the frame', () async {
    final nonce = List<int>.generate(12, (i) => 0xF0 + i);
    final fixed = SealedEnvelope(_unitKey, nonceSource: () => nonce);

    final sealed = await fixed.seal(_frame());

    expect(sealed.sublist(0, 12), nonce);
    expect(await envelope.open(sealed), _frame());
  });

  group('freshness', () {
    final sentAt = DateTime.utc(2026, 11, 14, 12);
    final window = sealFreshnessWindow;

    Future<Uint8List> sealAt(DateTime time) =>
        SealedEnvelope(_unitKey, clock: () => time).seal(_frame());

    Future<Uint8List> openAt(DateTime time, Uint8List sealed) =>
        SealedEnvelope(_unitKey, clock: () => time).open(sealed);

    test('opens at the window edges, in both directions', () async {
      final sealed = await sealAt(sentAt);

      expect(await openAt(sentAt, sealed), _frame());
      expect(await openAt(sentAt.add(window), sealed), _frame());
      expect(await openAt(sentAt.subtract(window), sealed), _frame());
    });

    test('rejects a frame one second outside the window', () async {
      final sealed = await sealAt(sentAt);
      const second = Duration(seconds: 1);

      for (final at in [
        sentAt.add(window + second),
        sentAt.subtract(window + second),
      ]) {
        await expectLater(
          openAt(at, sealed),
          throwsA(isA<SealedEnvelopeException>()),
          reason: 'opened at $at',
        );
      }
    });

    test('a replay recorded an hour ago is rejected', () async {
      final sealed = await sealAt(sentAt);

      await expectLater(
        openAt(sentAt.add(const Duration(hours: 1)), sealed),
        throwsA(isA<SealedEnvelopeException>()),
      );
    });

    test('the timestamp is inside the ciphertext, not in cleartext', () async {
      final sealed = await sealAt(sentAt);
      final seconds = sentAt.millisecondsSinceEpoch ~/ 1000;
      final stamp = (ByteData(4)..setUint32(0, seconds)).buffer.asUint8List();

      expect(_containsRun(sealed, stamp), isFalse);
    });

    test('sealing with a clock before 1970 is refused', () {
      final early = SealedEnvelope(
        _unitKey,
        clock: () => DateTime.utc(1969, 12, 31),
      );

      expect(early.seal(_frame()), throwsStateError);
    });
  });
}
