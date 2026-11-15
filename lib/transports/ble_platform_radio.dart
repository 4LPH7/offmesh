import 'dart:async';

import 'package:flutter/services.dart';

import '../core/ble/ble_segmenter.dart';
import 'ble_radio.dart';

/// Channel names; must match BleRadioPlugin.kt.
const String bleControlChannelName = 'me.offmesh.offmesh/ble';
const String bleEventChannelName = 'me.offmesh.offmesh/ble/events';

/// [BleRadio] over the Android BluetoothLeAdvertiser, scanner, GATT server and GATT client
/// (BleRadioPlugin.kt). Only moves bytes; sealing and segmenting happen in BleLink.
/// Not exercised by unit tests; verified only by building the APK.
class BlePlatformRadio implements BleRadio {
  BlePlatformRadio({MethodChannel? control, EventChannel? events})
    : _control = control ?? const MethodChannel(bleControlChannelName),
      _events = events ?? const EventChannel(bleEventChannelName) {
    _eventSubscription = _events.receiveBroadcastStream().listen(_onEvent);
  }

  final MethodChannel _control;
  final EventChannel _events;
  final StreamController<BleSighting> _sightings =
      StreamController<BleSighting>.broadcast();
  final StreamController<BleChannel> _inbound =
      StreamController<BleChannel>.broadcast();
  final Map<String, _PlatformChannel> _channels = {};
  late final StreamSubscription<dynamic> _eventSubscription;

  @override
  Stream<BleSighting> get sightings => _sightings.stream;

  @override
  Stream<BleChannel> get inboundChannels => _inbound.stream;

  @override
  Future<void> startAdvertising(Uint8List rotatingId) {
    if (rotatingId.length != 8) {
      throw ArgumentError.value(
        rotatingId.length,
        'rotatingId',
        'must be 8 bytes',
      );
    }
    return _control.invokeMethod<void>('startAdvertising', {
      'rotatingId': rotatingId,
    });
  }

  @override
  Future<void> stopAdvertising() =>
      _control.invokeMethod<void>('stopAdvertising');

  @override
  Future<void> startScan() => _control.invokeMethod<void>('startScan');

  @override
  Future<void> stopScan() => _control.invokeMethod<void>('stopScan');

  @override
  Future<BleChannel> connect(String address) async {
    final reply = await _control.invokeMapMethod<String, dynamic>('connect', {
      'address': address,
    });
    final key = reply?['key'] as String?;
    if (key == null) throw StateError('connect returned no channel key');
    return _channels[key] ??= _PlatformChannel(this, key, isClient: true);
  }

  Future<void> close() => _eventSubscription.cancel();

  void _onEvent(dynamic raw) {
    final event = raw as Map<dynamic, dynamic>;
    final key = event['key'] as String?;
    switch (event['event']) {
      case 'sighting':
        _sightings.add(
          BleSighting(
            address: event['address'] as String,
            rotatingId: event['data'] as Uint8List,
          ),
        );
      case 'inbound':
        if (key == null) return;
        final channel = _channels[key] ??= _PlatformChannel(
          this,
          key,
          isClient: false,
        );
        _inbound.add(channel);
      case 'chunk':
        final data = event['data'] as Uint8List?;
        if (data != null) _channels[key]?._received.add(data);
      case 'mtu':
        final mtu = event['mtu'] as int?;
        if (mtu != null) _channels[key]?._mtu = mtu;
      case 'closed':
        _channels.remove(key)?._closeFromPeer();
    }
  }

  void _forget(String key) => _channels.remove(key);
}

class _PlatformChannel implements BleChannel {
  _PlatformChannel(this._radio, this._key, {required this.isClient});

  final BlePlatformRadio _radio;
  final String _key;
  int _mtu = minAttMtu;
  final StreamController<Uint8List> _received = StreamController<Uint8List>();

  @override
  final bool isClient;

  @override
  int get mtu => _mtu;

  @override
  Stream<Uint8List> get received => _received.stream;

  @override
  Future<void> writeChunk(Uint8List chunk) => _radio._control
      .invokeMethod<void>('writeChunk', {'key': _key, 'data': chunk});

  @override
  Future<void> close() async {
    if (_received.isClosed) return;
    _radio._forget(_key);
    unawaited(_received.close());
    try {
      await _radio._control.invokeMethod<void>('closeChannel', {'key': _key});
    } on PlatformException {
      // The link is already gone on the platform side.
    }
  }

  void _closeFromPeer() {
    _radio._forget(_key);
    if (!_received.isClosed) unawaited(_received.close());
  }
}
