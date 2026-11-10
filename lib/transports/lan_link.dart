import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/crypto/identity.dart';
import '../core/mesh/transport.dart';
import 'lan_frame.dart';

/// One TCP connection to a neighbouring device. The first frame each side sends is its
/// 8-byte PeerID, so both ends know who they are talking to before any mesh traffic flows.
class LanLink implements MeshTransport {
  LanLink._(this._socket) {
    _subscription = _socket.listen(
      _onData,
      onError: (Object _) => close(),
      onDone: close,
      cancelOnError: true,
    );
  }

  final Socket _socket;
  final FrameDecoder _decoder = FrameDecoder();
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  final Completer<Uint8List> _remotePeerId = Completer<Uint8List>();
  final Completer<void> _closed = Completer<void>();
  late final StreamSubscription<Uint8List> _subscription;
  bool _isClosed = false;

  /// Starts the link: sends our PeerID and begins reading. Call [remotePeerId] to learn theirs.
  static LanLink attach(Socket socket, {required Uint8List localPeerId}) {
    final link = LanLink._(socket);
    socket.add(encodeFrame(localPeerId));
    return link;
  }

  Future<Uint8List> get remotePeerId => _remotePeerId.future;

  /// Completes once the link has closed, for any reason.
  Future<void> get closed => _closed.future;

  bool get isClosed => _isClosed;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> send(Uint8List frame) async {
    if (_isClosed) return;
    _socket.add(encodeFrame(frame));
    try {
      await _socket.flush();
    } on SocketException {
      await close();
    }
  }

  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    if (!_remotePeerId.isCompleted) {
      _remotePeerId.completeError(const SocketException('closed before hello'));
    }
    await _subscription.cancel();
    _socket.destroy();
    // Not awaited: the future only completes once someone listens, and a rejected link never has a listener.
    unawaited(_incoming.close());
    if (!_closed.isCompleted) _closed.complete();
  }

  void _onData(Uint8List data) {
    final List<Uint8List> frames;
    try {
      frames = _decoder.add(data);
    } on FormatException {
      unawaited(close());
      return;
    }
    for (final frame in frames) {
      if (!_remotePeerId.isCompleted) {
        if (frame.length != peerIdLength) {
          unawaited(close());
          return;
        }
        _remotePeerId.complete(frame);
      } else {
        _incoming.add(frame);
      }
    }
  }
}
