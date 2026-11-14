import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const int unitFormatVersion = 1;
const int unitSecretLength = 32;
const int memberKeyLength = 32;
const int maxMemberNameBytes = 16;

/// Largest roster that still fits one QR code at error-correction level M.
const int maxUnitMembers = 32;

const String unitCodePrefix = 'OFFM-UNIT1:';
const String identityCodePrefix = 'OFFM-ID1:';

/// A unit code, identity code or stored unit is malformed. Never carries key bytes.
class RosterFormatException implements Exception {
  const RosterFormatException(this.message);

  final String message;

  @override
  String toString() => 'RosterFormatException: $message';
}

/// One unit member: a static X25519 public key and a short display name.
class UnitMember {
  UnitMember(List<int> publicKey, this.name)
    : publicKey = Uint8List.fromList(publicKey).asUnmodifiableView() {
    if (publicKey.length != memberKeyLength) {
      throw const RosterFormatException(
        'public key must be $memberKeyLength bytes',
      );
    }
    _checkName(name);
  }

  final Uint8List publicKey;
  final String name;
}

/// The shared unit secret plus every member's public key. Unsigned in v1: whoever
/// holds the unit secret is trusted.
class UnitRoster {
  UnitRoster(List<int> unitSecret, List<UnitMember> members)
    : unitSecret = Uint8List.fromList(unitSecret).asUnmodifiableView(),
      members = List.unmodifiable(members) {
    if (unitSecret.length != unitSecretLength) {
      throw const RosterFormatException(
        'unit secret must be $unitSecretLength bytes',
      );
    }
    if (members.isEmpty || members.length > maxUnitMembers) {
      throw const RosterFormatException(
        'a unit has 1 to $maxUnitMembers members',
      );
    }
    final seen = <String>{};
    for (final member in members) {
      if (!seen.add(base64Encode(member.publicKey))) {
        throw const RosterFormatException('duplicate member key');
      }
    }
  }

  final Uint8List unitSecret;
  final List<UnitMember> members;

  bool contains(List<int> publicKey) =>
      members.any((m) => _equal(m.publicKey, publicKey));

  /// A copy with [member] added. Throws on a duplicate key or a full roster.
  UnitRoster withMember(UnitMember member) =>
      UnitRoster(unitSecret, [...members, member]);

  Uint8List encode() {
    final out = BytesBuilder(copy: false)
      ..addByte(unitFormatVersion)
      ..add(unitSecret)
      ..addByte(members.length);
    for (final member in members) {
      final name = utf8.encode(member.name);
      out
        ..add(member.publicKey)
        ..addByte(name.length)
        ..add(name);
    }
    return out.takeBytes();
  }

  static UnitRoster decode(List<int> bytes) {
    final reader = _Reader(bytes);
    if (reader.byte() != unitFormatVersion) {
      throw const RosterFormatException('unknown unit format version');
    }
    final secret = reader.take(unitSecretLength);
    final count = reader.byte();
    if (count == 0 || count > maxUnitMembers) {
      throw const RosterFormatException(
        'a unit has 1 to $maxUnitMembers members',
      );
    }
    final members = <UnitMember>[];
    for (var i = 0; i < count; i++) {
      final key = reader.take(memberKeyLength);
      members.add(UnitMember(key, _decodeName(reader.take(reader.byte()))));
    }
    reader.end();
    return UnitRoster(secret, members);
  }

  String toText() => unitCodePrefix + base64Url.encode(encode());

  static UnitRoster fromText(String text) =>
      decode(_decodeText(text, unitCodePrefix, 'unit code'));
}

/// What a phone shows so a unit member can add it: its public key and name.
class IdentityCode {
  static String encode(UnitMember member) =>
      identityCodePrefix +
      base64Url.encode([...member.publicKey, ...utf8.encode(member.name)]);

  static UnitMember decode(String text) {
    final bytes = _decodeText(text, identityCodePrefix, 'identity code');
    if (bytes.length <= memberKeyLength) {
      throw const RosterFormatException('identity code is too short');
    }
    return UnitMember(
      bytes.sublist(0, memberKeyLength),
      _decodeName(bytes.sublist(memberKeyLength)),
    );
  }
}

/// SHA-256 of the public key, first 16 bytes, as 8 groups of 4 hex digits.
Future<String> fingerprint(List<int> publicKey) async {
  final digest = (await Sha256().hash(publicKey)).bytes.sublist(0, 16);
  final hex = digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return [
    for (var i = 0; i < hex.length; i += 4) hex.substring(i, i + 4),
  ].join(' ');
}

void _checkName(String name) {
  final length = utf8.encode(name).length;
  if (length == 0 || length > maxMemberNameBytes) {
    throw const RosterFormatException(
      'name must be 1 to $maxMemberNameBytes bytes',
    );
  }
}

String _decodeName(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    throw const RosterFormatException('name is not valid UTF-8');
  }
}

Uint8List _decodeText(String text, String prefix, String what) {
  final clean = text.trim();
  if (!clean.startsWith(prefix)) {
    throw RosterFormatException('not an OffMesh $what');
  }
  try {
    return base64Url.decode(
      base64Url.normalize(clean.substring(prefix.length)),
    );
  } on FormatException {
    throw RosterFormatException('$what is damaged');
  }
}

bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _Reader {
  _Reader(this._bytes);

  final List<int> _bytes;
  int _offset = 0;

  int byte() => take(1)[0];

  Uint8List take(int length) {
    if (_offset + length > _bytes.length) {
      throw const RosterFormatException('unit data is truncated');
    }
    final out = Uint8List.fromList(_bytes.sublist(_offset, _offset + length));
    _offset += length;
    return out;
  }

  void end() {
    if (_offset != _bytes.length) {
      throw const RosterFormatException('unit data has trailing bytes');
    }
  }
}
