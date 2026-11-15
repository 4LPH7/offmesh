import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/crypto/identity.dart';
import '../core/crypto/unit_keys.dart';
import '../core/mesh/mesh_node.dart';
import '../core/posture.dart';
import '../core/protocol/packet.dart';
import '../core/provisioning/unit_roster.dart';
import '../transports/lan_manager.dart';
import 'panic_wipe.dart';
import 'posture_store.dart';
import 'secret_store.dart';
import 'unit_store.dart';

class ChatMessage {
  const ChatMessage({
    required this.outgoing,
    required this.text,
    required this.at,
    this.packetId,
    this.delivered = false,
    this.queued = false,
  });

  final bool outgoing;
  final String text;
  final DateTime at;

  /// The mesh packet ID of an outgoing message; its receipt carries the same ID.
  final int? packetId;

  /// True once the recipient's receipt for [packetId] has arrived.
  final bool delivered;

  /// True while a Quiet-mode message waits for the send-burst button.
  final bool queued;

  ChatMessage asDelivered() => ChatMessage(
    outgoing: outgoing,
    text: text,
    at: at,
    packetId: packetId,
    delivered: true,
  );
}

/// An outgoing message held in Quiet mode, with the contact it is for.
class _Queued {
  const _Queued(this.contactId, this.message);

  final String contactId;
  final ChatMessage message;
}

/// A roster member as the UI shows it.
class MemberInfo {
  const MemberInfo({
    required this.name,
    required this.peerId,
    required this.fingerprint,
    required this.isSelf,
  });

  final String name;
  final String peerId;
  final String fingerprint;
  final bool isSelf;
}

/// App state: unit provisioning, contacts (the roster members), one thread per
/// contact, and the node that carries the messages. LAN starts only once a unit exists.
class ChatController extends ChangeNotifier {
  ChatController({
    required this.node,
    required this.lan,
    required this.store,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final MeshNode node;
  final LanManager lan;
  final SecretStore store;
  final DateTime Function() _clock;

  final Map<String, List<ChatMessage>> _threads = {};
  UnitRoster? _unit;
  List<MemberInfo> _members = const [];
  String _myFingerprint = '';
  String? _selected;
  String? _lastError;
  int? _listenPort;
  StreamSubscription<ReceivedMessage>? _subscription;
  StreamSubscription<DeliveryReceiptEvent>? _receiptSubscription;
  final List<_Queued> _queue = [];

  /// The radio posture, shared with [lan], which checks it before every transmission.
  PostureController get posture => lan.posture;

  /// Outgoing messages held in Quiet mode until [sendBurst].
  int get queuedCount => _queue.length;

  String get myId => node.peerId.hex;

  String get myFingerprint => _myFingerprint;

  bool get provisioned => _unit != null;

  int? get listenPort => _listenPort;

  /// Every roster member, this phone included.
  List<MemberInfo> get members => _members;

  /// Roster members other than this phone, by PeerID hex.
  List<String> get contacts => [
    for (final m in _members)
      if (!m.isSelf) m.peerId,
  ];

  String nameOf(String peerId) => _members
      .firstWhere(
        (m) => m.peerId == peerId,
        orElse: () => MemberInfo(
          name: peerId,
          peerId: peerId,
          fingerprint: '',
          isSelf: false,
        ),
      )
      .name;

  /// The unit code to share as QR or text; null when unprovisioned.
  String? get unitCode => _unit?.toText();

  /// This phone's identity code under its roster name; null when unprovisioned.
  String? get myIdentityCode {
    final self = _members.where((m) => m.isSelf);
    return self.isEmpty ? null : identityCodeFor(self.first.name);
  }

  /// This phone's identity code under [name], or null when the name is invalid.
  String? identityCodeFor(String name) {
    try {
      return IdentityCode.encode(UnitMember(node.identity.publicKey, name));
    } on RosterFormatException {
      return null;
    }
  }

  String? get selectedContact => _selected;

  String? get lastError => _lastError;

  Set<String> get linkedNeighbours => lan.linkedPeerIds;

  List<ChatMessage> thread(String contactId) =>
      List.unmodifiable(_threads[contactId] ?? const []);

  /// Loads the stored unit and starts LAN only if there is one. A damaged stored
  /// unit leaves the phone unprovisioned with an error; importing replaces it.
  Future<void> start() async {
    _subscription = node.messages.listen(handleIncoming);
    _receiptSubscription = node.receipts.listen(handleReceipt);
    node.start();
    _myFingerprint = await fingerprint(node.identity.publicKey);
    // Before any LAN start: a Silent phone must not bind a socket on launch.
    posture.change(await PostureStore.load(store));
    try {
      final unit = await UnitStore.load(store);
      if (unit != null) {
        await _apply(unit);
        await _startLan();
      }
    } on UnitStoreException catch (e) {
      _lastError = '${e.message}. Join the unit again.';
    }
    notifyListeners();
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    await _receiptSubscription?.cancel();
    await lan.stop();
    _listenPort = null;
    await node.stop();
  }

  /// Creates a new unit with this phone as its only member.
  Future<bool> createUnit(String myName) => _guard(() async {
    if (provisioned) throw const RosterFormatException('already in a unit');
    final roster = UnitRoster(UnitStore.generateSecret(), [
      UnitMember(node.identity.publicKey, myName.trim()),
    ]);
    await _install(roster);
  });

  /// Adds the phone behind [identityCode] to this unit's roster.
  Future<bool> addMember(String identityCode) => _guard(() async {
    final unit = _unit;
    if (unit == null) throw const RosterFormatException('not in a unit');
    await _install(unit.withMember(IdentityCode.decode(identityCode)));
  });

  /// Joins (or re-joins) the unit in [unitCode], replacing any stored unit. Refused
  /// unless the roster lists this phone's own public key.
  Future<bool> importUnit(String unitCode) => _guard(() async {
    final roster = UnitRoster.fromText(unitCode);
    if (!roster.contains(node.identity.publicKey)) {
      throw const RosterFormatException(
        'this unit code does not list this phone; '
        'ask a member to add your identity code first',
      );
    }
    await _install(roster, restartLan: true);
  });

  /// Dials a neighbour by IP address. Failures are reported through [lastError].
  Future<void> connect(String host, int port) async {
    if (!provisioned) {
      reportError('Join a unit before linking');
      return;
    }
    if (posture.current == Posture.silent) {
      reportError('Silent: no connections. Set Normal or Quiet first');
      return;
    }
    try {
      await lan.connect(host, port);
      _lastError = null;
    } catch (error) {
      _lastError = 'Could not reach $host:$port';
    }
    notifyListeners();
  }

  /// Shows a user-facing error (for example, invalid input) until the next successful action.
  void reportError(String message) {
    _lastError = message;
    notifyListeners();
  }

  void select(String contactId) {
    _selected = contactId;
    notifyListeners();
  }

  /// Sends [text], or in Quiet holds it until [sendBurst]. In Silent nothing is handed to
  /// the node: MeshNode would queue it and flush it when a link returns.
  Future<void> send(String contactId, String text) async {
    final id = _parseId(contactId);
    if (posture.current == Posture.silent) {
      reportError('Silent: nothing is sent. Set Normal or Quiet first');
      return;
    }
    if (posture.current == Posture.quiet) {
      final held = ChatMessage(
        outgoing: true,
        text: text,
        at: _clock(),
        queued: true,
      );
      _queue.add(_Queued(id, held));
      _lastError = null;
      _append(id, held);
      return;
    }
    try {
      final packetId = await node.sendText(
        _bytesOf(id),
        Uint8List.fromList(utf8.encode(text)),
      );
      _lastError = null;
      _append(
        id,
        ChatMessage(
          outgoing: true,
          text: text,
          at: _clock(),
          packetId: packetId,
        ),
      );
    } on StateError catch (error) {
      _lastError = error.message;
      notifyListeners();
    }
  }

  /// Quiet mode's send-burst action: sends every held message in order. A message that
  /// the node refuses goes back on the queue, so nothing is dropped silently.
  Future<void> sendBurst() async {
    if (posture.current == Posture.silent) {
      reportError('Silent: nothing is sent. Set Normal or Quiet first');
      return;
    }
    final pending = List.of(_queue);
    _queue.clear();
    for (var index = 0; index < pending.length; index++) {
      final item = pending[index];
      // Silent can be chosen while an earlier send awaits: stop, keep the rest held.
      if (posture.current == Posture.silent) {
        _queue.insertAll(0, pending.sublist(index));
        _lastError = 'Silent: held messages were not sent';
        break;
      }
      try {
        final packetId = await node.sendText(
          _bytesOf(item.contactId),
          Uint8List.fromList(utf8.encode(item.message.text)),
        );
        _replace(
          item.contactId,
          item.message,
          ChatMessage(
            outgoing: true,
            text: item.message.text,
            at: item.message.at,
            packetId: packetId,
          ),
        );
      } on StateError catch (error) {
        // No link yet: keep this message and the rest, in order, for the next burst.
        _queue.insertAll(0, pending.sublist(index));
        _lastError = error.message;
        break;
      } on Object {
        // Refused for good (for example a message too long to send). Report it and
        // drop only this one, so the rest of the burst still goes out.
        _lastError = 'A held message could not be sent and was removed';
      }
    }
    notifyListeners();
  }

  /// Changes the radio posture. The radios change first, so a failed save never leaves
  /// transmission on; the new posture is then saved, and a failed save is reported.
  Future<void> setPosture(Posture next) async {
    posture.change(next);
    if (next == Posture.silent) {
      await lan.stop();
      _listenPort = null;
    } else if (provisioned) {
      try {
        _listenPort = await lan.start();
      } on StateError {
        // Silent was chosen again while the socket was binding.
        _listenPort = null;
      }
    }
    try {
      await PostureStore.save(store, next);
      _lastError = null;
    } catch (_) {
      _lastError = 'Posture changed for this session but could not be saved';
    }
    notifyListeners();
  }

  /// Deletes every stored key, stops all transports and clears memory. Returns false, with
  /// [lastError] set, when a key could not be deleted. The caller must then rebuild the
  /// controller: this node's identity is wiped and must not be used again.
  Future<bool> panicWipe() async {
    // Keys go first. A transport that fails to stop must not stop the deletes.
    var deleted = true;
    try {
      await wipeStoredSecrets(store);
    } catch (_) {
      deleted = false;
    }
    try {
      await stop();
    } catch (_) {
      // Ignored: the caller discards this controller either way.
    }
    // Message memory is cleared even when a delete failed: the wipe must not leave chat
    // plaintext in RAM just because a key could not be removed.
    _threads.clear();
    _queue.clear();
    if (!deleted) {
      _lastError =
          'Wipe incomplete: could not delete every stored key. Try again';
      notifyListeners();
      return false;
    }
    _unit = null;
    _members = const [];
    _myFingerprint = '';
    _selected = null;
    _listenPort = null;
    _lastError = null;
    posture.change(Posture.normal);
    notifyListeners();
    return true;
  }

  void _replace(String contactId, ChatMessage old, ChatMessage next) {
    final thread = _threads[contactId];
    if (thread == null) return;
    final index = thread.indexWhere((m) => identical(m, old));
    if (index >= 0) thread[index] = next;
  }

  /// Messages from senders outside the roster are dropped.
  void handleIncoming(ReceivedMessage message) {
    final id = message.senderId.hex;
    if (!contacts.contains(id)) return;
    _append(
      id,
      ChatMessage(
        outgoing: false,
        text: utf8.decode(message.plaintext, allowMalformed: true),
        at: _clock(),
      ),
    );
  }

  /// Marks the sent message with the receipt's packet ID delivered, but only in the
  /// thread of the peer that sent the receipt. Anything else is ignored.
  void handleReceipt(DeliveryReceiptEvent event) {
    final thread = _threads[event.peerId.hex];
    if (thread == null) return;
    final index = thread.indexWhere(
      (m) => m.outgoing && !m.delivered && m.packetId == event.receipt.packetId,
    );
    if (index < 0) return;
    thread[index] = thread[index].asDelivered();
    notifyListeners();
  }

  Future<bool> _guard(Future<void> Function() action) async {
    try {
      await action();
      _lastError = null;
      return true;
    } on RosterFormatException catch (e) {
      _lastError = e.message;
      return false;
    } catch (_) {
      // Platform errors may include file paths; keep the message generic.
      _lastError = 'Could not save the unit or start linking';
      return false;
    } finally {
      notifyListeners();
    }
  }

  /// Saves first, so a failed write never leaves the phone linking on an unsaved unit.
  /// [restartLan] drops links made under a previous unit.
  Future<void> _install(UnitRoster roster, {bool restartLan = false}) async {
    await UnitStore.save(store, roster);
    await _apply(roster);
    if (restartLan && _listenPort != null) {
      await lan.stop();
      _listenPort = null;
    }
    await _startLan();
  }

  Future<void> _apply(UnitRoster roster) async {
    final me = node.identity.publicKey;
    _members = List.unmodifiable([
      for (final m in roster.members)
        MemberInfo(
          name: m.name,
          peerId: (await peerIdFor(m.publicKey)).hex,
          fingerprint: await fingerprint(m.publicKey),
          isSelf: listEquals(m.publicKey, me),
        ),
    ]);
    // Seal key and roster for the wire; a member added while listening can link at once.
    await lan.configure(await UnitKeys.derive(roster.unitSecret), [
      for (final m in roster.members) m.publicKey,
    ]);
    _unit = roster;
    if (_selected != null && !contacts.contains(_selected)) _selected = null;
  }

  /// Starts listening unless Silent. Every path that starts LAN goes through here.
  Future<void> _startLan() async {
    if (posture.current == Posture.silent) return;
    _listenPort = await lan.start();
  }

  void _append(String contactId, ChatMessage message) {
    _threads.putIfAbsent(contactId, () => []).add(message);
    notifyListeners();
  }

  static String _parseId(String text) {
    final clean = text.trim().toLowerCase();
    if (clean.length != 16 || !RegExp(r'^[0-9a-f]+$').hasMatch(clean)) {
      throw const FormatException('contact ID must be 16 hex characters');
    }
    return clean;
  }

  static Uint8List _bytesOf(String idHex) {
    final out = Uint8List(idHex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(idHex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}
