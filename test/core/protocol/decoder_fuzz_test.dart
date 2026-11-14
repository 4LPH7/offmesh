import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/protocol/delivery_ack.dart';
import 'package:offmesh/core/protocol/fragmentation.dart';
import 'package:offmesh/core/protocol/packet.dart';
import 'package:offmesh/core/protocol/sealed_envelope.dart';
import 'package:offmesh/transports/lan_frame.dart';

/// Every decoder that reads bytes from the wire must reject malformed input with its
/// own typed exception and never anything else. Seeded, so a failure reproduces.
///
/// Inputs per decoder (100,000 in total): packet 40,000 (each decodable one is also
/// fed to a Reassembler), receipt 30,000, LAN framing 20,000, sealed envelope 10,000
/// (fewer because each one runs a full AEAD check in pure Dart).

const int _seed = 0x0FF3E5;

Uint8List _mutate(Random random, Uint8List valid) {
  final bytes = List<int>.of(valid);
  switch (random.nextInt(5)) {
    case 0: // truncate
      bytes.length = random.nextInt(bytes.length + 1);
    case 1: // extend with junk
      bytes.addAll(
        List.generate(1 + random.nextInt(40), (_) => random.nextInt(256)),
      );
    case 2: // flip a few bits
      if (bytes.isNotEmpty) {
        for (var i = 0; i < 1 + random.nextInt(4); i++) {
          bytes[random.nextInt(bytes.length)] ^= 1 << random.nextInt(8);
        }
      }
    case 3: // overwrite a few bytes with boundary values
      if (bytes.isNotEmpty) {
        const edges = [0x00, 0x01, 0x7F, 0x80, 0xFE, 0xFF];
        for (var i = 0; i < 1 + random.nextInt(4); i++) {
          bytes[random.nextInt(bytes.length)] =
              edges[random.nextInt(edges.length)];
        }
      }
    default: // fully random buffer
      bytes
        ..clear()
        ..addAll(
          List.generate(random.nextInt(300), (_) => random.nextInt(256)),
        );
  }
  return Uint8List.fromList(bytes);
}

Uint8List _bytes(Random random, int length) =>
    Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));

List<Uint8List> _validPackets(Random random) => [
  for (final type in PacketType.values)
    for (final payloadLength in [0, 1, 32, maxPayloadLength])
      Packet(
        type: type,
        ttl: random.nextInt(maxTtl + 1),
        packetId: random.nextInt(1 << 32),
        senderId: _bytes(random, 8),
        recipientId: _bytes(random, 8),
        fragIdx: 0,
        fragTotal: 1 + random.nextInt(3),
        payload: _bytes(random, payloadLength),
      ).encode(),
];

void main() {
  test('Packet.decode and Reassembler: 40,000 mutated frames', () {
    final random = Random(_seed);
    final seeds = _validPackets(random);
    final reassembler = Reassembler();
    var decoded = 0;

    for (var i = 0; i < 40000; i++) {
      final input = _mutate(random, seeds[random.nextInt(seeds.length)]);
      final Packet packet;
      try {
        packet = Packet.decode(input);
      } on PacketFormatException {
        continue;
      }
      decoded++;
      reassembler.add(packet); // must not throw for any decodable packet
      expect(
        reassembler.inFlightCount,
        lessThanOrEqualTo(reassembler.maxInFlight),
      );
    }
    // The mutator must not only produce garbage, or the reassembler goes untested.
    expect(decoded, greaterThan(1000));
  });

  test('DeliveryReceipt.decode: 30,000 mutated receipts', () {
    final random = Random(_seed + 1);
    final valid = DeliveryReceipt(
      packetId: 0xDEADBEEF,
      receivedAt: DateTime.utc(2026, 11, 14),
    ).encode();

    for (var i = 0; i < 30000; i++) {
      try {
        DeliveryReceipt.decode(_mutate(random, valid));
      } on DeliveryReceiptFormatException {
        // expected rejection
      }
    }
  });

  test('FrameDecoder: 20,000 mutated chunks, one stream per case', () {
    final random = Random(_seed + 2);
    final valid = encodeFrame(_bytes(random, 64));

    for (var i = 0; i < 20000; i++) {
      final decoder = FrameDecoder();
      try {
        for (final frame in decoder.add(_mutate(random, valid))) {
          expect(frame.length, lessThanOrEqualTo(maxFrameLength));
        }
      } on FormatException {
        // expected rejection of an oversized length prefix
      }
    }
  });

  test('SealedEnvelope.open: 10,000 mutated sealed frames', () async {
    final random = Random(_seed + 3);
    final now = DateTime.utc(2026, 11, 14, 12);
    final envelope = SealedEnvelope(
      _bytes(random, sealKeyLength),
      clock: () => now,
    );
    final seeds = [
      for (final packet in _validPackets(random).take(6))
        await envelope.seal(packet),
    ];
    var opened = 0;

    for (var i = 0; i < 10000; i++) {
      try {
        await envelope.open(
          _mutate(random, seeds[random.nextInt(seeds.length)]),
        );
        opened++;
      } on SealedEnvelopeException {
        // expected rejection
      }
    }
    // Only an unmodified frame can open; mutations that change nothing are rare.
    expect(opened, lessThan(500));
  });
}
