import 'dart:async';
import 'dart:typed_data';

import '../core/crypto/rotating_id.dart';
import '../core/crypto/unit_keys.dart';
import '../core/mesh/mesh_node.dart';
import '../core/posture.dart';
import '../core/protocol/sealed_envelope.dart';
import 'ble_link.dart';
import 'ble_radio.dart';
import 'lan_link.dart' show defaultLinkIdleTimeout;

const Duration _bleConnectTimeout = Duration(seconds: 10);
const Duration _bleHelloTimeout = Duration(seconds: 10);
const Duration _bleRefresh = Duration(seconds: 30);

/// Higher-PeerID side waits this long for the lower side to dial before dialing itself.
const Duration bleDialYield = Duration(seconds: 6);
const Duration bleDialBackoff = Duration(seconds: 10);

/// BLE links at once; a phone can hold only a few GATT connections.
const int maxBleLinks = 6;

class _BleUnit {
  const _BleUnit(this.envelope, this.idKey, this.resolver);

  final SealedEnvelope envelope;
  final Uint8List idKey;
  final RosterResolver resolver;
}

/// Brings BLE neighbours into a [MeshNode], like LanManager does for Wi-Fi. Advertises
/// only the hourly rotating ID, scans for unit members, dials one link per member and
/// accepts inbound GATT links. Every frame is sealed by [BleLink].
///
/// Posture: Silent stops everything and closes links; Quiet stops advertising, scanning
/// and new dials, and keeps open links; Normal runs discovery.
class BleManager {
  BleManager({
    required this.node,
    required this.radio,
    required this.posture,
    this.linkIdleTimeout = defaultLinkIdleTimeout,
    this.dialYield = bleDialYield,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final MeshNode node;
  final BleRadio radio;
  final PostureController posture;
  final Duration linkIdleTimeout;
  final Duration dialYield;
  final DateTime Function() _clock;

  _BleUnit? _unit;
  bool _running = false;
  bool _discovering = false;
  Uint8List? _advertised;
  Timer? _refresh;
  StreamSubscription<BleSighting>? _sightingSub;
  StreamSubscription<BleChannel>? _inboundSub;
  final Map<String, BleLink> _links = {};
  final Map<String, bool> _dialedByMe = {};
  final Set<String> _dialing = {};
  final Set<String> _backingOff = {};
  int _generation = 0;
  int _dropped = 0;

  /// Why the radio refused the last call, or null.
  String? lastError;

  Set<String> get linkedPeerIds => _links.keys.toSet();

  int get droppedFrames => _dropped;

  bool get running => _running;

  Future<void> configure(
    UnitKeys keys,
    List<List<int>> rosterPublicKeys,
  ) async {
    _unit = _BleUnit(
      SealedEnvelope(keys.sealKey, clock: _clock),
      Uint8List.fromList(keys.idKey),
      await RosterResolver.create(keys.idKey, rosterPublicKeys, clock: _clock),
    );
  }

  /// Starts accepting links and, in Normal, discovery. Does nothing in Silent.
  Future<void> start() async {
    if (_unit == null || _running || posture.current == Posture.silent) return;
    _running = true;
    _sightingSub = radio.sightings.listen((s) => unawaited(_onSighting(s)));
    _inboundSub = radio.inboundChannels.listen(
      (channel) => unawaited(_adopt(channel)),
    );
    _refresh = Timer.periodic(_bleRefresh, (_) => unawaited(applyPosture()));
    await applyPosture();
  }

  /// Follows the posture: call after every change.
  Future<void> applyPosture() async {
    if (!_running) return;
    switch (posture.current) {
      case Posture.silent:
        await stop();
      case Posture.quiet:
        await _stopDiscovery();
      case Posture.normal:
        await _startDiscovery();
    }
  }

  Future<void> _startDiscovery() async {
    final unit = _unit;
    if (unit == null) return;
    final id = await _ownRotatingId(unit);
    if (posture.current != Posture.normal || !_running) return;
    try {
      // The rotating ID changes hourly: advertise again when it does.
      if (_advertised == null || !_same(_advertised!, id)) {
        if (_advertised != null) await radio.stopAdvertising();
        await radio.startAdvertising(id);
        _advertised = id;
      }
      if (!_discovering) {
        await radio.startScan();
        _discovering = true;
      }
      lastError = null;
    } catch (error) {
      lastError = error.runtimeType.toString();
    }
  }

  Future<void> _stopDiscovery() async {
    try {
      if (_advertised != null) await radio.stopAdvertising();
      if (_discovering) await radio.stopScan();
    } catch (_) {
      // The radio may already be off.
    }
    _advertised = null;
    _discovering = false;
  }

  /// Stops discovery and closes every link.
  Future<void> stop() async {
    _generation++;
    _running = false;
    _refresh?.cancel();
    _refresh = null;
    await _sightingSub?.cancel();
    await _inboundSub?.cancel();
    _sightingSub = null;
    _inboundSub = null;
    await _stopDiscovery();
    final links = _links.values.toList();
    _links.clear();
    _dialedByMe.clear();
    _dialing.clear();
    _backingOff.clear();
    for (final link in links) {
      await link.close();
    }
  }

  Future<Uint8List> _ownRotatingId(_BleUnit unit) =>
      rotatingId(unit.idKey, node.identity.publicKey, epochAt(_clock()));

  Future<void> _onSighting(BleSighting sighting) async {
    final unit = _unit;
    final generation = _generation;
    if (unit == null || posture.current != Posture.normal) return;
    try {
      final member = await unit.resolver.resolve(sighting.rotatingId);
      if (member == null || generation != _generation) return;
      final peer = _hex(member.peerId);
      final self = _hex(node.peerId);
      if (peer == self ||
          _links.containsKey(peer) ||
          _dialing.contains(peer) ||
          _backingOff.contains(peer) ||
          _links.length >= maxBleLinks) {
        return;
      }
      _dialing.add(peer);
      // The lower PeerID dials; the higher waits, then dials only if no link came.
      if (peer.compareTo(self) < 0) {
        await Future<void>.delayed(dialYield);
      }
      if (generation != _generation ||
          _links.containsKey(peer) ||
          posture.current != Posture.normal) {
        _dialing.remove(peer);
        return;
      }
      var linked = false;
      try {
        final channel = await radio
            .connect(sighting.address)
            .timeout(_bleConnectTimeout);
        linked = await _adopt(channel);
      } catch (_) {
        linked = false;
      }
      if (generation != _generation) return;
      _dialing.remove(peer);
      if (!linked) {
        _backingOff.add(peer);
        Timer(bleDialBackoff, () {
          if (generation == _generation) _backingOff.remove(peer);
        });
      }
    } catch (_) {
      // A stale or hostile sighting never fails the zone; the next scan retries.
    }
  }

  /// Runs the sealed handshake on [channel] and registers the link.
  Future<bool> _adopt(BleChannel channel) async {
    final unit = _unit;
    final generation = _generation;
    if (unit == null || posture.current == Posture.silent) {
      await channel.close();
      return false;
    }
    final link = BleLink.attach(
      channel,
      envelope: unit.envelope,
      resolver: unit.resolver,
      localRotatingId: await _ownRotatingId(unit),
      idleTimeout: linkIdleTimeout,
      onDrop: () => _dropped++,
      clock: _clock,
    );
    final Uint8List remote;
    try {
      remote = await link.remotePeerId.timeout(_bleHelloTimeout);
    } catch (_) {
      await link.close();
      return false;
    }
    final key = _hex(remote);
    final existing = _links[key];
    // Two dials that cross: both ends keep the link the lower PeerID dialed.
    final selfIsLower = _hex(node.peerId).compareTo(key) < 0;
    final keepNew =
        existing == null ||
        (channel.isClient == selfIsLower && _dialedByMe[key] != selfIsLower);
    if (generation != _generation || key == _hex(node.peerId) || !keepNew) {
      await link.close();
      return false;
    }
    _links[key] = link;
    _dialedByMe[key] = channel.isClient;
    if (existing != null) unawaited(existing.close());
    node.addTransport(link);
    unawaited(
      link.closed.then((_) async {
        if (identical(_links[key], link)) _links.remove(key);
        await node.removeTransport(link);
      }),
    );
    return true;
  }

  static bool _same(List<int> a, List<int> b) =>
      a.length == b.length && _hex(a) == _hex(b);

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
