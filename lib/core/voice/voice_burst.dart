import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'adpcm.dart';

/// Push-to-talk audio: 8 kHz mono, 16-bit PCM in, IMA ADPCM on the wire.
const int voiceSampleRate = 8000;

/// Samples per frame: 40 ms. One frame fills one channel packet.
const int voiceFrameSamples = 320;

/// Longest burst: 30 seconds of frames. The sender stops itself here.
const int maxBurstFrames = 750;

/// Frame header: burst ID (4) | sequence (2) | flags (1).
const int voiceFrameHeaderLength = 7;

const int _flagStart = 1;
const int _flagEnd = 2;

class VoiceFormatException implements Exception {
  const VoiceFormatException(this.message);

  final String message;

  @override
  String toString() => 'VoiceFormatException: $message';
}

/// One decoded voice frame.
class VoiceFrame {
  const VoiceFrame({
    required this.burstId,
    required this.seq,
    required this.start,
    required this.end,
    required this.pcm,
  });

  final int burstId;
  final int seq;
  final bool start;
  final bool end;
  final Int16List pcm;

  static VoiceFrame decode(Uint8List body) {
    if (body.length < voiceFrameHeaderLength + adpcmHeaderLength) {
      throw const VoiceFormatException('voice frame too short');
    }
    final header = ByteData.sublistView(body);
    final block = Uint8List.sublistView(body, voiceFrameHeaderLength);
    final samples = (block.length - adpcmHeaderLength) * 2;
    if (samples > voiceFrameSamples) {
      throw const VoiceFormatException('voice frame too long');
    }
    final Int16List pcm;
    try {
      pcm = decodeAdpcm(block, samples);
    } on AdpcmFormatException catch (e) {
      throw VoiceFormatException(e.message);
    }
    final flags = header.getUint8(6);
    return VoiceFrame(
      burstId: header.getUint32(0, Endian.big),
      seq: header.getUint16(4, Endian.big),
      start: (flags & _flagStart) != 0,
      end: (flags & _flagEnd) != 0,
      pcm: pcm,
    );
  }
}

Uint8List encodeVoiceFrame({
  required int burstId,
  required int seq,
  required bool start,
  required bool end,
  required Uint8List adpcmBlock,
}) {
  final out = Uint8List(voiceFrameHeaderLength + adpcmBlock.length);
  ByteData.sublistView(out)
    ..setUint32(0, burstId, Endian.big)
    ..setUint16(4, seq, Endian.big)
    ..setUint8(6, (start ? _flagStart : 0) | (end ? _flagEnd : 0));
  out.setRange(voiceFrameHeaderLength, out.length, adpcmBlock);
  return out;
}

/// Turns microphone PCM into numbered voice frames while the talk button is held.
class VoiceBurstSender {
  VoiceBurstSender({
    required Future<void> Function(Uint8List frame) send,
    Random? random,
    this.maxFrames = maxBurstFrames,
    void Function()? onCapped,
  }) : _send = send,
       _random = random ?? Random.secure(),
       _onCapped = onCapped;

  final Future<void> Function(Uint8List frame) _send;
  final Random _random;
  final int maxFrames;
  final void Function()? _onCapped;

  bool _active = false;
  int _burstId = 0;
  int _seq = 0;
  AdpcmEncoder _encoder = AdpcmEncoder();
  final List<int> _pending = [];
  Future<void> _sends = Future<void>.value();

  bool get active => _active;

  int get framesSent => _seq;

  void start() {
    _active = true;
    _burstId = _random.nextInt(0x100000000);
    _seq = 0;
    _encoder = AdpcmEncoder();
    _pending.clear();
  }

  /// Adds little-endian 16-bit PCM. Full frames are sent at once, in order.
  Future<void> addPcm(Uint8List pcm16le) {
    if (!_active) return _sends;
    final data = ByteData.sublistView(pcm16le);
    for (var i = 0; i + 1 < pcm16le.length; i += 2) {
      _pending.add(data.getInt16(i, Endian.little));
    }
    while (_active && _pending.length >= voiceFrameSamples) {
      final frame = Int16List.fromList(_pending.sublist(0, voiceFrameSamples));
      _pending.removeRange(0, voiceFrameSamples);
      final last = _seq + 1 >= maxFrames;
      _queue(frame, end: last);
      if (last) {
        _active = false;
        _onCapped?.call();
      }
    }
    return _sends;
  }

  /// Ends the burst: sends what is left, padded to an even length, as the end frame.
  Future<void> stop() {
    if (!_active) return _sends;
    _active = false;
    if (_pending.length.isOdd) _pending.add(0);
    _queue(Int16List.fromList(_pending), end: true);
    _pending.clear();
    return _sends;
  }

  void _queue(Int16List pcm, {required bool end}) {
    final frame = encodeVoiceFrame(
      burstId: _burstId,
      seq: _seq,
      start: _seq == 0,
      end: end,
      adpcmBlock: _encoder.encode(pcm),
    );
    _seq++;
    _sends = _sends.then((_) => _send(frame));
  }
}

/// Plays one speaker at a time per channel, in sequence order, with a short reorder
/// buffer. A frame from anyone else while a burst is playing is refused (busy).
class VoiceBurstReceiver {
  VoiceBurstReceiver({
    required void Function(Int16List pcm) onPcm,
    void Function(String? speaker)? onSpeaker,
    DateTime Function()? clock,
    this.jitterFrames = 3,
    this.speakerTimeout = const Duration(milliseconds: 600),
  }) : _onPcm = onPcm,
       _onSpeaker = onSpeaker,
       _clock = clock ?? DateTime.now;

  final void Function(Int16List pcm) _onPcm;
  final void Function(String? speaker)? _onSpeaker;
  final DateTime Function() _clock;
  final int jitterFrames;
  final Duration speakerTimeout;

  String? _speaker;
  int _burstId = 0;
  int _nextSeq = 0;
  int? _endSeq;
  DateTime _lastHeard = DateTime.fromMillisecondsSinceEpoch(0);
  final Map<int, Int16List> _buffer = {};

  /// Whoever is talking now (PeerID hex), or null.
  String? get speaker => _speaker;

  /// Takes one frame from [sender]. Returns false when someone else holds the channel.
  /// Throws [VoiceFormatException] for a malformed frame.
  bool accept(String sender, Uint8List body) {
    final frame = VoiceFrame.decode(body);
    tick();
    final speaker = _speaker;
    if (speaker != null && speaker != sender) return false;
    if (speaker == null || frame.burstId != _burstId) {
      _begin(sender, frame);
    } else if (frame.seq < _nextSeq) {
      return true; // late or duplicate
    }
    _lastHeard = _clock();
    _buffer[frame.seq] = frame.pcm;
    if (frame.end) _endSeq = frame.seq;
    _drain();
    return true;
  }

  /// Releases a speaker who went quiet without an end frame; call it periodically.
  void tick() {
    if (_speaker == null) return;
    if (_clock().difference(_lastHeard) <= speakerTimeout) return;
    final rest = _buffer.keys.toList()..sort();
    for (final seq in rest) {
      _onPcm(_buffer[seq]!);
    }
    _release();
  }

  void _begin(String sender, VoiceFrame frame) {
    final changed = _speaker != sender;
    _speaker = sender;
    _burstId = frame.burstId;
    _nextSeq = frame.seq;
    _endSeq = null;
    _buffer.clear();
    if (changed) _onSpeaker?.call(sender);
  }

  void _drain() {
    while (true) {
      final pcm = _buffer.remove(_nextSeq);
      if (pcm != null) {
        _onPcm(pcm);
        _nextSeq++;
        continue;
      }
      if (_buffer.length > jitterFrames) {
        // A frame is lost: skip the gap rather than wait for it.
        _nextSeq = _buffer.keys.reduce(min);
        continue;
      }
      break;
    }
    final end = _endSeq;
    if (end != null && _nextSeq > end) _release();
  }

  void _release() {
    _speaker = null;
    _endSeq = null;
    _buffer.clear();
    _onSpeaker?.call(null);
  }
}
