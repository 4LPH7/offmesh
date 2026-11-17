import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/mesh/transport.dart';
import '../core/protocol/sealed_envelope.dart';
import '../core/relay/rendezvous.dart';
import '../relay/relay_server.dart';
import 'lan_frame.dart';

enum RelayState { stopped, connecting, connected, retrying }

/// Reaches other unit members through a relay (internet mode).
///
/// One TCP connection to the relay, one room per UTC day. Every frame is sealed under the
/// unit key before it leaves, so the relay carries ciphertext only; frames that fail to
/// open (another unit's, tampered, stale) are dropped and counted. The mesh above this
/// treats the relay like one more link: Noise sessions, roster checks and receipts work
/// unchanged. Reconnects with backoff, and rejoins the new room after midnight UTC.
class RelayTransport implements MeshTransport {
  RelayTransport({
    required this.host,
    required this.port,
    required SealedEnvelope envelope,
    required List<int> unitSecret,
    DateTime Function()? clock,
    this.keepalive = const Duration(seconds: 30),
    this.connectTimeout = const Duration(seconds: 5),
    this.minBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 30),
    void Function(RelayState state)? onState,
  }) : _envelope = envelope,
       _secret = List<int>.unmodifiable(unitSecret),
       _clock = clock ?? DateTime.now,
       _onState = onState;

  final String host;
  final int port;
  final Duration keepalive;
  final Duration connectTimeout;
  final Duration minBackoff;
  final Duration maxBackoff;
  final SealedEnvelope _envelope;
  final List<int> _secret;
  final DateTime Function() _clock;
  final void Function(RelayState state)? _onState;

  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  RelayState _state = RelayState.stopped;
  Socket? _socket;
  Timer? _retry;
  Timer? _ticker;
  int _generation = 0;
  int _day = 0;
  Duration _backoff = Duration.zero;
  Future<void> _reads = Future<void>.value();

  int framesDropped = 0;

  RelayState get state => _state;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  /// Starts connecting. Safe to call again after [stop].
  void start() {
    if (_state != RelayState.stopped) return;
    _backoff = minBackoff;
    unawaited(_connect(++_generation));
    _ticker = Timer.periodic(keepalive, (_) => _tick());
  }

  Future<void> stop() async {
    _generation++;
    _ticker?.cancel();
    _ticker = null;
    _retry?.cancel();
    _retry = null;
    _closeSocket();
    _set(RelayState.stopped);
  }

  /// Seals and sends [frame] to the room. Silently does nothing while not connected:
  /// the mesh above resends through its other links or the next handshake.
  @override
  Future<void> send(Uint8List frame) async {
    final socket = _socket;
    if (socket == null || _state != RelayState.connected) return;
    final sealed = await _envelope.seal(frame);
    if (!identical(socket, _socket)) return;
    socket.add(encodeFrame(sealed));
  }

  Future<void> _connect(int generation) async {
    _set(RelayState.connecting);
    final Socket socket;
    final Uint8List room;
    try {
      _day = epochDay(_clock());
      room = await rendezvousId(_secret, _day);
      socket = await Socket.connect(host, port, timeout: connectTimeout);
    } on Object {
      _scheduleRetry(generation);
      return;
    }
    if (generation != _generation) {
      socket.destroy();
      return;
    }
    socket.setOption(SocketOption.tcpNoDelay, true);
    _socket = socket;
    socket.add(encodeFrame(Uint8List.fromList([...relayMagic, ...room])));
    final decoder = FrameDecoder();
    socket.listen(
      (chunk) {
        if (generation != _generation) return;
        try {
          for (final frame in decoder.add(chunk)) {
            _reads = _reads.then((_) => _open(generation, frame));
          }
        } on FormatException {
          socket.destroy();
        }
      },
      onError: (Object _) => _lost(generation),
      onDone: () => _lost(generation),
      cancelOnError: true,
    );
    _backoff = minBackoff;
    _set(RelayState.connected);
  }

  Future<void> _open(int generation, Uint8List sealed) async {
    if (sealed.isEmpty || generation != _generation) return;
    try {
      final frame = await _envelope.open(sealed);
      if (generation == _generation && !_incoming.isClosed) {
        _incoming.add(frame);
      }
    } on SealedEnvelopeException {
      framesDropped++;
    }
  }

  void _lost(int generation) {
    if (generation != _generation) return;
    _closeSocket();
    _scheduleRetry(generation);
  }

  void _scheduleRetry(int generation) {
    if (generation != _generation) return;
    _set(RelayState.retrying);
    _retry?.cancel();
    final wait = _backoff;
    _backoff = Duration(
      milliseconds: (wait.inMilliseconds * 2).clamp(
        minBackoff.inMilliseconds,
        maxBackoff.inMilliseconds,
      ),
    );
    _retry = Timer(wait, () {
      if (generation == _generation) unawaited(_connect(generation));
    });
  }

  void _tick() {
    final socket = _socket;
    if (socket == null || _state != RelayState.connected) return;
    if (epochDay(_clock()) != _day) {
      // New UTC day, new room: leave the old one and join the new.
      _closeSocket();
      unawaited(_connect(++_generation));
      return;
    }
    socket.add(encodeFrame(Uint8List(0)));
  }

  void _closeSocket() {
    _socket?.destroy();
    _socket = null;
  }

  void _set(RelayState next) {
    if (_state == next) return;
    _state = next;
    _onState?.call(next);
  }
}
