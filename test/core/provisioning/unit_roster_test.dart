import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/provisioning/unit_roster.dart';
import 'package:qr_flutter/qr_flutter.dart';

Uint8List _bytes(int fill, [int length = 32]) =>
    Uint8List.fromList(List.filled(length, fill));

UnitRoster _roster(int members, {String name = 'a'}) => UnitRoster(_bytes(7), [
  for (var i = 0; i < members; i++) UnitMember(_bytes(i + 1), name),
]);

Matcher get _rejected => throwsA(isA<RosterFormatException>());

void main() {
  group('unit roster codec', () {
    test('round trips bytes and text, keeping order and names', () {
      final roster = UnitRoster(_bytes(9), [
        UnitMember(_bytes(1), 'Alpha 1'),
        UnitMember(_bytes(2), 'Ñandú ✓'),
      ]);

      for (final decoded in [
        UnitRoster.decode(roster.encode()),
        UnitRoster.fromText(roster.toText()),
        UnitRoster.fromText('  ${roster.toText()}\n'),
        UnitRoster.fromText(roster.toText().replaceAll('=', '')),
      ]) {
        expect(decoded.unitSecret, roster.unitSecret);
        expect(decoded.members.map((m) => m.name), ['Alpha 1', 'Ñandú ✓']);
        expect(decoded.members[1].publicKey, _bytes(2));
      }
      expect(roster.toText(), startsWith(unitCodePrefix));
    });

    test('a full roster with 16-byte names fits one QR code at level M', () {
      final text = _roster(maxUnitMembers, name: 'x' * 16).toText();

      expect(
        QrValidator.validate(
          data: text,
          errorCorrectionLevel: QrErrorCorrectLevel.M,
        ).isValid,
        isTrue,
      );
    });

    test('every truncation is rejected', () {
      final bytes = _roster(3).encode();
      for (var length = 0; length < bytes.length; length++) {
        expect(
          () => UnitRoster.decode(bytes.sublist(0, length)),
          _rejected,
          reason: 'length $length',
        );
      }
    });

    test('trailing bytes, bad version and bad member count are rejected', () {
      final bytes = _roster(2).encode();
      expect(() => UnitRoster.decode([...bytes, 0]), _rejected);
      expect(() => UnitRoster.decode([2, ...bytes.sublist(1)]), _rejected);
      expect(() => UnitRoster.decode([...bytes.sublist(0, 33), 0]), _rejected);
      final over = _roster(maxUnitMembers).encode();
      over[33] = maxUnitMembers + 1;
      expect(() => UnitRoster.decode(over), _rejected);
    });

    test('empty, over-long and non-UTF-8 names are rejected', () {
      List<int> withName(List<int> name) => [
        1,
        ..._bytes(7),
        1,
        ..._bytes(1),
        name.length,
        ...name,
      ];
      expect(
        UnitRoster.decode(withName(utf8.encode('x' * 16))).members,
        hasLength(1),
      );
      expect(() => UnitRoster.decode(withName([])), _rejected);
      expect(
        () => UnitRoster.decode(withName(utf8.encode('x' * 17))),
        _rejected,
      );
      expect(() => UnitRoster.decode(withName([0xff, 0xfe])), _rejected);
      expect(() => UnitMember(_bytes(1), ''), _rejected);
      expect(() => UnitMember(_bytes(1), 'é' * 9), _rejected);
    });

    test('duplicate keys, wrong lengths and member limits are rejected', () {
      final bytes = BytesBuilder()
        ..addByte(1)
        ..add(_bytes(7))
        ..addByte(2);
      for (var i = 0; i < 2; i++) {
        bytes
          ..add(_bytes(1))
          ..addByte(1)
          ..addByte(0x61);
      }
      expect(() => UnitRoster.decode(bytes.toBytes()), _rejected);
      expect(
        () => _roster(1).withMember(UnitMember(_bytes(1), 'b')),
        _rejected,
      );
      expect(
        () => _roster(maxUnitMembers).withMember(UnitMember(_bytes(99), 'b')),
        _rejected,
      );
      expect(() => UnitRoster(_bytes(7), const []), _rejected);
      expect(
        () => UnitRoster(_bytes(7, 31), [UnitMember(_bytes(1), 'a')]),
        _rejected,
      );
      expect(() => UnitMember(_bytes(1, 31), 'a'), _rejected);
    });

    test('wrong prefix and damaged base64 are rejected', () {
      final text = _roster(1).toText();
      expect(() => UnitRoster.fromText(''), _rejected);
      expect(() => UnitRoster.fromText(text.substring(1)), _rejected);
      expect(() => UnitRoster.fromText('$unitCodePrefix!!!'), _rejected);
      expect(() => UnitRoster.fromText('${text}A'), _rejected);
      expect(
        () => UnitRoster.fromText(
          IdentityCode.encode(UnitMember(_bytes(1), 'a')),
        ),
        _rejected,
      );
    });
  });

  group('identity code', () {
    test('round trips key and name', () {
      final code = IdentityCode.encode(UnitMember(_bytes(5), 'Bravo'));

      final member = IdentityCode.decode(' $code ');

      expect(code, startsWith(identityCodePrefix));
      expect(member.publicKey, _bytes(5));
      expect(member.name, 'Bravo');
    });

    test('short, nameless, long-named and foreign codes are rejected', () {
      String code(List<int> bytes) =>
          identityCodePrefix + base64Url.encode(bytes);
      expect(() => IdentityCode.decode(code(_bytes(5, 31))), _rejected);
      expect(() => IdentityCode.decode(code(_bytes(5))), _rejected);
      expect(
        () =>
            IdentityCode.decode(code([..._bytes(5), ...utf8.encode('x' * 17)])),
        _rejected,
      );
      expect(() => IdentityCode.decode(code([..._bytes(5), 0xff])), _rejected);
      expect(() => IdentityCode.decode(_roster(1).toText()), _rejected);
    });
  });

  test(
    'fingerprint is SHA-256 first 16 bytes in groups of 4 hex digits',
    () async {
      // SHA-256 of 32 zero bytes starts 66687aadf862bd776c8fc18b8e9f8e20.
      expect(
        await fingerprint(Uint8List(32)),
        '6668 7aad f862 bd77 6c8f c18b 8e9f 8e20',
      );
    },
  );
}
