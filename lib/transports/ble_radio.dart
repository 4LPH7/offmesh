import 'dart:typed_data';

/// One neighbour heard in a scan: the rotating ID from its advertisement and the radio
/// address the scan reported. Carries no static identifier.
class BleSighting {
  const BleSighting({required this.address, required this.rotatingId});

  final String address;
  final Uint8List rotatingId;
}

/// One connected BLE link. Chunks travel as ATT writes or notifications of at most
/// [mtu] - 3 bytes each. Implemented by the platform radio and by test fakes.
abstract interface class BleChannel {
  /// Negotiated ATT MTU. 23 until the radio reports the negotiated value.
  int get mtu;

  /// True when this side opened the connection as GATT client.
  bool get isClient;

  /// Chunks from the peer, in arrival order.
  Stream<Uint8List> get received;

  /// Sends one chunk; completes when the radio has accepted it for delivery.
  Future<void> writeChunk(Uint8List chunk);

  Future<void> close();
}

/// The radio seam: advertise, scan, GATT server (inbound channels) and GATT client
/// (connect). Every method is asynchronous because the platform answers asynchronously.
abstract interface class BleRadio {
  /// Neighbours heard while scanning.
  Stream<BleSighting> get sightings;

  /// Centrals that connected to our GATT server.
  Stream<BleChannel> get inboundChannels;

  /// Advertises [rotatingId] (8 bytes) under the OffMesh service UUID and nothing else.
  Future<void> startAdvertising(Uint8List rotatingId);

  Future<void> stopAdvertising();

  Future<void> startScan();

  Future<void> stopScan();

  /// Opens a GATT client connection to [address] and completes once it is ready to carry chunks.
  Future<BleChannel> connect(String address);
}
