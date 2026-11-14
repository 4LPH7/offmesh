import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/crypto/identity.dart';
import 'package:offmesh/core/crypto/unit_keys.dart';
import 'package:offmesh/core/mesh/mesh_node.dart';
import 'package:offmesh/core/protocol/sealed_envelope.dart';
import 'package:offmesh/transports/lan_frame.dart';
import 'package:offmesh/transports/lan_link.dart';
import 'package:offmesh/transports/lan_manager.dart';

final Random _random = Random.secure();

Uint8List randomBytes(int length) =>
    Uint8List.fromList(List<int>.generate(length, (_) => _random.nextInt(256)));

/// Hello plaintext: [rotatingId] || [peerNonce] || [role].
Uint8List helloBytes(List<int> rotatingId, List<int> peerNonce, int role) =>
    Uint8List.fromList([...rotatingId, ...peerNonce, role]);

/// A TCP client that speaks the sealed LAN framing by hand, to play a hostile or
/// silent peer.
class RawPeer {
  RawPeer._(this.socket, this.envelope) {
    socket.listen(
      (data) => _decoder.add(data).forEach(_frames.add),
      onDone: _finish,
      onError: (Object _) => _finish(),
    );
  }

  final Socket socket;
  final SealedEnvelope envelope;
  final FrameDecoder _decoder = FrameDecoder();
  final StreamController<Uint8List> _frames = StreamController<Uint8List>();
  late final StreamIterator<Uint8List> _next = StreamIterator(_frames.stream);
  final Completer<void> _done = Completer<void>();

  static Future<RawPeer> connect(int port, List<int> sealKey) async {
    final socket = await Socket.connect('127.0.0.1', port);
    addTearDown(socket.destroy);
    return RawPeer._(socket, SealedEnvelope(sealKey));
  }

  /// Completes when the other side closes the socket.
  Future<void> get done => _done.future;

  /// The next frame from the other side, opened with [envelope].
  Future<Uint8List> nextOpened() async {
    if (!await _next.moveNext()) throw StateError('socket closed');
    return envelope.open(_next.current);
  }

  Future<void> sendSealed(List<int> plaintext) async =>
      socket.add(encodeFrame(await envelope.seal(plaintext)));

  /// Completes the handshake as the dialer whose rotating ID is [rotatingId].
  Future<void> handshake(List<int> rotatingId) async {
    await sendSealed(randomBytes(linkNonceLength));
    final peerNonce = await nextOpened();
    await sendSealed(helloBytes(rotatingId, peerNonce, roleDialer));
  }

  void _finish() {
    if (!_done.isCompleted) _done.complete();
    unawaited(_frames.close());
  }
}

/// A 32-byte unit secret that differs per [seed].
Uint8List testSecret(int seed) =>
    Uint8List.fromList(List<int>.generate(32, (i) => (seed * 31 + i) & 0xFF));

class TestDevice {
  TestDevice(this.identity, this.node, this.lan, this.inbox);

  final Identity identity;
  final MeshNode node;
  final LanManager lan;
  final List<ReceivedMessage> inbox;
}

/// A started node whose LanManager is configured with [unitSecret] and the public keys
/// of [roster]. Beacons are off unless [beaconPort] is set.
Future<TestDevice> unitDevice(
  Identity identity, {
  required List<int> unitSecret,
  required List<Identity> roster,
  int beaconPort = 0,
  Duration beaconInterval = const Duration(milliseconds: 300),
  DateTime Function()? clock,
  Duration linkIdleTimeout = defaultLinkIdleTimeout,
  Duration dialBackoff = const Duration(seconds: 3),
}) async {
  final node = MeshNode(
    identity: identity,
    transports: const [],
    random: Random(),
    delay: (_) async {},
  );
  final lan = LanManager(
    node: node,
    beaconPort: beaconPort,
    beaconInterval: beaconInterval,
    clock: clock,
    linkIdleTimeout: linkIdleTimeout,
    dialBackoff: dialBackoff,
  );
  await lan.configure(await UnitKeys.derive(unitSecret), [
    for (final member in roster) member.publicKey,
  ]);
  final inbox = <ReceivedMessage>[];
  node.messages.listen(inbox.add);
  node.start();
  addTearDown(lan.stop);
  return TestDevice(identity, node, lan, inbox);
}

Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// True when [needle] occurs anywhere in [haystack].
bool containsBytes(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}
