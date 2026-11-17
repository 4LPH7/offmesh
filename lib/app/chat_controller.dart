import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/channel/channel_crypto.dart';
import '../core/crypto/identity.dart';
import '../core/crypto/unit_keys.dart';
import '../core/mesh/mesh_node.dart';
import '../core/posture.dart';
import '../core/protocol/packet.dart';
import '../core/protocol/sealed_envelope.dart';
import '../core/provisioning/unit_roster.dart';
import '../transports/lan_manager.dart';
import '../transports/relay_transport.dart';
import '../core/voice/tones.dart';
import '../core/voice/voice_burst.dart';
import 'channel_store.dart';
import 'history_store.dart';
import 'internet_store.dart';
import 'voice_audio.dart';
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
    this.from,
  });

  /// Sender name on a channel message from someone else; null in 1:1 threads.
  final String? from;

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
    this.capture,
    this.playback,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Microphone and speaker for push-to-talk; null where voice is not available.
  final VoiceCapture? capture;
  final VoicePlayback? playback;
  VoiceBurstSender? _talkSender;
  final Map<String, VoiceBurstReceiver> _receivers = {};
  final Map<String, String> _speakers = {};
  final Map<String, DateTime> _lastHeard = {};

  // Internet mode: off at every launch, on only when the user switches it on.
  RelayTransport? _relay;
  RelayAddress? _relayAddress;
  bool _internetAcked = false;
  RelayState _internetState = RelayState.stopped;

  /// The relay as 'host:port', or null until one is set.
  String? get relayAddress => _relayAddress?.toString();

  /// True while internet mode is switched on (it may still be connecting).
  bool get internetOn => _relay != null;

  RelayState get internetState => _internetState;

  /// False until the user has read the internet-mode warning once.
  bool get internetAcked => _internetAcked;

  /// Saves the relay address. A running connection moves to the new relay.
  Future<bool> setRelayAddress(String text) async {
    final RelayAddress address;
    try {
      address = RelayAddress.parse(text);
    } on FormatException catch (e) {
      _lastError = e.message;
      notifyListeners();
      return false;
    }
    try {
      await InternetStore.saveAddress(store, address);
    } catch (_) {
      _lastError = 'Could not save the relay address';
      notifyListeners();
      return false;
    }
    _relayAddress = address;
    _lastError = null;
    if (internetOn) await _startInternet();
    notifyListeners();
    return true;
  }

  /// Records that the warning was read, so it is not shown again.
  Future<void> acknowledgeInternet() async {
    _internetAcked = true;
    try {
      await InternetStore.saveAck(store);
    } catch (_) {
      // Shown again next launch; nothing else depends on it.
    }
    notifyListeners();
  }

  /// Switches internet mode on or off. On needs a unit, a relay address and the Normal
  /// posture: Silent and Quiet keep every link that leaves the local network closed.
  Future<void> setInternet(bool on) async {
    if (!on) {
      await _stopInternet();
      _lastError = null;
      notifyListeners();
      return;
    }
    if (_unit == null) {
      return reportError('Join a unit first');
    }
    if (_relayAddress == null) {
      return reportError('Set a relay address first');
    }
    if (posture.current != Posture.normal) {
      return reportError('Set the posture to Normal to use the internet');
    }
    await _startInternet();
    _lastError = null;
    notifyListeners();
  }

  /// (Re)connects to the relay with the current unit and address.
  Future<void> _startInternet() async {
    final unit = _unit;
    final address = _relayAddress;
    await _stopInternet();
    if (unit == null || address == null) return;
    final keys = await UnitKeys.derive(unit.unitSecret);
    final relay = RelayTransport(
      host: address.host,
      port: address.port,
      envelope: SealedEnvelope(keys.sealKey),
      unitSecret: unit.unitSecret,
      onState: (state) {
        _internetState = state;
        notifyListeners();
      },
    );
    _relay = relay;
    node.addTransport(relay);
    relay.start();
  }

  Future<void> _stopInternet() async {
    final relay = _relay;
    if (relay == null) return;
    _relay = null;
    await node.removeTransport(relay);
    await relay.stop();
    _internetState = RelayState.stopped;
  }

  Timer? _voiceTicker;

  final MeshNode node;
  final LanManager lan;
  final SecretStore store;
  final DateTime Function() _clock;

  final Map<String, List<ChatMessage>> _threads = {};

  /// Threads are written shortly after they change, so a burst of messages is one write.
  Timer? _historyTimer;
  bool _wiped = false;
  static const _historyDelay = Duration(milliseconds: 500);

  void _scheduleHistorySave() {
    if (_wiped || _unit == null) return;
    _historyTimer?.cancel();
    _historyTimer = Timer(_historyDelay, () => unawaited(_saveHistory()));
  }

  Future<void> _saveHistory() async {
    if (_wiped || _unit == null) return;
    try {
      await HistoryStore.save(store, _threads);
    } catch (_) {
      // Kept in memory; the next change tries again.
    }
  }

  UnitRoster? _unit;
  List<MemberInfo> _members = const [];
  String _myFingerprint = '';
  String? _selected;
  String? _lastError;
  int? _listenPort;
  StreamSubscription<ReceivedMessage>? _subscription;
  StreamSubscription<DeliveryReceiptEvent>? _receiptSubscription;
  StreamSubscription<ChannelMessage>? _channelSubscription;
  final List<_Queued> _queue = [];

  /// Joined channels by normalized name. Keys follow the unit secret, so they are
  /// re-derived whenever the unit changes.
  final Map<String, ChannelKey> _channelKeys = {};
  List<String> _channelNames = const [];

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

  /// Joined channels as conversation IDs: '#' plus the channel name.
  List<String> get channels => [for (final name in _channelNames) '#$name'];

  /// Everything the conversation picker shows: channels first, then members.
  List<String> get conversations => [...channels, ...contacts];

  static bool isChannel(String conversationId) =>
      conversationId.startsWith('#');

  String nameOf(String peerId) => isChannel(peerId)
      ? peerId
      : _members
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
    _channelSubscription = node.channelMessages.listen(handleChannelMessage);
    // Releases a speaker whose end frame was lost.
    _voiceTicker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      for (final receiver in _receivers.values) {
        receiver.tick();
      }
    });
    node.start();
    _myFingerprint = await fingerprint(node.identity.publicKey);
    // Before any LAN start: a Silent phone must not bind a socket on launch.
    posture.change(await PostureStore.load(store));
    _relayAddress = await InternetStore.loadAddress(store);
    _internetAcked = await InternetStore.loadAck(store);
    try {
      final unit = await UnitStore.load(store);
      if (unit != null) {
        await _apply(unit);
        _threads.addAll(await HistoryStore.load(store));
        await _startLan();
      }
    } on UnitStoreException catch (e) {
      _lastError = '${e.message}. Join the unit again.';
    }
    notifyListeners();
  }

  Future<void> stop() async {
    if (_historyTimer?.isActive ?? false) {
      _historyTimer!.cancel();
      await _saveHistory();
    }
    await _stopInternet();
    await stopTalking();
    _voiceTicker?.cancel();
    _voiceTicker = null;
    await _subscription?.cancel();
    await _receiptSubscription?.cancel();
    await _channelSubscription?.cancel();
    await lan.stop();
    _listenPort = null;
    await node.stop();
  }

  /// Joins channel [name] and opens its thread. Every unit member who joins the same
  /// name (case and surrounding spaces ignored) shares the channel.
  Future<bool> joinChannel(String name) => _guard(() async {
    final unit = _unit;
    if (unit == null) throw const _UserError('Join a unit first');
    final clean = _channelName(name);
    if (!_channelKeys.containsKey(clean)) {
      if (_channelNames.length >= maxJoinedChannels) {
        throw const _UserError('Leave a channel before joining another');
      }
      final names = [..._channelNames, clean];
      await ChannelStore.save(store, names);
      final key = await ChannelKey.derive(unit.unitSecret, clean);
      node.joinChannel(key);
      _channelKeys[clean] = key;
      _channelNames = List.unmodifiable(names);
    }
    _selected = '#$clean';
  });

  /// Leaves a channel by its conversation ID ('#name') and forgets its thread.
  Future<bool> leaveChannel(String conversationId) => _guard(() async {
    final clean = conversationId.substring(1);
    final key = _channelKeys[clean];
    if (key == null) return;
    final names = [
      for (final n in _channelNames)
        if (n != clean) n,
    ];
    await ChannelStore.save(store, names);
    node.leaveChannel(key);
    _channelKeys.remove(clean);
    _channelNames = List.unmodifiable(names);
    _threads.remove(conversationId);
    _scheduleHistorySave();
    if (_selected == conversationId) _selected = null;
  });

  static String _channelName(String name) {
    try {
      return normalizeChannelName(name);
    } on ChannelFormatException catch (e) {
      throw _UserError(e.message);
    }
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
    final id = isChannel(contactId) ? contactId : _parseId(contactId);
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
      final packetId = await _dispatch(
        id,
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
        final packetId = await _dispatch(
          item.contactId,
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
    if (next != Posture.normal) {
      await stopTalking();
      await _stopInternet();
    }
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
    // No history write may follow the wipe.
    _wiped = true;
    _historyTimer?.cancel();
    _talkSender = null;
    unawaited(capture?.stop());
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
    _lastHeard.clear();
    _relayAddress = null;
    _internetAcked = false;
    _channelKeys.clear();
    _channelNames = const [];
    _queue.clear();
    if (!deleted) {
      // The radios are already off on purpose: nothing arrives until the app restarts.
      _lastError =
          'Wipe incomplete: a stored key could not be deleted. Radios are off; '
          'retry the wipe, or restart the app to listen again';
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
    _scheduleHistorySave();
  }

  /// Messages from senders outside the roster are dropped.
  void handleIncoming(ReceivedMessage message) {
    final id = message.senderId.hex;
    if (!contacts.contains(id)) return;
    _heard(id);
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
  /// Channel messages from senders outside the roster, or on channels this phone left,
  /// are dropped.
  void handleChannelMessage(ChannelMessage message) {
    final tag = message.channelTag.hex;
    final entry = _channelKeys.entries
        .where((e) => e.value.tagHex == tag)
        .firstOrNull;
    final sender = message.senderId.hex;
    if (entry == null || !contacts.contains(sender)) return;
    _heard(sender);
    final body = message.text;
    if (body.isEmpty) return;
    final channelId = '#${entry.key}';
    switch (body[0]) {
      case _kindText:
        _append(
          channelId,
          ChatMessage(
            outgoing: false,
            text: utf8.decode(body.sublist(1), allowMalformed: true),
            at: _clock(),
            from: nameOf(sender),
          ),
        );
      case _kindVoice:
        _receiverFor(channelId).accept(sender, Uint8List.sublistView(body, 1));
    }
  }

  // Inner message kinds on a channel: the first plaintext byte.
  static const int _kindText = 0x00;
  static const int _kindVoice = 0x01;

  VoiceBurstReceiver _receiverFor(String channelId) => _receivers.putIfAbsent(
    channelId,
    () => VoiceBurstReceiver(
      clock: _clock,
      onPcm: (pcm) => playback?.push(pcm),
      onSpeaker: (speaker) {
        if (speaker == null) {
          _speakers.remove(channelId);
          // Roger beep: the burst is over and the channel is free.
          playback?.push(rogerBeep());
          unawaited(playback?.end());
        } else {
          _speakers[channelId] = nameOf(speaker);
          unawaited(playback?.begin());
        }
        notifyListeners();
      },
    ),
  );

  /// When this phone last received anything from member [peerId] (PeerID hex): a 1:1
  /// message or any channel text or voice frame. Null if never in this session.
  DateTime? lastHeard(String peerId) => _lastHeard[peerId];

  void _heard(String peerId) => _lastHeard[peerId] = _clock();

  /// Who is talking on [channelId] right now, by name; null when nobody is.
  String? speakerOn(String channelId) => _speakers[channelId];

  /// True while this phone holds the talk button and is sending.
  bool get talking => _talkSender?.active ?? false;

  /// Push-to-talk needs a microphone and speaker on this platform.
  bool get voiceAvailable => capture != null && playback != null;

  /// Starts a voice burst on the selected channel. Silent and Quiet refuse it, and a
  /// burst stops itself after 30 seconds.
  Future<void> startTalking() async {
    final channelId = _selected;
    final input = capture;
    if (channelId == null || !isChannel(channelId)) {
      return reportError('Choose a channel to talk on');
    }
    if (input == null) return reportError('Voice is not available here');
    if (posture.current == Posture.silent) {
      return reportError('Silent: talk is off');
    }
    if (posture.current == Posture.quiet) {
      return reportError('Quiet: voice is off; text is held until you send');
    }
    final key = _channelKeys[channelId.substring(1)];
    if (key == null || talking) return;
    if (_speakers[channelId] != null) {
      return reportError('${_speakers[channelId]} is talking');
    }
    final sender = VoiceBurstSender(
      send: (frame) => node
          .sendChannel(key, Uint8List.fromList([_kindVoice, ...frame]))
          .then((_) {}),
      onCapped: () {
        unawaited(input.stop());
        reportError('Burst limit reached (30 s)');
      },
    )..start();
    _talkSender = sender;
    if (!await input.start((pcm) => unawaited(sender.addPcm(pcm)))) {
      _talkSender = null;
      return reportError('Microphone permission is needed to talk');
    }
    _lastError = null;
    notifyListeners();
  }

  /// Ends the burst; the remaining audio goes out as the end frame.
  Future<void> stopTalking() async {
    final sender = _talkSender;
    if (sender == null) return;
    _talkSender = null;
    await capture?.stop();
    await sender.stop();
    notifyListeners();
  }

  /// Sends to a member (PeerID hex) or a channel ('#name').
  Future<int> _dispatch(String conversationId, Uint8List bytes) {
    if (!isChannel(conversationId)) {
      return node.sendText(_bytesOf(conversationId), bytes);
    }
    final key = _channelKeys[conversationId.substring(1)];
    if (key == null) throw StateError('Join $conversationId before sending');
    return node.sendChannel(key, Uint8List.fromList([_kindText, ...bytes]));
  }

  /// Channel keys depend on the unit secret: derive them again for the current unit.
  Future<void> _rejoinChannels(List<int> unitSecret) async {
    for (final key in _channelKeys.values) {
      node.leaveChannel(key);
    }
    _channelKeys.clear();
    final names = await ChannelStore.load(store);
    for (final name in names) {
      final key = await ChannelKey.derive(unitSecret, name);
      node.joinChannel(key);
      _channelKeys[key.name] = key;
    }
    _channelNames = List.unmodifiable(_channelKeys.keys);
  }

  void handleReceipt(DeliveryReceiptEvent event) {
    final thread = _threads[event.peerId.hex];
    if (thread == null) return;
    final index = thread.indexWhere(
      (m) => m.outgoing && !m.delivered && m.packetId == event.receipt.packetId,
    );
    if (index < 0) return;
    thread[index] = thread[index].asDelivered();
    _scheduleHistorySave();
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
    } on _UserError catch (e) {
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
    await _rejoinChannels(roster.unitSecret);
    // A new unit means a new seal key and rendezvous room: reconnect if online.
    if (internetOn) await _startInternet();
    if (_selected != null && !conversations.contains(_selected)) {
      _selected = null;
    }
  }

  /// Starts listening unless Silent. Every path that starts LAN goes through here.
  Future<void> _startLan() async {
    if (posture.current == Posture.silent) return;
    _listenPort = await lan.start();
  }

  void _append(String contactId, ChatMessage message) {
    _threads.putIfAbsent(contactId, () => []).add(message);
    _scheduleHistorySave();
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

/// A refusal to show the user as is (no platform detail inside).
class _UserError implements Exception {
  const _UserError(this.message);

  final String message;
}
