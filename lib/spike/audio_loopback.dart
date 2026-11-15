// SPIKE ONLY (branch spike/audio). Not wired into the app.
// Mic -> 16-bit PCM stream -> speaker, to measure frame size and loopback latency on a
// real device. Run by temporarily pointing main() at AudioLoopbackApp.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:record/record.dart';

const int spikeSampleRate = 8000;

class AudioLoopbackApp extends StatefulWidget {
  const AudioLoopbackApp({super.key});

  @override
  State<AudioLoopbackApp> createState() => _AudioLoopbackAppState();
}

class _AudioLoopbackAppState extends State<AudioLoopbackApp> {
  final AudioRecorder _recorder = AudioRecorder();
  AudioSource? _source;
  StreamSubscription<Uint8List>? _mic;
  final Stopwatch _clock = Stopwatch();
  int _chunks = 0;
  int _bytes = 0;
  int? _firstChunkMs;
  String _log = 'idle';

  Future<void> _start() async {
    if (!await _recorder.hasPermission()) {
      setState(() => _log = 'microphone permission denied');
      return;
    }
    final soloud = SoLoud.instance;
    if (!soloud.isInitialized) await soloud.init();
    final source = soloud.setBufferStream(
      sampleRate: spikeSampleRate,
      channels: Channels.mono,
      format: BufferType.s16le,
      bufferingType: BufferingType.released,
      bufferingTimeNeeds: 0.1,
    );
    _source = source;
    await soloud.play(source);
    _chunks = 0;
    _bytes = 0;
    _firstChunkMs = null;
    _clock
      ..reset()
      ..start();
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: spikeSampleRate,
        numChannels: 1,
      ),
    );
    _mic = stream.listen((chunk) {
      _firstChunkMs ??= _clock.elapsedMilliseconds;
      _chunks++;
      _bytes += chunk.length;
      SoLoud.instance.addAudioDataStream(source, chunk);
      setState(
        () => _log =
            'first chunk after ${_firstChunkMs}ms, $_chunks chunks, '
            'avg ${_bytes ~/ _chunks} bytes',
      );
    });
  }

  Future<void> _stop() async {
    await _mic?.cancel();
    await _recorder.stop();
    final source = _source;
    if (source != null) SoLoud.instance.setDataIsEnded(source);
    _source = null;
  }

  @override
  void dispose() {
    unawaited(_stop());
    _recorder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_log),
            Listener(
              onPointerDown: (_) => unawaited(_start()),
              onPointerUp: (_) => unawaited(_stop()),
              child: const Padding(
                padding: EdgeInsets.all(48),
                child: Text('HOLD TO TALK'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
