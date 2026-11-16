import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/app/chat_controller.dart';
import 'package:offmesh/app/secret_store.dart';
import 'package:offmesh/app/voice_audio.dart';
import 'package:offmesh/core/crypto/identity.dart';
import 'package:offmesh/core/mesh/mesh_node.dart';
import 'package:offmesh/core/mesh/transport.dart';
import 'package:offmesh/core/posture.dart';
import 'package:offmesh/core/voice/tones.dart';
import 'package:offmesh/core/voice/voice_burst.dart';
import 'package:offmesh/transports/lan_manager.dart';

import '../core/mesh/fake_network.dart';

class _FakeCapture implements VoiceCapture {
  _FakeCapture({this.allowed = true});

  final bool allowed;
  void Function(Uint8List pcm)? _sink;
  bool get recording => _sink != null;

  @override
  Future<bool> start(void Function(Uint8List pcm16le) onData) async {
    if (!allowed) return false;
    _sink = onData;
    return true;
  }

  @override
  Future<void> stop() async => _sink = null;

  void speak(int samples) => _sink?.call(Uint8List(samples * 2));
}

class _FakePlayback implements VoicePlayback {
  final List<String> events = [];
  int samples = 0;

  @override
  Future<void> begin() async => events.add('begin');

  @override
  void push(Int16List pcm) => samples += pcm.length;

  @override
  Future<void> end() async => events.add('end');
}

Future<ChatController> _controller(
  List<MeshTransport> transports, {
  VoiceCapture? capture,
  VoicePlayback? playback,
}) async {
  final node = MeshNode(
    identity: await Identity.generate(),
    transports: transports,
    random: Random(),
    delay: (_) async {},
  );
  final controller = ChatController(
    node: node,
    lan: LanManager(node: node, beaconPort: 0),
    store: MemorySecretStore(),
    capture: capture,
    playback: playback,
  );
  addTearDown(controller.stop);
  await controller.start();
  return controller;
}

void main() {
  test(
    'a burst on a channel plays on the other member, then releases',
    () async {
      final topology = FakeTopology(2, const [(0, 1)]);
      final mic = _FakeCapture();
      final speaker = _FakePlayback();
      final alice = await _controller(
        topology.transportsOf(0),
        capture: mic,
        playback: _FakePlayback(),
      );
      final bob = await _controller(
        topology.transportsOf(1),
        capture: _FakeCapture(),
        playback: speaker,
      );
      await alice.createUnit('Alice');
      await alice.addMember(bob.identityCodeFor('Bob')!);
      expect(await bob.importUnit(alice.unitCode!), isTrue);
      await alice.joinChannel('ops');
      await bob.joinChannel('ops');

      await alice.startTalking();
      expect(alice.talking, isTrue);
      mic.speak(voiceFrameSamples * 3);
      await pumpEventQueue();
      expect(bob.speakerOn('#ops'), 'Alice');

      await alice.stopTalking();
      await pumpEventQueue();

      expect(alice.talking, isFalse);
      expect(mic.recording, isFalse);
      expect(speaker.samples, voiceFrameSamples * 3 + rogerBeep().length);
      expect(speaker.events, ['begin', 'end']);
      expect(bob.speakerOn('#ops'), isNull);
      expect(bob.lastHeard(alice.myId), isNotNull);
      expect(alice.lastHeard(bob.myId), isNull);
    },
  );

  test('Silent and Quiet refuse to talk; Silent mid-burst stops it', () async {
    final mic = _FakeCapture();
    final c = await _controller(
      const [],
      capture: mic,
      playback: _FakePlayback(),
    );
    await c.createUnit('Alice');
    await c.joinChannel('ops');

    await c.setPosture(Posture.silent);
    await c.startTalking();
    expect(c.talking, isFalse);
    expect(c.lastError, 'Silent: talk is off');

    await c.setPosture(Posture.quiet);
    await c.startTalking();
    expect(c.talking, isFalse);
    expect(c.lastError, startsWith('Quiet'));

    await c.setPosture(Posture.normal);
    await c.startTalking();
    expect(c.talking, isTrue);
    await c.setPosture(Posture.silent);
    expect(c.talking, isFalse);
    expect(mic.recording, isFalse);
  });

  test('talking needs a channel and the microphone permission', () async {
    final c = await _controller(
      const [],
      capture: _FakeCapture(allowed: false),
      playback: _FakePlayback(),
    );
    await c.createUnit('Alice');

    await c.startTalking();
    expect(c.lastError, 'Choose a channel to talk on');

    await c.joinChannel('ops');
    await c.startTalking();
    expect(c.talking, isFalse);
    expect(c.lastError, 'Microphone permission is needed to talk');
  });

  test('no voice adapters means no talk button and a clear refusal', () async {
    final c = await _controller(const []);
    await c.createUnit('Alice');
    await c.joinChannel('ops');

    expect(c.voiceAvailable, isFalse);
    await c.startTalking();
    expect(c.lastError, 'Voice is not available here');
  });
}
