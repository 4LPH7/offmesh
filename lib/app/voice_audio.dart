import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:record/record.dart';

import '../core/voice/voice_burst.dart';

/// Microphone input for push-to-talk: 8 kHz mono, 16-bit little-endian PCM.
abstract interface class VoiceCapture {
  /// Starts recording. Returns false when the microphone permission is refused.
  Future<bool> start(void Function(Uint8List pcm16le) onData);

  Future<void> stop();
}

/// Speaker output for incoming bursts.
abstract interface class VoicePlayback {
  Future<void> begin();

  void push(Int16List pcm);

  Future<void> end();
}

/// [VoiceCapture] over the `record` plugin (Android and Windows).
class RecordVoiceCapture implements VoiceCapture {
  // Created on first use, so building the app never touches the plugin.
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _subscription;

  @override
  Future<bool> start(void Function(Uint8List pcm16le) onData) async {
    final recorder = _recorder ??= AudioRecorder();
    if (!await recorder.hasPermission()) return false;
    final stream = await recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: voiceSampleRate,
        numChannels: 1,
      ),
    );
    _subscription = stream.listen(onData);
    return true;
  }

  @override
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    await _recorder?.stop();
  }
}

/// [VoicePlayback] over `flutter_soloud` streaming buffers (Android and Windows).
class SoloudVoicePlayback implements VoicePlayback {
  AudioSource? _source;

  @override
  Future<void> begin() async {
    final soloud = SoLoud.instance;
    if (!soloud.isInitialized) await soloud.init();
    await end();
    final source = soloud.setBufferStream(
      sampleRate: voiceSampleRate,
      channels: Channels.mono,
      format: BufferType.s16le,
      bufferingType: BufferingType.released,
      bufferingTimeNeeds: 0.12,
    );
    _source = source;
    await soloud.play(source);
  }

  @override
  void push(Int16List pcm) {
    final source = _source;
    if (source == null) return;
    final bytes = ByteData(pcm.length * 2);
    for (var i = 0; i < pcm.length; i++) {
      bytes.setInt16(i * 2, pcm[i], Endian.little);
    }
    SoLoud.instance.addAudioDataStream(source, bytes.buffer.asUint8List());
  }

  @override
  Future<void> end() async {
    final source = _source;
    _source = null;
    if (source != null) SoLoud.instance.setDataIsEnded(source);
  }
}
