import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/mesh/mesh_node.dart';
import '../core/protocol/packet.dart';
import '../transports/lan_manager.dart';

class ChatMessage {
  const ChatMessage({required this.outgoing, required this.text, required this.at});

  final bool outgoing;
  final String text;
  final DateTime at;
}

/// App state: contacts, one thread per contact, and the node that carries the messages.
class ChatController extends ChangeNotifier {
  ChatController({required this.node, required this.lan, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final MeshNode node;
  final LanManager lan;
  final DateTime Function() _clock;

  final Map<String, List<ChatMessage>> _threads = {};
  final List<String> _contacts = [];
  String? _selected;
  String? _lastError;
  int? _listenPort;
  StreamSubscription<ReceivedMessage>? _subscription;

  String get myId => node.peerId.hex;

  int? get listenPort => _listenPort;

  List<String> get contacts => List.unmodifiable(_contacts);

  String? get selectedContact => _selected;

  String? get lastError => _lastError;

  Set<String> get linkedNeighbours => lan.linkedPeerIds;

  List<ChatMessage> thread(String contactId) => List.unmodifiable(_threads[contactId] ?? const []);

  Future<void> start() async {
    _subscription = node.messages.listen(handleIncoming);
    node.start();
    _listenPort = await lan.start();
    notifyListeners();
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    await lan.stop();
    await node.stop();
  }

  /// Dials a neighbour by IP address. Failures are reported through [lastError].
  Future<void> connect(String host, int port) async {
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

  /// Adds a contact by the 16-hex-character ID they show on their screen.
  void addContact(String idHex) {
    final id = _parseId(idHex);
    _remember(id);
    _selected = id;
    notifyListeners();
  }

  void select(String contactId) {
    _remember(contactId);
    _selected = contactId;
    notifyListeners();
  }

  Future<void> send(String contactId, String text) async {
    final id = _parseId(contactId);
    try {
      await node.sendText(_bytesOf(id), Uint8List.fromList(utf8.encode(text)));
      _lastError = null;
      _append(id, ChatMessage(outgoing: true, text: text, at: _clock()));
    } on StateError catch (error) {
      _lastError = error.message;
      notifyListeners();
    }
  }

  void handleIncoming(ReceivedMessage message) {
    final id = message.senderId.hex;
    _append(
      id,
      ChatMessage(
        outgoing: false,
        text: utf8.decode(message.plaintext, allowMalformed: true),
        at: _clock(),
      ),
    );
  }

  void _append(String contactId, ChatMessage message) {
    _remember(contactId);
    _threads.putIfAbsent(contactId, () => []).add(message);
    notifyListeners();
  }

  void _remember(String contactId) {
    if (!_contacts.contains(contactId)) _contacts.add(contactId);
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
