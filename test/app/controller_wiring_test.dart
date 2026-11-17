import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/app/chat_controller.dart';
import 'package:offmesh/app/history_store.dart';
import 'package:offmesh/app/secret_store.dart';
import 'package:offmesh/app/unit_store.dart';
import 'package:offmesh/core/crypto/identity.dart';
import 'package:offmesh/core/mesh/mesh_node.dart';
import 'package:offmesh/core/protocol/delivery_ack.dart';
import 'package:offmesh/core/protocol/packet.dart';
import 'package:offmesh/core/provisioning/unit_roster.dart';
import 'package:offmesh/transports/ble_manager.dart';
import 'package:offmesh/transports/ble_radio.dart';
import 'package:offmesh/transports/lan_manager.dart';

/// A radio that accepts every call and never hears anyone.
class _QuietRadio implements BleRadio {
  int starts = 0;

  @override
  Stream<BleSighting> get sightings => const Stream.empty();

  @override
  Stream<BleChannel> get inboundChannels => const Stream.empty();

  @override
  Future<void> startAdvertising(Uint8List rotatingId) async => starts++;

  @override
  Future<void> stopAdvertising() async {}

  @override
  Future<void> startScan() async {}

  @override
  Future<void> stopScan() async {}

  @override
  Future<BleChannel> connect(String address) => Completer<BleChannel>().future;
}

/// A store whose writes wait for [gate] while [hold] is true.
class _GatedStore implements SecretStore {
  final MemorySecretStore inner = MemorySecretStore();
  bool hold = false;
  Completer<void> gate = Completer<void>();

  @override
  Future<Uint8List?> read(String key) => inner.read(key);

  @override
  Future<void> write(String key, Uint8List value) async {
    if (hold && key == historyKey) await gate.future;
    await inner.write(key, value);
  }

  @override
  Future<void> delete(String key) => inner.delete(key);
}

class _Clock {
  DateTime now = DateTime.utc(2026, 11, 17, 12);
  DateTime call() => now;
}

Future<(ChatController, Identity)> _controller({
  SecretStore? store,
  _Clock? clock,
  BleRadio? radio,
  Future<bool> Function()? bleAllowed,
}) async {
  final me = await Identity.generate();
  final bob = await Identity.generate();
  final node = MeshNode(
    identity: me,
    transports: const [],
    random: Random(1),
    delay: (_) async {},
    clock: clock?.call,
  );
  final lan = LanManager(node: node, beaconPort: 0);
  final controller = ChatController(
    node: node,
    lan: lan,
    store: store ?? MemorySecretStore(),
    clock: clock?.call,
    ble: radio == null
        ? null
        : BleManager(node: node, radio: radio, posture: lan.posture),
    bleAllowed: bleAllowed,
  );
  addTearDown(controller.stop);
  await controller.start();
  await controller.importUnit(
    UnitRoster(UnitStore.generateSecret(), [
      UnitMember(me.publicKey, 'Me'),
      UnitMember(bob.publicKey, 'Bob'),
    ]).toText(),
  );
  return (controller, bob);
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  group('store-and-forward hand-over', () {
    test('no receipt after 15 s: the message is held for carrying', () async {
      final clock = _Clock();
      final (c, bob) = await _controller(clock: clock);
      await c.send(bob.peerId.hex, 'over');
      await c.custodyTick();
      expect(c.courier.store.length, 0, reason: 'not yet overdue');

      clock.now = clock.now.add(ChatController.custodyFallbackAfter);
      await c.custodyTick();
      expect(c.courier.store.length, 1);
    });

    test('a receipt before 15 s means nothing is held', () async {
      final clock = _Clock();
      final (c, bob) = await _controller(clock: clock);
      await c.send(bob.peerId.hex, 'over');
      c.handleReceipt(
        DeliveryReceiptEvent(
          peerId: bob.peerId,
          receipt: DeliveryReceipt(
            packetId: c.thread(bob.peerId.hex).single.packetId!,
            receivedAt: clock.now,
          ),
        ),
      );
      clock.now = clock.now.add(const Duration(minutes: 1));
      await c.custodyTick();
      expect(c.courier.store.length, 0);
    });

    test('a late receipt stops carrying a held copy', () async {
      final clock = _Clock();
      final (c, bob) = await _controller(clock: clock);
      await c.send(bob.peerId.hex, 'over');
      final packetId = c.thread(bob.peerId.hex).single.packetId!;
      clock.now = clock.now.add(ChatController.custodyFallbackAfter);
      await c.custodyTick();
      expect(c.courier.store.length, 1);
      c.handleReceipt(
        DeliveryReceiptEvent(
          peerId: bob.peerId,
          receipt: DeliveryReceipt(packetId: packetId, receivedAt: clock.now),
        ),
      );
      expect(c.courier.store.length, 0);
    });

    test('the same message arriving twice is shown once', () async {
      final (c, bob) = await _controller();
      final copy = ReceivedMessage(
        senderId: bob.peerId,
        plaintext: Uint8List.fromList(utf8.encode('hi')),
        packetId: 9,
      );
      c.handleIncoming(copy);
      c.handleIncoming(copy);
      expect(c.thread(bob.peerId.hex).length, 1);
    });
  });

  group('Bluetooth start', () {
    test(
      'a permission prompt that never answers does not hold up start',
      () async {
        final radio = _QuietRadio();
        final (c, _) = await _controller(
          radio: radio,
          bleAllowed: () => Completer<bool>().future,
        );
        expect(c.provisioned, isTrue);
        expect(c.ble!.running, isFalse);
      },
    );

    test('granted starts the radio; denied says so', () async {
      final granted = _QuietRadio();
      final (on, _) = await _controller(
        radio: granted,
        bleAllowed: () async => true,
      );
      await _settle();
      expect(on.ble!.running, isTrue);
      expect(granted.starts, greaterThan(0));
      expect(on.bleStatus, isNull);

      final (off, _) = await _controller(
        radio: _QuietRadio(),
        bleAllowed: () async => false,
      );
      await _settle();
      expect(off.ble!.running, isFalse);
      expect(off.bleStatus, 'Bluetooth off: permission not granted');
    });
  });

  test('a history save in flight cannot outlive the wipe', () async {
    final store = _GatedStore();
    final (c, bob) = await _controller(store: store);
    store.hold = true;
    c.handleIncoming(
      ReceivedMessage(
        senderId: bob.peerId,
        plaintext: Uint8List.fromList(utf8.encode('secret')),
        packetId: 3,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 700));
    final wipe = c.panicWipe();
    await _settle();
    store.gate.complete();
    expect(await wipe, isTrue);
    expect(await store.read(historyKey), isNull);
  });
}
