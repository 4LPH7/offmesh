import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/crypto/identity.dart';
import 'package:offmesh/core/crypto/rotating_id.dart';

const int baseEpoch = 493827;

Uint8List bytes(int start, int length) =>
    Uint8List.fromList(List.generate(length, (i) => (start + i) & 0xff));

String hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

DateTime startOf(int epoch) =>
    DateTime.fromMillisecondsSinceEpoch(epoch * 3600 * 1000, isUtc: true);

void main() {
  final secret = bytes(0, 32);
  final keyA = bytes(0x40, 32);
  final keyB = bytes(0x80, 32);

  test('matches an independently computed HMAC-SHA256 vector', () async {
    // Python: hmac.new(secret, keyA + (493827).to_bytes(8, 'big'), sha256)
    final id = await rotatingId(secret, keyA, baseEpoch);
    expect(hex(id), '078cdb0665ad0e2c');
    final epochBytes = (ByteData(8)..setUint64(0, baseEpoch)).buffer;
    final mac = await Hmac.sha256().calculateMac([
      ...keyA,
      ...epochBytes.asUint8List(),
    ], secretKey: SecretKey(secret));
    expect(hex(mac.bytes.sublist(0, 8)), hex(id));
  });

  test('resolved members cannot be mutated', () async {
    final resolver = await RosterResolver.create(secret, [
      keyA,
    ], clock: () => startOf(baseEpoch));
    final id = await rotatingId(secret, keyA, baseEpoch);
    final member = (await resolver.resolve(id))!;
    expect(() => member.publicKey[0] ^= 1, throwsUnsupportedError);
    expect(() => member.peerId[0] ^= 1, throwsUnsupportedError);
    expect(await resolver.resolve(id), isNotNull);
  });

  test('epochAt floors UTC seconds by the hour', () {
    final start = startOf(baseEpoch);
    expect(epochAt(start), baseEpoch);
    expect(
      epochAt(start.add(const Duration(minutes: 59, seconds: 59))),
      baseEpoch,
    );
    expect(epochAt(start.add(const Duration(hours: 1))), baseEpoch + 1);
    expect(epochAt(start.toLocal()), baseEpoch);
  });

  test('ID changes across an epoch boundary and differs per member', () async {
    final a0 = await rotatingId(secret, keyA, baseEpoch);
    final a1 = await rotatingId(secret, keyA, baseEpoch + 1);
    final b0 = await rotatingId(secret, keyB, baseEpoch);
    expect(a0.length, rotatingIdLength);
    expect(hex(a0), isNot(hex(a1)));
    expect(hex(a0), isNot(hex(b0)));
  });

  test('rejects short secrets, wrong key lengths and negative epochs', () {
    expect(() => rotatingId(bytes(0, 31), keyA, 1), throwsArgumentError);
    expect(() => rotatingId(secret, bytes(0, 31), 1), throwsArgumentError);
    expect(() => rotatingId(secret, bytes(0, 33), 1), throwsArgumentError);
    expect(() => rotatingId(secret, keyA, -1), throwsArgumentError);
    expect(
      () => RosterResolver.create(bytes(0, 31), [keyA]),
      throwsArgumentError,
    );
    expect(
      () => RosterResolver.create(secret, [bytes(0, 16)]),
      throwsArgumentError,
    );
    expect(
      () => RosterResolver.create(secret, [keyA, keyA]),
      throwsArgumentError,
    );
  });

  group('RosterResolver', () {
    late RosterResolver resolver;

    setUp(() async {
      resolver = await RosterResolver.create(secret, [
        keyA,
        keyB,
      ], clock: () => startOf(baseEpoch).add(const Duration(minutes: 30)));
    });

    test('resolves IDs from previous, current and next epochs', () async {
      for (final offset in [-1, 0, 1]) {
        final id = await rotatingId(secret, keyB, baseEpoch + offset);
        final member = await resolver.resolve(id);
        expect(member, isNotNull, reason: 'offset $offset');
        expect(member!.publicKey, keyB);
        expect(member.peerId, await peerIdFor(keyB));
      }
    });

    test('does not resolve IDs two epochs away', () async {
      for (final offset in [-2, 2]) {
        final id = await rotatingId(secret, keyA, baseEpoch + offset);
        expect(await resolver.resolve(id), isNull, reason: 'offset $offset');
      }
    });

    test('unknown ID and other unit secret resolve to null', () async {
      expect(await resolver.resolve(bytes(0xa0, 8)), isNull);
      final foreign = await rotatingId(bytes(1, 32), keyA, baseEpoch);
      expect(await resolver.resolve(foreign), isNull);
    });

    test('rejects wire IDs of the wrong length', () {
      expect(() => resolver.resolve(bytes(0, 7)), throwsArgumentError);
      expect(() => resolver.resolve(bytes(0, 9)), throwsArgumentError);
    });

    test('follows the clock into later epochs', () async {
      var now = startOf(baseEpoch);
      final moving = await RosterResolver.create(secret, [
        keyA,
      ], clock: () => now);
      final old = await rotatingId(secret, keyA, baseEpoch);
      expect(await moving.resolve(old), isNotNull);
      now = startOf(baseEpoch + 2);
      expect(await moving.resolve(old), isNull);
      final fresh = await rotatingId(secret, keyA, baseEpoch + 3);
      expect(await moving.resolve(fresh), isNotNull);
    });
  });

  test('colliding members resolve to null instead of guessing', () async {
    final shared = bytes(0xee, 8);
    Future<Uint8List> derive(List<int> s, List<int> key, int epoch) async =>
        epoch == baseEpoch ? shared : rotatingId(s, key, epoch);
    final resolver = await RosterResolver.create(
      secret,
      [keyA, keyB],
      clock: () => startOf(baseEpoch),
      derive: derive,
    );
    expect(await resolver.resolve(shared), isNull);
    final next = await rotatingId(secret, keyA, baseEpoch + 1);
    expect((await resolver.resolve(next))!.publicKey, keyA);
  });

  test(
    'ID owned by different members in adjacent epochs is ambiguous',
    () async {
      final shared = bytes(0xdd, 8);
      Future<Uint8List> derive(List<int> s, List<int> key, int epoch) async {
        if (epoch == baseEpoch && hex(key) == hex(keyA)) return shared;
        if (epoch == baseEpoch + 1 && hex(key) == hex(keyB)) return shared;
        return rotatingId(s, key, epoch);
      }

      final resolver = await RosterResolver.create(
        secret,
        [keyA, keyB],
        clock: () => startOf(baseEpoch),
        derive: derive,
      );
      expect(await resolver.resolve(shared), isNull);
    },
  );
}
