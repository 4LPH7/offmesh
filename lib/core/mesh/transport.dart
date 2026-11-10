import 'dart:typed_data';

/// One physical link (a BLE connection, a LAN socket, a radio). The router uses this
/// interface only, so the core mesh logic runs unchanged on every platform and in tests.
abstract interface class MeshTransport {
  /// Encoded packets arriving on this link.
  Stream<Uint8List> get incoming;

  /// Sends one encoded packet to every neighbour reachable over this link.
  Future<void> send(Uint8List frame);
}
