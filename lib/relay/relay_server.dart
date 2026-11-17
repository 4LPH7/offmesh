import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import '../transports/lan_frame.dart';

/// First frame of every client connection: these ASCII bytes, then the rendezvous ID.
const List<int> relayMagic = [0x4F, 0x46, 0x4D, 0x52, 0x31]; // "OFMR1"
const int rendezvousLength = 16;
const int relayJoinLength = 5 + rendezvousLength;

/// Limits that bound what an anonymous client can make the relay hold.
const int maxRelayRoomMembers = 16;
const int maxRelayRooms = 256;
const int maxRelayConnections = 1024;
const Duration relayJoinTimeout = Duration(seconds: 5);
const Duration relayIdleTimeout = Duration(seconds: 90);
const int relayFramesPerSecond = 200;

/// Frames queued for one slow receiver before the relay starts dropping for it.
const int maxPendingRelayFrames = 256;

class _Member {
  _Member(this.socket, DateTime now) : lastSeen = now;

  final Socket socket;
  final FrameDecoder decoder = FrameDecoder();
  Timer? joinTimer;
  String? room;
  DateTime lastSeen;
  final Queue<Uint8List> outbox = Queue<Uint8List>();
  bool writing = false;
  double tokens = relayFramesPerSecond.toDouble();
  DateTime refilled = DateTime.fromMillisecondsSinceEpoch(0);
  bool closed = false;
}

/// A rendezvous relay for internet mode.
///
/// Clients that present the same 16-byte rendezvous ID share a room, and every frame a
/// client sends goes to the other members of its room. Frames are sealed by the clients;
/// the relay never opens them, stores nothing, and has no accounts. What it can see: each
/// client's IP address, when it is online, how big and how often its frames are, and the
/// rendezvous ID (derived from the unit secret and the date, so it changes daily).
class RelayServer {
  RelayServer({
    this.address,
    this.port = 0,
    DateTime Function()? clock,
    void Function(String event)? onLog,
  }) : _clock = clock ?? DateTime.now,
       _onLog = onLog;

  final InternetAddress? address;
  final int port;
  final DateTime Function() _clock;
  final void Function(String event)? _onLog;

  ServerSocket? _server;
  Timer? _sweeper;
  final Map<String, Set<_Member>> _rooms = {};
  final Set<_Member> _all = {};

  int framesForwarded = 0;
  int framesDropped = 0;
  int connectionsRefused = 0;

  int get connectionCount => _all.length;

  int get roomCount => _rooms.length;

  Future<int> start() async {
    final server = await ServerSocket.bind(
      address ?? InternetAddress.anyIPv4,
      port,
    );
    _server = server;
    server.listen(_accept);
    _sweeper = Timer.periodic(const Duration(seconds: 10), (_) => _sweep());
    return server.port;
  }

  Future<void> stop() async {
    _sweeper?.cancel();
    _sweeper = null;
    await _server?.close();
    _server = null;
    for (final member in List.of(_all)) {
      _drop(member);
    }
  }

  void _accept(Socket socket) {
    if (_all.length >= maxRelayConnections) {
      connectionsRefused++;
      socket.destroy();
      return;
    }
    final member = _Member(socket, _clock());
    _all.add(member);
    member.joinTimer = Timer(relayJoinTimeout, () => _drop(member));
    socket.listen(
      (chunk) => _onData(member, chunk),
      onError: (Object _) => _drop(member),
      onDone: () => _drop(member),
      cancelOnError: true,
    );
  }

  void _onData(_Member member, List<int> chunk) {
    if (member.closed) return;
    final List<Uint8List> frames;
    try {
      frames = member.decoder.add(chunk);
    } on FormatException {
      _drop(member);
      return;
    }
    for (final frame in frames) {
      member.lastSeen = _clock();
      if (member.room == null) {
        if (!_join(member, frame)) return;
        continue;
      }
      if (frame.isEmpty) continue; // keepalive
      _forward(member, frame);
      if (member.closed) return;
    }
  }

  bool _join(_Member member, Uint8List frame) {
    if (frame.length != relayJoinLength) {
      _drop(member);
      return false;
    }
    for (var i = 0; i < relayMagic.length; i++) {
      if (frame[i] != relayMagic[i]) {
        _drop(member);
        return false;
      }
    }
    final room = _hex(frame.sublist(relayMagic.length));
    final members = _rooms[room];
    if (members == null && _rooms.length >= maxRelayRooms) {
      connectionsRefused++;
      _drop(member);
      return false;
    }
    if (members != null && members.length >= maxRelayRoomMembers) {
      connectionsRefused++;
      _drop(member);
      return false;
    }
    member.joinTimer?.cancel();
    member.joinTimer = null;
    member.room = room;
    _rooms.putIfAbsent(room, () => {}).add(member);
    return true;
  }

  void _forward(_Member from, Uint8List frame) {
    if (!_allow(from)) {
      framesDropped++;
      return;
    }
    final wire = encodeFrame(frame);
    for (final to in List.of(_rooms[from.room] ?? const <_Member>{})) {
      if (identical(to, from) || to.closed) continue;
      if (to.outbox.length >= maxPendingRelayFrames) {
        framesDropped++;
        continue;
      }
      to.outbox.add(wire);
      framesForwarded++;
      if (!to.writing) unawaited(_pump(to));
    }
  }

  /// Writes a receiver's queue one frame at a time. A socket allows only one pending
  /// flush, so overlapping writes would throw and drop a healthy receiver.
  Future<void> _pump(_Member to) async {
    to.writing = true;
    try {
      while (to.outbox.isNotEmpty && !to.closed) {
        to.socket.add(to.outbox.removeFirst());
        await to.socket.flush();
      }
    } on Object {
      _drop(to);
    } finally {
      to.writing = false;
    }
  }

  /// Token bucket: [relayFramesPerSecond] frames a second, with a one-second burst.
  bool _allow(_Member member) {
    final now = _clock();
    final elapsed = member.refilled.millisecondsSinceEpoch == 0
        ? 0.0
        : now.difference(member.refilled).inMilliseconds / 1000;
    member.refilled = now;
    member.tokens = (member.tokens + elapsed * relayFramesPerSecond).clamp(
      0,
      relayFramesPerSecond.toDouble(),
    );
    if (member.tokens < 1) return false;
    member.tokens -= 1;
    return true;
  }

  void _sweep() {
    final now = _clock();
    for (final member in List.of(_all)) {
      if (now.difference(member.lastSeen) > relayIdleTimeout) _drop(member);
    }
  }

  void _drop(_Member member) {
    if (member.closed) return;
    member.closed = true;
    member.joinTimer?.cancel();
    _all.remove(member);
    final room = member.room;
    if (room != null) {
      final members = _rooms[room];
      members?.remove(member);
      if (members != null && members.isEmpty) _rooms.remove(room);
    }
    member.socket.destroy();
    _onLog?.call('closed');
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
