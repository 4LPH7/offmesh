import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/mesh/transport.dart';

/// Deterministic virtual time for relay jitter.
///
/// Every pause lasts [hopDelay] whatever jitter the router asked for, so links stay FIFO
/// and copies that travel equal-length paths land inside each other's relay window.
class VirtualTime {
  VirtualTime({this.hopDelay = const Duration(milliseconds: 50)});

  final Duration hopDelay;
  DateTime now = DateTime.utc(2026, 1, 1);
  final List<(DateTime, Completer<void>)> _timers = [];

  Future<void> pause(Duration _) {
    final completer = Completer<void>();
    _timers.add((now.add(hopDelay), completer));
    return completer.future;
  }

  /// Fires timers in deadline order (ties in creation order) until nothing is pending.
  Future<void> run() async {
    await pumpEventQueue();
    while (_timers.isNotEmpty) {
      var next = 0;
      for (var i = 1; i < _timers.length; i++) {
        if (_timers[i].$1.isBefore(_timers[next].$1)) next = i;
      }
      final (deadline, completer) = _timers.removeAt(next);
      now = deadline;
      completer.complete();
      await pumpEventQueue();
    }
  }
}

/// Counts and records every frame sent on any link of the fake topology.
class FakeNetwork {
  int transmissions = 0;
  final List<Uint8List> frames = [];
}

class FakeEndpoint implements MeshTransport {
  FakeEndpoint(this._network);

  final FakeNetwork _network;
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  FakeEndpoint? peer;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> send(Uint8List frame) async {
    _network.transmissions++;
    _network.frames.add(frame);
    peer?._incoming.add(frame);
  }
}

/// Nodes numbered 0..n-1 joined by point-to-point links given as (a, b) pairs.
class FakeTopology {
  FakeTopology(int nodeCount, List<(int, int)> edges)
    : network = FakeNetwork() {
    _endpoints = List.generate(nodeCount, (_) => <FakeEndpoint>[]);
    for (final (a, b) in edges) {
      final endA = FakeEndpoint(network);
      final endB = FakeEndpoint(network);
      endA.peer = endB;
      endB.peer = endA;
      _endpoints[a].add(endA);
      _endpoints[b].add(endB);
    }
  }

  final FakeNetwork network;
  late final List<List<FakeEndpoint>> _endpoints;

  List<MeshTransport> transportsOf(int node) => List.of(_endpoints[node]);
}
