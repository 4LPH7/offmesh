import 'dart:async';
import 'dart:typed_data';

import '../core/ble/ble_reassembler.dart';
import '../core/ble/ble_segmenter.dart';
import '../core/crypto/rotating_id.dart';
import '../core/mesh/transport.dart';
import '../core/protocol/sealed_envelope.dart';
import 'ble_radio.dart';
import 'lan_link.dart' show defaultLinkIdleTimeout;
import 'sealed_link.dart';

/// One BLE connection to a peer. Each packet is sealed as a whole frame, split into
/// chunks that fit the channel's MTU, and reassembled and opened on the other side.
/// The handshake, roster check and keepalive are the same [SealedLink] that LAN uses.
class BleLink implements MeshTransport {
  BleLink._(this._channel, this._reassembler, this._onDrop);

  final BleChannel _channel;
  final BleReassembler _reassembler;
  final void Function() _onDrop;
  late final SealedLink _sealed;
  StreamSubscription<Uint8List>? _subscription;
  int _messageId = 0;

  /// Starts the link over [channel]. The dialer is the GATT client. [onDrop] is called for
  /// each malformed chunk and each frame after the handshake that fails to open.
  static BleLink attach(
    BleChannel channel, {
    required SealedEnvelope envelope,
    required RosterResolver resolver,
    required Uint8List localRotatingId,
    Duration idleTimeout = defaultLinkIdleTimeout,
    void Function()? onDrop,
    DateTime Function()? clock,
  }) {
    final link = BleLink._(
      channel,
      BleReassembler(clock: clock),
      onDrop ?? () {},
    );
    link._sealed = SealedLink.attach(
      envelope: envelope,
      resolver: resolver,
      localRotatingId: localRotatingId,
      isDialer: channel.isClient,
      idleTimeout: idleTimeout,
      writeSealed: link._writeSealed,
      closeTransport: link._closeChannel,
      onDrop: onDrop,
    );
    link._subscription = channel.received.listen(
      link._onChunk,
      onDone: () => unawaited(link.close()),
    );
    return link;
  }

  /// The sender's static PeerID, once its hello resolved to a roster member.
  Future<Uint8List> get remotePeerId => _sealed.remotePeerId;

  /// Completes once the link has closed, for any reason.
  Future<void> get closed => _sealed.closed;

  bool get isClosed => _sealed.isClosed;

  @override
  Stream<Uint8List> get incoming => _sealed.incoming;

  /// Rejects a packet that would not fit one sealed frame. Checked before sealing so an
  /// oversize packet does not end the link.
  @override
  Future<void> send(Uint8List frame) {
    if (frame.length + sealOverhead > maxBleFrameLength) {
      return Future.error(
        ArgumentError.value(
          frame.length,
          'frame',
          'too large for one BLE frame',
        ),
      );
    }
    return _sealed.send(frame);
  }

  Future<void> close() => _sealed.close();

  Future<void> _writeSealed(Uint8List sealedFrame) async {
    final messageId = _messageId;
    _messageId = (_messageId + 1) & 0xFFFF;
    final chunks = segmentFrame(sealedFrame, _channel.mtu, messageId);
    for (final chunk in chunks) {
      await _channel.writeChunk(chunk);
    }
  }

  void _onChunk(Uint8List chunk) {
    final Uint8List? frame;
    try {
      frame = _reassembler.add(
        chunk,
        maxChunkLength: _channel.mtu - attOverhead,
      );
    } on BleFramingException {
      _onDrop();
      return;
    }
    if (frame != null) _sealed.onSealedFrame(frame);
  }

  Future<void> _closeChannel() async {
    await _subscription?.cancel();
    await _channel.close();
  }
}
