import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/app/unit_store.dart';
import 'package:offmesh/core/crypto/identity.dart';
import 'package:offmesh/core/crypto/unit_keys.dart';
import 'package:offmesh/core/mesh/mesh_node.dart';
import 'package:offmesh/core/posture.dart';
import 'package:offmesh/core/protocol/packet.dart';
import 'package:offmesh/transports/ble_manager.dart';
import 'package:offmesh/transports/ble_radio.dart';

import 'ble_fake_radio.dart';

/// Radios in one room: each hears the others' advertisements while scanning.
class _Air {
  final Map<String, _FakeRadio> radios = {};
}

class _FakeRadio implements BleRadio {
  _FakeRadio(this.air, this.address) {
    air.radios[address] = this;
  }

  final _Air air;
  final String address;
  Uint8List? advertising;
  bool scanning = false;
  final _sightings = StreamController<BleSighting>.broadcast();
  final _inbound = StreamController<BleChannel>.broadcast();

  @override
  Stream<BleSighting> get sightings => _sightings.stream;

  @override
  Stream<BleChannel> get inboundChannels => _inbound.stream;

  @override
  Future<void> startAdvertising(Uint8List rotatingId) async =>
      advertising = rotatingId;

  @override
  Future<void> stopAdvertising() async => advertising = null;

  @override
  Future<void> startScan() async => scanning = true;

  @override
  Future<void> stopScan() async => scanning = false;

  /// Delivers one round of sightings to every scanning radio.
  static void sweep(_Air air) {
    for (final scanner in air.radios.values.where((r) => r.scanning)) {
      for (final other in air.radios.values) {
        final ad = other.advertising;
        if (identical(other, scanner) || ad == null) continue;
        scanner._sightings.add(
          BleSighting(address: other.address, rotatingId: ad),
        );
      }
    }
  }

  @override
  Future<BleChannel> connect(String address) async {
    final target = air.radios[address]!;
    final (client, server) = FakeBleChannel.pair(mtu: 185);
    target._inbound.add(server);
    return client;
  }
}

Future<(MeshNode, BleManager, PostureController)> _phone(
  _Air air,
  String address,
  Identity id,
  UnitKeys keys,
  List<Uint8List> roster,
) async {
  final node = MeshNode(
    identity: id,
    transports: const [],
    random: Random(1),
    delay: (_) async {},
  );
  final posture = PostureController();
  final ble = BleManager(
    node: node,
    radio: _FakeRadio(air, address),
    posture: posture,
    dialYield: Duration.zero,
  );
  await ble.configure(keys, roster);
  node.start();
  addTearDown(() async {
    await ble.stop();
    await node.stop();
  });
  return (node, ble, posture);
}

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test(
    'two members link over BLE, chat, and Quiet then Silent apply',
    () async {
      final air = _Air();
      final a = await Identity.generate();
      final b = await Identity.generate();
      final keys = await UnitKeys.derive(UnitStore.generateSecret());
      final roster = [a.publicKey, b.publicKey];
      final (nodeA, bleA, postureA) = await _phone(air, 'AA', a, keys, roster);
      final (nodeB, bleB, _) = await _phone(air, 'BB', b, keys, roster);

      await bleA.start();
      await bleB.start();
      expect(air.radios['AA']!.advertising, isNotNull);
      _FakeRadio.sweep(air);
      await _until(
        () => bleA.linkedPeerIds.isNotEmpty && bleB.linkedPeerIds.isNotEmpty,
      );
      expect(bleA.linkedPeerIds, {b.peerId.hex});
      expect(bleB.linkedPeerIds, {a.peerId.hex});

      final got = nodeB.messages.first;
      await nodeA.sendText(b.peerId, Uint8List.fromList(utf8.encode('over')));
      expect(
        utf8.decode((await got.timeout(const Duration(seconds: 5))).plaintext),
        'over',
      );

      postureA.change(Posture.quiet);
      await bleA.applyPosture();
      expect(air.radios['AA']!.advertising, isNull);
      expect(air.radios['AA']!.scanning, isFalse);
      expect(bleA.linkedPeerIds, isNotEmpty, reason: 'Quiet keeps open links');

      postureA.change(Posture.silent);
      await bleA.applyPosture();
      expect(bleA.running, isFalse);
      expect(bleA.linkedPeerIds, isEmpty);
    },
  );

  test('a phone outside the roster is never linked', () async {
    final air = _Air();
    final a = await Identity.generate();
    final stranger = await Identity.generate();
    final keys = await UnitKeys.derive(UnitStore.generateSecret());
    final (_, bleA, _) = await _phone(air, 'AA', a, keys, [a.publicKey]);
    final (_, bleS, _) = await _phone(
      air,
      'SS',
      stranger,
      await UnitKeys.derive(UnitStore.generateSecret()),
      [stranger.publicKey],
    );
    await bleA.start();
    await bleS.start();
    _FakeRadio.sweep(air);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(bleA.linkedPeerIds, isEmpty);
    expect(bleS.linkedPeerIds, isEmpty);
  });

  test('Silent at start leaves the radio untouched', () async {
    final air = _Air();
    final a = await Identity.generate();
    final keys = await UnitKeys.derive(UnitStore.generateSecret());
    final (_, bleA, posture) = await _phone(air, 'AA', a, keys, [a.publicKey]);
    posture.change(Posture.silent);
    await bleA.start();
    expect(bleA.running, isFalse);
    expect(air.radios['AA']!.advertising, isNull);
  });
}
