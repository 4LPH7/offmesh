import 'dart:async';
import 'dart:typed_data';

import 'package:offmesh/transports/ble_radio.dart';

/// One end of an in-memory BLE connection. Writes arrive on the peer's [received]
/// stream asynchronously, as a radio would deliver them. Closing one end closes both.
class FakeBleChannel implements BleChannel {
  FakeBleChannel._(this._mtu, this.isClient);

  /// A connected pair: the first end is the GATT client, the second the server.
  static (FakeBleChannel, FakeBleChannel) pair({int mtu = 23}) {
    final client = FakeBleChannel._(mtu, true);
    final server = FakeBleChannel._(mtu, false);
    client._peer = server;
    server._peer = client;
    return (client, server);
  }

  int _mtu;
  FakeBleChannel? _peer;
  bool _closed = false;
  final StreamController<Uint8List> _inbound = StreamController<Uint8List>();

  /// Every chunk this end has written, in order.
  final List<Uint8List> written = [];

  @override
  int get mtu => _mtu;

  /// Models a negotiated MTU; set it on both ends before use.
  set mtu(int value) => _mtu = value;

  @override
  final bool isClient;

  @override
  Stream<Uint8List> get received => _inbound.stream;

  @override
  Future<void> writeChunk(Uint8List chunk) async {
    if (_closed) throw StateError('channel closed');
    if (chunk.length > _mtu - 3) {
      throw ArgumentError(
        'chunk of ${chunk.length} bytes exceeds the ATT write limit',
      );
    }
    final copy = Uint8List.fromList(chunk);
    written.add(copy);
    _deliverToPeer(copy);
  }

  /// Delivers [raw] to the peer as if it were a chunk, bypassing the segmenter. Tests use it
  /// to play a hostile or broken peer.
  void sendRaw(Uint8List raw) => _deliverToPeer(Uint8List.fromList(raw));

  void _deliverToPeer(Uint8List chunk) {
    final peer = _peer;
    if (peer == null || peer._inbound.isClosed) return;
    peer._inbound.add(chunk);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _inbound.close();
    await _peer?.close();
  }
}
