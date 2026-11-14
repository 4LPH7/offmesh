import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../core/crypto/rotating_id.dart';
import '../core/mesh/transport.dart';
import '../core/protocol/sealed_envelope.dart';
import 'lan_frame.dart';

/// Random challenge each side sends as its first frame.
const int linkNonceLength = 16;

/// Hello plaintext: rotating ID (8) || the peer's challenge (16) || role (1).
const int helloLength = rotatingIdLength + linkNonceLength + 1;

/// Role byte in the hello: the side that dialed, or the side that accepted.
const int roleDialer = 1;
const int roleAcceptor = 0;

/// A link that opens no frame for this long is closed. Each side sends a keepalive
/// (a sealed empty frame) every third of it, so a quiet but healthy link stays up.
const Duration defaultLinkIdleTimeout = Duration(seconds: 30);

/// Idle ticks per [LanLink] idle timeout: one keepalive per tick, close after this many
/// ticks without an opened frame.
const int _idleTicks = 3;

final Random _random = Random.secure();

/// One TCP connection to a neighbouring device. Every frame on the socket is sealed with
/// the unit seal key. The handshake binds the hello to this connection:
///
/// 1. Each side sends a random 16-byte challenge.
/// 2. Once the peer's challenge arrives, each side sends its hello: its rotating ID, the
///    peer's challenge and its role (dialer or acceptor).
/// 3. Each side checks that its own challenge and the opposite role came back, then
///    resolves the rotating ID through the roster to the sender's static PeerID.
///
/// A hello relayed from another connection carries the wrong challenge or role, so a
/// party without the unit key cannot link by forwarding a member's frames.
class LanLink implements MeshTransport {
  LanLink._(
    this._socket,
    this._envelope,
    this._resolver,
    this._localRotatingId,
    this.isDialer,
    Duration idleTimeout,
    this._onDrop,
  ) {
    _subscription = _socket.listen(
      _onData,
      onError: (Object _) => close(),
      onDone: close,
      cancelOnError: true,
    );
    _ticker = Timer.periodic(idleTimeout ~/ _idleTicks, (_) => _tick());
  }

  final Socket _socket;
  final SealedEnvelope _envelope;
  final RosterResolver _resolver;
  final Uint8List _localRotatingId;

  /// True when this side dialed the connection.
  final bool isDialer;
  final void Function() _onDrop;
  final FrameDecoder _decoder = FrameDecoder();
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  final Completer<Uint8List> _remotePeerId = Completer<Uint8List>();
  final Completer<void> _closed = Completer<void>();
  final Uint8List _localNonce = Uint8List.fromList(
    List<int>.generate(linkNonceLength, (_) => _random.nextInt(256)),
  );
  late final StreamSubscription<Uint8List> _subscription;
  late final Timer _ticker;
  // Sealing and opening are async; these chains keep frames in order in each direction.
  Future<void> _writes = Future<void>.value();
  Future<void> _reads = Future<void>.value();
  Uint8List? _peerNonce;
  int _silentTicks = 0;
  bool _isClosed = false;

  /// Starts the link: sends the sealed challenge and begins reading. The hello carrying
  /// [localRotatingId] follows once the peer's challenge arrives. [onDrop] is called for
  /// each frame after the handshake that fails to open.
  static LanLink attach(
    Socket socket, {
    required SealedEnvelope envelope,
    required RosterResolver resolver,
    required Uint8List localRotatingId,
    required bool isDialer,
    Duration idleTimeout = defaultLinkIdleTimeout,
    void Function()? onDrop,
  }) {
    if (localRotatingId.length != rotatingIdLength) {
      throw ArgumentError('rotating ID must be $rotatingIdLength bytes');
    }
    final link = LanLink._(
      socket,
      envelope,
      resolver,
      Uint8List.fromList(localRotatingId),
      isDialer,
      idleTimeout,
      onDrop ?? () {},
    );
    unawaited(link._write(link._localNonce));
    return link;
  }

  /// The sender's static PeerID, once its hello resolved to a roster member.
  Future<Uint8List> get remotePeerId => _remotePeerId.future;

  /// Completes once the link has closed, for any reason.
  Future<void> get closed => _closed.future;

  bool get isClosed => _isClosed;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> send(Uint8List frame) => _write(frame);

  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    _ticker.cancel();
    if (!_remotePeerId.isCompleted) {
      _remotePeerId.completeError(const SocketException('closed before hello'));
    }
    await _subscription.cancel();
    _socket.destroy();
    // Not awaited: the future only completes once someone listens, and a rejected link never has a listener.
    unawaited(_incoming.close());
    if (!_closed.isCompleted) _closed.complete();
  }

  void _tick() {
    if (++_silentTicks >= _idleTicks) {
      unawaited(close());
      return;
    }
    if (_remotePeerId.isCompleted) unawaited(_write(Uint8List(0)));
  }

  Uint8List _hello(Uint8List peerNonce) => Uint8List(helloLength)
    ..setRange(0, rotatingIdLength, _localRotatingId)
    ..setRange(rotatingIdLength, rotatingIdLength + linkNonceLength, peerNonce)
    ..[helloLength - 1] = isDialer ? roleDialer : roleAcceptor;

  bool _isBoundHello(Uint8List hello) {
    if (hello.length != helloLength) return false;
    for (var i = 0; i < linkNonceLength; i++) {
      if (hello[rotatingIdLength + i] != _localNonce[i]) return false;
    }
    return hello[helloLength - 1] == (isDialer ? roleAcceptor : roleDialer);
  }

  Future<void> _write(Uint8List plaintext) => _writes = _writes.then((_) async {
    if (_isClosed) return;
    try {
      final sealed = await _envelope.seal(plaintext);
      if (_isClosed) return;
      _socket.add(encodeFrame(sealed));
      await _socket.flush();
    } catch (_) {
      // Socket errors and oversize frames both end the link.
      await close();
    }
  });

  void _onData(Uint8List data) {
    final List<Uint8List> frames;
    try {
      frames = _decoder.add(data);
    } on FormatException {
      unawaited(close());
      return;
    }
    for (final frame in frames) {
      _reads = _reads
          .then((_) => _onFrame(frame))
          .catchError((Object _) => close());
    }
  }

  Future<void> _onFrame(Uint8List frame) async {
    if (_isClosed) return;
    final Uint8List plaintext;
    try {
      plaintext = await _envelope.open(frame);
    } on SealedEnvelopeException {
      if (_remotePeerId.isCompleted) {
        _onDrop();
      } else {
        await close();
      }
      return;
    }
    if (_isClosed) return;
    _silentTicks = 0;
    if (_remotePeerId.isCompleted) {
      // An empty frame is a keepalive; mesh packets always carry a header.
      if (plaintext.isNotEmpty) _incoming.add(plaintext);
      return;
    }
    if (_peerNonce == null) {
      if (plaintext.length != linkNonceLength) {
        await close();
        return;
      }
      _peerNonce = plaintext;
      unawaited(_write(_hello(plaintext)));
      return;
    }
    if (!_isBoundHello(plaintext)) {
      await close();
      return;
    }
    final member = await _resolver.resolve(
      Uint8List.sublistView(plaintext, 0, rotatingIdLength),
    );
    if (_isClosed) return;
    if (member == null) {
      await close();
      return;
    }
    _remotePeerId.complete(Uint8List.fromList(member.peerId));
  }
}
