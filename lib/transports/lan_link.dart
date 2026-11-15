import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/crypto/rotating_id.dart';
import '../core/mesh/transport.dart';
import '../core/protocol/sealed_envelope.dart';
import 'lan_frame.dart';
import 'sealed_link.dart';

export 'sealed_link.dart'
    show helloLength, linkNonceLength, roleAcceptor, roleDialer;

/// A link that opens no frame for this long is closed. Each side sends a keepalive
/// (a sealed empty frame) every third of it, so a quiet but healthy link stays up.
const Duration defaultLinkIdleTimeout = Duration(seconds: 30);

/// One TCP connection to a neighbouring device. The handshake, sealing, keepalive and
/// roster resolution live in [SealedLink]; this class only frames whole sealed frames
/// onto the socket with the LAN length prefix.
class LanLink implements MeshTransport {
  LanLink._(this._socket, this._sealed, this._decoder) {
    _subscription = _socket.listen(
      _onData,
      onError: (Object _) => unawaited(_sealed.close()),
      onDone: () => unawaited(_sealed.close()),
      cancelOnError: true,
    );
  }

  final Socket _socket;
  final SealedLink _sealed;
  final FrameDecoder _decoder;
  late final StreamSubscription<Uint8List> _subscription;

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
    final sealed = SealedLink.attach(
      envelope: envelope,
      resolver: resolver,
      localRotatingId: localRotatingId,
      isDialer: isDialer,
      idleTimeout: idleTimeout,
      writeSealed: (frame) async {
        socket.add(encodeFrame(frame));
        await socket.flush();
      },
      closeTransport: () async => socket.destroy(),
      onDrop: onDrop,
    );
    return LanLink._(socket, sealed, FrameDecoder());
  }

  /// True when this side dialed the connection.
  bool get isDialer => _sealed.isDialer;

  /// The sender's static PeerID, once its hello resolved to a roster member.
  Future<Uint8List> get remotePeerId => _sealed.remotePeerId;

  /// Completes once the link has closed, for any reason.
  Future<void> get closed => _sealed.closed;

  bool get isClosed => _sealed.isClosed;

  @override
  Stream<Uint8List> get incoming => _sealed.incoming;

  @override
  Future<void> send(Uint8List frame) => _sealed.send(frame);

  Future<void> close() async {
    await _subscription.cancel();
    await _sealed.close();
  }

  void _onData(Uint8List data) {
    final List<Uint8List> frames;
    try {
      frames = _decoder.add(data);
    } on FormatException {
      unawaited(_sealed.close());
      return;
    }
    for (final frame in frames) {
      _sealed.onSealedFrame(frame);
    }
  }
}
