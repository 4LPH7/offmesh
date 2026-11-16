import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/channel/channel_crypto.dart';
import 'package:offmesh/core/crypto/identity.dart';
import 'package:offmesh/core/mesh/mesh_node.dart';
import 'package:offmesh/core/protocol/packet.dart';

import '../mesh/fake_network.dart';

final List<int> _secret = List<int>.generate(32, (i) => i);
final Uint8List _alice = Uint8List.fromList(List.filled(8, 0xA1));
final Uint8List _bob = Uint8List.fromList(List.filled(8, 0xB2));

Future<void> _noDelay(Duration _) async {}

void main() {
  group('channel keys', () {
    test(
      'the same name in any case and spacing gives the same key and tag',
      () async {
        final a = await ChannelKey.derive(_secret, 'Ops');
        final b = await ChannelKey.derive(_secret, '  ops ');
        expect(a.name, 'ops');
        expect(a.key, b.key);
        expect(a.tag, b.tag);
      },
    );

    test(
      'different names or unit secrets give different keys and tags',
      () async {
        final ops = await ChannelKey.derive(_secret, 'ops');
        final med = await ChannelKey.derive(_secret, 'med');
        final otherUnit = await ChannelKey.derive(
          List<int>.generate(32, (i) => i + 1),
          'ops',
        );
        expect(ops.key, isNot(med.key));
        expect(ops.tag, isNot(med.tag));
        expect(ops.key, isNot(otherUnit.key));
        expect(ops.tag, isNot(otherUnit.tag));
        expect(ops.key.sublist(0, channelTagLength), isNot(ops.tag));
      },
    );

    test('empty, too long and short-secret inputs are refused', () async {
      expect(
        () => normalizeChannelName('   '),
        throwsA(isA<ChannelFormatException>()),
      );
      expect(
        () => normalizeChannelName('x' * (maxChannelNameBytes + 1)),
        throwsA(isA<ChannelFormatException>()),
      );
      expect(ChannelKey.derive(List.filled(31, 1), 'ops'), throwsArgumentError);
    });
  });

  group('channel messages', () {
    test('round trip keeps counter and text; the tag leads the blob', () async {
      final ops = await ChannelKey.derive(_secret, 'ops');
      final blob = await sealChannelMessage(
        ops,
        senderId: _alice,
        counter: 1234567,
        text: utf8.encode('rally at gate'),
      );
      expect(blob.length, channelOverhead + 'rally at gate'.length);
      expect(channelTagOf(blob), ops.tag);

      final opened = await openChannelMessage(ops, blob, senderId: _alice);
      expect(opened.counter, 1234567);
      expect(utf8.decode(opened.text), 'rally at gate');
    });

    test('the text does not appear in the blob', () async {
      final ops = await ChannelKey.derive(_secret, 'ops');
      final blob = await sealChannelMessage(
        ops,
        senderId: _alice,
        counter: 1,
        text: utf8.encode('secret-plan'),
      );
      expect(
        latin1.decode(blob, allowInvalid: true),
        isNot(contains('secret-plan')),
      );
    });

    test(
      'another sender ID, another channel, or any flipped bit fails',
      () async {
        final ops = await ChannelKey.derive(_secret, 'ops');
        final med = await ChannelKey.derive(_secret, 'med');
        final blob = await sealChannelMessage(
          ops,
          senderId: _alice,
          counter: 7,
          text: utf8.encode('hi'),
        );

        await expectLater(
          openChannelMessage(ops, blob, senderId: _bob),
          throwsA(isA<ChannelFormatException>()),
        );
        await expectLater(
          openChannelMessage(med, blob, senderId: _alice),
          throwsA(isA<ChannelFormatException>()),
        );
        for (var i = channelTagLength; i < blob.length; i++) {
          final tampered = Uint8List.fromList(blob)..[i] ^= 0x01;
          await expectLater(
            openChannelMessage(ops, tampered, senderId: _alice),
            throwsA(isA<ChannelFormatException>()),
            reason: 'byte $i',
          );
        }
        await expectLater(
          openChannelMessage(
            ops,
            blob.sublist(0, channelOverhead - 1),
            senderId: _alice,
          ),
          throwsA(isA<ChannelFormatException>()),
        );
      },
    );
  });

  group('channels on the mesh', () {
    Future<List<MeshNode>> line(FakeTopology topology, int count) async => [
      for (var i = 0; i < count; i++)
        MeshNode(
          identity: await Identity.generate(),
          transports: topology.transportsOf(i),
          random: Random(i),
          delay: _noDelay,
        )..start(),
    ];

    test(
      'members receive once, through a relay that is not on the channel',
      () async {
        // 0 - 1 - 2 - 3. Node 1 relays but has not joined; node 3 joined another channel.
        final topology = FakeTopology(4, const [(0, 1), (1, 2), (2, 3)]);
        final nodes = await line(topology, 4);
        final ops = await ChannelKey.derive(_secret, 'ops');
        final med = await ChannelKey.derive(_secret, 'med');
        nodes[0].joinChannel(ops);
        nodes[2].joinChannel(ops);
        nodes[3].joinChannel(med);
        final inboxes = [for (final _ in nodes) <ChannelMessage>[]];
        for (var i = 0; i < nodes.length; i++) {
          nodes[i].channelMessages.listen(inboxes[i].add);
        }

        final long = 'x' * 500; // forces fragmentation
        await nodes[0].sendChannel(ops, Uint8List.fromList(utf8.encode(long)));
        await pumpEventQueue();

        expect(inboxes[2], hasLength(1));
        expect(utf8.decode(inboxes[2].single.text), long);
        expect(inboxes[2].single.senderId, nodes[0].peerId);
        expect(inboxes[1], isEmpty);
        expect(inboxes[3], isEmpty);
        expect(inboxes[0], isEmpty, reason: 'own messages are not echoed back');
      },
    );

    test(
      'a replay under a new packet ID is refused by the per-sender window',
      () async {
        // 0 - 1, plus an attacker endpoint (2) linked to 1 that injects recorded frames.
        final topology = FakeTopology(3, const [(0, 1), (1, 2)]);
        final nodes = await line(topology, 2);
        final ops = await ChannelKey.derive(_secret, 'ops');
        nodes[0].joinChannel(ops);
        nodes[1].joinChannel(ops);
        final inbox = <ChannelMessage>[];
        nodes[1].channelMessages.listen(inbox.add);

        await nodes[0].sendChannel(
          ops,
          Uint8List.fromList(utf8.encode('once')),
        );
        await pumpEventQueue();
        expect(inbox, hasLength(1));

        final recorded = Packet.decode(
          topology.network.frames.firstWhere(
            (f) => Packet.decode(f).type == PacketType.channel,
          ),
        );
        final replay = Packet(
          type: recorded.type,
          ttl: recorded.ttl,
          packetId: (recorded.packetId + 1) & 0xFFFFFFFF,
          senderId: recorded.senderId,
          recipientId: recorded.recipientId,
          fragIdx: recorded.fragIdx,
          fragTotal: recorded.fragTotal,
          payload: recorded.payload,
        ).encode();
        await topology.transportsOf(2).single.send(replay);
        await pumpEventQueue();

        expect(inbox, hasLength(1));
      },
    );

    test('later messages from one sender are all accepted', () async {
      final topology = FakeTopology(2, const [(0, 1)]);
      final nodes = await line(topology, 2);
      final ops = await ChannelKey.derive(_secret, 'ops');
      nodes[0].joinChannel(ops);
      nodes[1].joinChannel(ops);
      final inbox = <ChannelMessage>[];
      nodes[1].channelMessages.listen(inbox.add);

      for (var i = 0; i < 5; i++) {
        await nodes[0].sendChannel(ops, Uint8List.fromList(utf8.encode('m$i')));
      }
      await pumpEventQueue();

      expect(
        [for (final m in inbox) utf8.decode(m.text)],
        ['m0', 'm1', 'm2', 'm3', 'm4'],
      );
    });
  });
}
