import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/crypto/identity.dart';
import 'package:offmesh/core/crypto/rotating_id.dart';
import 'package:offmesh/core/crypto/unit_keys.dart';
import 'package:offmesh/core/protocol/packet.dart';
import 'package:offmesh/core/protocol/sealed_envelope.dart';
import 'package:offmesh/transports/lan_frame.dart';
import 'package:offmesh/transports/lan_link.dart';

import 'lan_test_support.dart';

/// Test-only beacon port, so beacons from other test files on 47999 do not mix in.
const int _captureBeaconPort = 47996;

final List<int> _tag = ascii.encode('OFFM');

/// A loopback TCP relay that records every byte in each direction and can inject frames.
class _Proxy {
  _Proxy._(this._server, this._target) {
    _server.listen(_onClient);
  }

  final ServerSocket _server;
  final int _target;
  final BytesBuilder toServer = BytesBuilder();
  final BytesBuilder toClient = BytesBuilder();
  Socket? _upstream;

  static Future<_Proxy> start(int targetPort) async {
    final proxy = _Proxy._(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
      targetPort,
    );
    addTearDown(proxy._server.close);
    return proxy;
  }

  int get port => _server.port;

  void injectToServer(List<int> bytes) => _upstream!.add(bytes);

  Future<void> _onClient(Socket client) async {
    final upstream = await Socket.connect('127.0.0.1', _target);
    _upstream = upstream;
    client.listen(
      (data) {
        toServer.add(data);
        upstream.add(data);
      },
      onDone: upstream.destroy,
      onError: (Object _) => upstream.destroy(),
    );
    upstream.listen(
      (data) {
        toClient.add(data);
        client.add(data);
      },
      onDone: client.destroy,
      onError: (Object _) => client.destroy(),
    );
  }
}

/// Opens every captured frame: the challenge, the hello, then mesh packets and empty
/// keepalives.
Future<List<Uint8List>> _openAll(
  List<int> stream,
  SealedEnvelope envelope,
) async {
  final frames = FrameDecoder().add(stream);
  return [for (final frame in frames) await envelope.open(frame)];
}

void _expectNoCleartext(List<int> wire, List<TestDevice> devices) {
  expect(containsBytes(wire, _tag), isFalse, reason: 'OFFM tag on the wire');
  for (final device in devices) {
    expect(
      containsBytes(wire, device.node.peerId),
      isFalse,
      reason: 'static PeerID on the wire',
    );
    expect(
      containsBytes(wire, device.identity.publicKey),
      isFalse,
      reason: 'public key on the wire',
    );
  }
}

void main() {
  final secret = testSecret(3);
  late Identity aliceId;
  late Identity bobId;
  late UnitKeys keys;

  setUp(() async {
    aliceId = await Identity.generate();
    bobId = await Identity.generate();
    keys = await UnitKeys.derive(secret);
  });

  test(
    'a two-node loopback capture shows no PeerID, tag or packet header',
    () async {
      final roster = [aliceId, bobId];
      final alice = await unitDevice(
        aliceId,
        unitSecret: secret,
        roster: roster,
      );
      final bob = await unitDevice(bobId, unitSecret: secret, roster: roster);
      final proxy = await _Proxy.start(await bob.lan.start());

      await alice.lan.connect('127.0.0.1', proxy.port);
      await alice.node.sendText(
        bob.node.peerId,
        Uint8List.fromList(utf8.encode('to bob')),
      );
      await waitFor(() => bob.inbox.isNotEmpty);
      await bob.node.sendText(
        alice.node.peerId,
        Uint8List.fromList(utf8.encode('to alice')),
      );
      await waitFor(() => alice.inbox.isNotEmpty);

      final envelope = SealedEnvelope(keys.sealKey);
      final epoch = epochAt(DateTime.now());
      for (final (wire, sender) in [
        (proxy.toServer.toBytes(), alice),
        (proxy.toClient.toBytes(), bob),
      ]) {
        _expectNoCleartext(wire, [alice, bob]);
        final plain = await _openAll(wire, envelope);
        expect(plain.length, greaterThan(2));
        expect(plain[0], hasLength(linkNonceLength));
        // The hello leads with the sender's rotating ID (an hour boundary may fall
        // mid-test).
        expect(plain[1], hasLength(helloLength));
        expect([
          (await rotatingId(
            keys.idKey,
            sender.identity.publicKey,
            epoch - 1,
          )).hex,
          (await rotatingId(keys.idKey, sender.identity.publicKey, epoch)).hex,
        ], contains(plain[1].sublist(0, rotatingIdLength).hex));
        for (final packet in plain.skip(2).where((p) => p.isNotEmpty)) {
          final header = packet.sublist(0, Packet.headerLength);
          expect(Packet.decode(packet).senderId, isNotNull);
          expect(
            containsBytes(wire, header),
            isFalse,
            reason: 'packet header on the wire',
          );
        }
      }
    },
  );

  test(
    'a frame that fails to open is dropped and counted; the link stays up',
    () async {
      final roster = [aliceId, bobId];
      final alice = await unitDevice(
        aliceId,
        unitSecret: secret,
        roster: roster,
      );
      final bob = await unitDevice(bobId, unitSecret: secret, roster: roster);
      final proxy = await _Proxy.start(await bob.lan.start());
      await alice.lan.connect('127.0.0.1', proxy.port);
      await waitFor(() => bob.lan.linkCount == 1);

      proxy.injectToServer(encodeFrame(Uint8List(60)));
      await waitFor(() => bob.lan.droppedFrames == 1);
      await alice.node.sendText(
        bob.node.peerId,
        Uint8List.fromList(utf8.encode('still up')),
      );
      await waitFor(() => bob.inbox.isNotEmpty);

      expect(bob.lan.linkCount, 1);
      expect(utf8.decode(bob.inbox.single.plaintext), 'still up');
    },
  );

  test(
    'beacons are sealed rotating ID and port, and the ID changes each epoch',
    () async {
      var now = DateTime.utc(2026, 11, 15, 9, 59, 30);
      DateTime clock() => now;
      final capture = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _captureBeaconPort,
        reuseAddress: true,
      );
      addTearDown(capture.close);
      final datagrams = StreamController<Uint8List>();
      capture.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = capture.receive();
        if (datagram != null) datagrams.add(datagram.data);
      });
      final beacons = StreamIterator(datagrams.stream);

      final alice = await unitDevice(
        aliceId,
        unitSecret: secret,
        roster: [aliceId, bobId],
        beaconPort: _captureBeaconPort,
        beaconInterval: const Duration(milliseconds: 100),
        clock: clock,
      );
      final port = await alice.lan.start();
      final envelope = SealedEnvelope(keys.sealKey, clock: clock);

      /// The rotating ID in the next beacon that opens at the current clock.
      Future<Uint8List> nextBeacon() async {
        while (true) {
          expect(await beacons.moveNext(), isTrue);
          final wire = beacons.current;
          _expectNoCleartext(wire, [alice]);
          expect(wire, hasLength(rotatingIdLength + 2 + sealOverhead));
          try {
            final plain = await envelope.open(wire);
            expect(
              ByteData.sublistView(plain).getUint16(rotatingIdLength),
              port,
            );
            return plain.sublist(0, rotatingIdLength);
          } on SealedEnvelopeException {
            // Sealed before the clock jumped; outside the freshness window now.
          }
        }
      }

      final before = await nextBeacon();
      expect(
        before,
        await rotatingId(keys.idKey, aliceId.publicKey, epochAt(now)),
      );
      now = now.add(const Duration(hours: 1));
      // A beacon whose ID was computed just before the jump may still be in flight.
      var after = await nextBeacon();
      while (_same(after, before)) {
        after = await nextBeacon();
      }
      expect(
        after,
        await rotatingId(keys.idKey, aliceId.publicKey, epochAt(now)),
      );
    },
  );

  test('a link made after an epoch change still resolves both sides', () async {
    var now = DateTime.utc(2026, 11, 15, 9, 59, 30);
    DateTime clock() => now;
    final roster = [aliceId, bobId];
    final alice = await unitDevice(
      aliceId,
      unitSecret: secret,
      roster: roster,
      clock: clock,
    );
    final bob = await unitDevice(
      bobId,
      unitSecret: secret,
      roster: roster,
      clock: clock,
    );
    final port = await bob.lan.start();
    final proxy = await _Proxy.start(port);

    await alice.lan.connect('127.0.0.1', proxy.port);
    await waitFor(() => alice.lan.linkCount == 1 && bob.lan.linkCount == 1);
    final firstId = (await _openAll(
      proxy.toServer.toBytes(),
      SealedEnvelope(keys.sealKey, clock: clock),
    ))[1].sublist(0, rotatingIdLength);
    await alice.lan.stop();
    await waitFor(() => bob.lan.linkCount == 0);

    now = now.add(const Duration(hours: 1));
    final proxy2 = await _Proxy.start(port);
    await alice.lan.connect('127.0.0.1', proxy2.port);
    await waitFor(() => alice.lan.linkCount == 1 && bob.lan.linkCount == 1);
    final secondId = (await _openAll(
      proxy2.toServer.toBytes(),
      SealedEnvelope(keys.sealKey, clock: clock),
    ))[1].sublist(0, rotatingIdLength);

    // Compare the rotating IDs only; the rest of the hello is a fresh challenge.
    expect(_same(firstId, secondId), isFalse);

    await alice.node.sendText(
      bob.node.peerId,
      Uint8List.fromList(utf8.encode('next hour')),
    );
    await waitFor(() => bob.inbox.isNotEmpty);
    expect(utf8.decode(bob.inbox.last.plaintext), 'next hour');
  });

  test('a mesh packet sealed for LAN fits the frame limit', () {
    expect(
      Packet.headerLength + maxPayloadLength + sealOverhead,
      lessThanOrEqualTo(maxFrameLength),
    );
  });
}

bool _same(List<int> a, List<int> b) =>
    a.length == b.length && containsBytes(a, b);
