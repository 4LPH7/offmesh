import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/channel/channel_crypto.dart';
import 'package:offmesh/core/protocol/packet.dart';
import 'package:offmesh/core/voice/adpcm.dart';
import 'package:offmesh/core/voice/voice_burst.dart';

Int16List _sine(int samples, {double hz = 440, double amplitude = 12000}) =>
    Int16List.fromList([
      for (var i = 0; i < samples; i++)
        (amplitude * sin(2 * pi * hz * i / voiceSampleRate)).round(),
    ]);

Uint8List _pcmBytes(Int16List pcm) {
  final out = ByteData(pcm.length * 2);
  for (var i = 0; i < pcm.length; i++) {
    out.setInt16(i * 2, pcm[i], Endian.little);
  }
  return out.buffer.asUint8List();
}

double _snrDb(Int16List reference, Int16List decoded) {
  var signal = 0.0;
  var noise = 0.0;
  for (var i = 0; i < reference.length; i++) {
    signal += reference[i] * reference[i].toDouble();
    final error = reference[i] - decoded[i];
    noise += error * error.toDouble();
  }
  return 10 * log(signal / noise) / ln10;
}

void main() {
  group('IMA ADPCM', () {
    test('a 440 Hz tone survives with more than 20 dB SNR', () {
      final encoder = AdpcmEncoder();
      final input = _sine(voiceFrameSamples * 10);
      final decoded = <int>[];
      for (var f = 0; f < 10; f++) {
        final frame = Int16List.sublistView(
          input,
          f * voiceFrameSamples,
          (f + 1) * voiceFrameSamples,
        );
        final block = encoder.encode(frame);
        expect(block.length, adpcmHeaderLength + voiceFrameSamples ~/ 2);
        decoded.addAll(decodeAdpcm(block, voiceFrameSamples));
      }
      // Skip the first frame: the encoder starts from zero and needs a few samples to adapt.
      final skip = voiceFrameSamples;
      expect(
        _snrDb(
          Int16List.sublistView(input, skip),
          Int16List.fromList(decoded.sublist(skip)),
        ),
        greaterThan(20),
      );
    });

    test(
      'a later block decodes well on its own, so a lost block does not hurt the next',
      () {
        final encoder = AdpcmEncoder();
        final input = _sine(voiceFrameSamples * 3);
        final blocks = [
          for (var f = 0; f < 3; f++)
            encoder.encode(
              Int16List.sublistView(
                input,
                f * voiceFrameSamples,
                (f + 1) * voiceFrameSamples,
              ),
            ),
        ];
        // Decode block 2 without ever decoding block 1.
        final alone = decodeAdpcm(blocks[2], voiceFrameSamples);
        expect(
          _snrDb(Int16List.sublistView(input, 2 * voiceFrameSamples), alone),
          greaterThan(20),
        );
      },
    );

    test('short blocks and a bad step index are refused', () {
      expect(
        () => decodeAdpcm(Uint8List(3), 0),
        throwsA(isA<AdpcmFormatException>()),
      );
      expect(
        () => decodeAdpcm(Uint8List(5), 4),
        throwsA(isA<AdpcmFormatException>()),
      );
      final bad = Uint8List(8)..[2] = 200;
      expect(() => decodeAdpcm(bad, 8), throwsA(isA<AdpcmFormatException>()));
    });
  });

  group('voice frames', () {
    test('a full frame plus the channel overhead fits one packet payload', () {
      const fullFrame =
          voiceFrameHeaderLength + adpcmHeaderLength + voiceFrameSamples ~/ 2;
      // One kind byte separates voice from text inside a channel message.
      expect(
        1 + fullFrame + channelOverhead,
        lessThanOrEqualTo(maxPayloadLength),
      );
    });

    test('round trip keeps burst, sequence and flags', () {
      final body = encodeVoiceFrame(
        burstId: 0xCAFEBABE,
        seq: 513,
        start: true,
        end: false,
        adpcmBlock: AdpcmEncoder().encode(_sine(voiceFrameSamples)),
      );
      final frame = VoiceFrame.decode(body);
      expect(frame.burstId, 0xCAFEBABE);
      expect(frame.seq, 513);
      expect(frame.start, isTrue);
      expect(frame.end, isFalse);
      expect(frame.pcm, hasLength(voiceFrameSamples));
    });

    test('too short and too long frames are refused', () {
      expect(
        () => VoiceFrame.decode(Uint8List(10)),
        throwsA(isA<VoiceFormatException>()),
      );
      final long = Uint8List(
        voiceFrameHeaderLength + adpcmHeaderLength + voiceFrameSamples,
      );
      expect(
        () => VoiceFrame.decode(long),
        throwsA(isA<VoiceFormatException>()),
      );
    });
  });

  group('burst sender', () {
    test(
      'sends numbered frames, start flag first, the remainder as the end frame',
      () async {
        final sent = <VoiceFrame>[];
        final sender = VoiceBurstSender(
          send: (frame) async => sent.add(VoiceFrame.decode(frame)),
          random: Random(1),
        )..start();

        await sender.addPcm(_pcmBytes(_sine(1000)));
        await sender.stop();

        expect([for (final f in sent) f.seq], [0, 1, 2, 3]);
        expect([for (final f in sent) f.start], [true, false, false, false]);
        expect([for (final f in sent) f.end], [false, false, false, true]);
        expect(sent.last.pcm, hasLength(1000 - 3 * voiceFrameSamples));
        expect(sent.map((f) => f.burstId).toSet(), hasLength(1));
      },
    );

    test('stops itself at the cap and says so', () async {
      final sent = <VoiceFrame>[];
      var capped = false;
      final sender = VoiceBurstSender(
        send: (frame) async => sent.add(VoiceFrame.decode(frame)),
        maxFrames: 3,
        onCapped: () => capped = true,
      )..start();

      await sender.addPcm(_pcmBytes(_sine(voiceFrameSamples * 5)));
      await sender.stop();

      expect(sent, hasLength(3));
      expect(sent.last.end, isTrue);
      expect(capped, isTrue);
      expect(sender.active, isFalse);
    });

    test('nothing is sent before start or after stop', () async {
      final sent = <Uint8List>[];
      final sender = VoiceBurstSender(send: (f) async => sent.add(f));
      await sender.addPcm(_pcmBytes(_sine(voiceFrameSamples)));
      expect(sent, isEmpty);
      sender.start();
      await sender.stop();
      await sender.addPcm(_pcmBytes(_sine(voiceFrameSamples)));
      expect(sent, hasLength(1)); // the end frame only
    });
  });

  group('burst receiver', () {
    List<Uint8List> burst(int frames, {int burstId = 7}) {
      final encoder = AdpcmEncoder();
      return [
        for (var i = 0; i < frames; i++)
          encodeVoiceFrame(
            burstId: burstId,
            seq: i,
            start: i == 0,
            end: i == frames - 1,
            adpcmBlock: encoder.encode(
              Int16List(voiceFrameSamples)
                ..fillRange(0, voiceFrameSamples, i * 1000),
            ),
          ),
      ];
    }

    test('plays frames in order even when they arrive reordered', () {
      final played = <int>[];
      final speakers = <String?>[];
      final receiver = VoiceBurstReceiver(
        onPcm: (pcm) => played.add(pcm.last),
        onSpeaker: speakers.add,
      );
      final frames = burst(4);

      for (final i in [0, 2, 1, 3]) {
        expect(receiver.accept('alice', frames[i]), isTrue);
      }

      expect(played, hasLength(4));
      // Each frame holds a constant level i*1000; the decoder converges toward it.
      expect(played, orderedEquals([...played]..sort()));
      expect(speakers, ['alice', null]);
      expect(receiver.speaker, isNull);
    });

    test('a second speaker is refused while the first is talking', () {
      final speakers = <String?>[];
      final receiver = VoiceBurstReceiver(
        onPcm: (_) {},
        onSpeaker: speakers.add,
      );
      final alice = burst(3);
      final bob = burst(3, burstId: 9);

      expect(receiver.accept('alice', alice[0]), isTrue);
      expect(receiver.accept('bob', bob[0]), isFalse);
      expect(receiver.speaker, 'alice');
      expect(receiver.accept('alice', alice[1]), isTrue);
      expect(receiver.accept('alice', alice[2]), isTrue);
      expect(receiver.accept('bob', bob[0]), isTrue);
      expect(speakers, ['alice', null, 'bob']);
    });

    test('a lost frame is skipped once the reorder buffer is full', () {
      var count = 0;
      final receiver = VoiceBurstReceiver(
        onPcm: (_) => count++,
        jitterFrames: 2,
      );
      final frames = burst(6);

      for (final i in [0, 2, 3, 4]) {
        receiver.accept('alice', frames[i]);
      }

      expect(count, 4, reason: 'frame 1 is lost; 0, 2, 3 and 4 still play');
    });

    test('a speaker who goes quiet without an end frame is released', () {
      var now = DateTime.utc(2026);
      final speakers = <String?>[];
      final receiver = VoiceBurstReceiver(
        onPcm: (_) {},
        onSpeaker: speakers.add,
        clock: () => now,
      );

      receiver.accept('alice', burst(5)[0]);
      now = now.add(const Duration(milliseconds: 601));
      receiver.tick();

      expect(receiver.speaker, isNull);
      expect(speakers, ['alice', null]);
    });
  });
}
