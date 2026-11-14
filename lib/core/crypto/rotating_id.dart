import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:offmesh/core/crypto/identity.dart';

const int rotatingIdLength = 8;
const int minUnitSecretLength = 32;
const int staticPublicKeyLength = 32;
const Duration epochLength = Duration(hours: 1);

/// Hourly epoch index: floor(UTC unix seconds / 3600).
int epochAt(DateTime time) =>
    time.toUtc().millisecondsSinceEpoch ~/ epochLength.inMilliseconds;

/// HMAC-SHA256(unitSecret, staticPublicKey || epoch as u64 BE), first 8 bytes.
Future<Uint8List> rotatingId(
  List<int> unitSecret,
  List<int> staticPublicKey,
  int epoch,
) async {
  if (unitSecret.length < minUnitSecretLength) {
    throw ArgumentError('unitSecret must be >= $minUnitSecretLength bytes');
  }
  if (staticPublicKey.length != staticPublicKeyLength) {
    throw ArgumentError('public key must be $staticPublicKeyLength bytes');
  }
  if (epoch < 0) throw ArgumentError.value(epoch, 'epoch', 'must be >= 0');
  final message = BytesBuilder(copy: false)
    ..add(staticPublicKey)
    ..add((ByteData(8)..setUint64(0, epoch)).buffer.asUint8List());
  final mac = await Hmac.sha256().calculateMac(
    message.takeBytes(),
    secretKey: SecretKey(List<int>.of(unitSecret)),
  );
  return Uint8List.fromList(mac.bytes.sublist(0, rotatingIdLength));
}

typedef IdDerivation =
    Future<Uint8List> Function(
      List<int> secret,
      List<int> publicKey,
      int epoch,
    );

/// A roster entry: the member's static public key and its stable PeerID.
class RosterMember {
  const RosterMember(this.publicKey, this.peerId);
  final Uint8List publicKey;
  final Uint8List peerId;
}

/// Resolves on-wire rotating IDs to roster members for epochs current-1..+1.
class RosterResolver {
  RosterResolver._(this._secret, this._members, this._clock, this._derive);

  final Uint8List _secret;
  final List<RosterMember> _members;
  final DateTime Function() _clock;
  final IdDerivation _derive;

  /// epoch -> (id hex -> member index, or -1 when two members collide).
  final Map<int, Future<Map<String, int>>> _tables = {};

  /// [derive] defaults to [rotatingId]; tests override it to force collisions.
  static Future<RosterResolver> create(
    List<int> unitSecret,
    List<List<int>> rosterPublicKeys, {
    DateTime Function()? clock,
    IdDerivation derive = rotatingId,
  }) async {
    if (unitSecret.length < minUnitSecretLength) {
      throw ArgumentError('unitSecret must be >= $minUnitSecretLength bytes');
    }
    final seen = <String>{};
    final members = <RosterMember>[];
    for (final key in rosterPublicKeys) {
      if (key.length != staticPublicKeyLength) {
        throw ArgumentError('public key must be $staticPublicKeyLength bytes');
      }
      if (!seen.add(_hex(key))) throw ArgumentError('duplicate roster key');
      final copy = Uint8List.fromList(key).asUnmodifiableView();
      final peerId = (await peerIdFor(copy)).asUnmodifiableView();
      members.add(RosterMember(copy, peerId));
    }
    return RosterResolver._(
      Uint8List.fromList(unitSecret),
      List.unmodifiable(members),
      clock ?? DateTime.now,
      derive,
    );
  }

  /// The member that owns [wireId] in epochs current-1..current+1, or null
  /// when the ID is unknown or matches more than one member.
  Future<RosterMember?> resolve(List<int> wireId) async {
    if (wireId.length != rotatingIdLength) {
      throw ArgumentError('wire ID must be $rotatingIdLength bytes');
    }
    final current = epochAt(_clock());
    _tables.removeWhere((epoch, _) => (epoch - current).abs() > 1);
    final hex = _hex(wireId);
    int? found;
    for (var epoch = current - 1; epoch <= current + 1; epoch++) {
      if (epoch < 0) continue;
      final index = (await (_tables[epoch] ??= _build(epoch)))[hex];
      if (index == null) continue;
      if (index < 0 || (found != null && found != index)) return null;
      found = index;
    }
    return found == null ? null : _members[found];
  }

  Future<Map<String, int>> _build(int epoch) async {
    final table = <String, int>{};
    for (var i = 0; i < _members.length; i++) {
      final hex = _hex(await _derive(_secret, _members[i].publicKey, epoch));
      table[hex] = table.containsKey(hex) ? -1 : i;
    }
    return table;
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
