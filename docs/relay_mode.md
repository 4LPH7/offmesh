# Relay Mode

Relay Mode turns a spare Android phone into a stationary repeater. It adds **no new
protocol**, **no new dependencies**, and only one new core class. Everything a relay does,
every node already does today: decode, dedupe, decrement TTL, forward. Relay Mode is a
power and UX profile on top of that, plus one routing improvement that benefits *every*
node, relay or not.

Relays never hold Noise session keys, so they see only the 26-byte header. That is already
true of `MeshRouter` and does not change.

## What the codebase already gives us

| Draft assumption | Reality in `lib/` | Consequence |
| --- | --- | --- |
| `transport.sendToPeer(id, bytes)` and `broadcastExcept(...)` | A `MeshTransport` **is one link** (`LanLink` = one TCP socket, `FakeEndpoint` = one edge). `send()` reaches exactly one neighbour. | A "next hop" is just a `MeshTransport` reference. No neighbour IDs needed in the table. |
| `maxTtl = 15` | `maxTtl = 7` | Hop count = `maxTtl - ttl`, range 0..7. Seven hops covers a realistic chain; raising it is a one-constant change if ever needed. |
| `PacketType.voiceFrame`, `callRing`, `textMessage` | `announce`, `noiseHandshake`, `noiseTransport`, `ack` | Do not key behaviour on voice types that do not exist yet. Key it on **unicast vs broadcast**, which already exists. |
| Cross-radio bridging needs new code | `MeshRouter` holds a flat `List<MeshTransport>` and relays to all except the inbound one | LAN to BLE bridging is free the day `BleLink implements MeshTransport`. Nothing to build. |
| Relay-mode-specific forwarding (less jitter when relaying) | Jitter exists to desynchronise neighbours on a shared medium | A relay needs collision avoidance exactly as much as an endpoint. **Forwarding logic must not depend on the relay flag.** |

## The one routing change: learn the reverse path

Today the router floods everything. In a chain A, R1, R2, R3, B that is fine for the first
packet, but every reply also floods, and every hop adds 15 to 85 ms of jitter. Over six
hops that is up to half a second and six times the airtime a unicast path would use.

Fix: whenever a packet from `senderId` arrives on link `L` having taken `hops` hops,
remember `senderId -> L`. When a later packet is **addressed** to that sender, send it on
`L` only, with **no jitter**. Jitter is a broadcast-storm defence; a single-link unicast
has no storm to defend against.

Floods are unchanged. Broadcasts, packets to unknown destinations, and packets whose route
has expired still go everywhere except the inbound link, with the existing jitter. This
makes the change **safe by construction**: the worst case is today's behaviour.

### `lib/core/mesh/routing_table.dart` (new, about 40 lines)

```dart
import 'dart:typed_data';
import '../protocol/packet.dart';
import 'transport.dart';

const Duration routeLifetime = Duration(seconds: 60);
const int maxRoutes = 256;

class Route {
  Route(this.via, this.hops, this.seenAt);
  final MeshTransport via;
  final int hops;
  final DateTime seenAt;
}

/// Reverse-path table: which link last carried packets *from* each sender.
class RoutingTable {
  RoutingTable({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final Map<String, Route> _routes = {}; // insertion-ordered: oldest first

  int get length => _routes.length;

  /// Keeps the shortest fresh route; a longer one only replaces a stale one.
  void learn(Uint8List sender, MeshTransport via, int hops) {
    final key = sender.hex;
    final now = _clock();
    final old = _routes[key];
    if (old != null && hops > old.hops && !_expired(old, now)) return;
    _routes.remove(key);
    _routes[key] = Route(via, hops, now);
    while (_routes.length > maxRoutes) {
      _routes.remove(_routes.keys.first);
    }
  }

  /// Fresh next hop toward [recipient], or null to fall back to flooding.
  MeshTransport? nextHop(Uint8List recipient) {
    final route = _routes[recipient.hex];
    if (route == null || _expired(route, _clock())) return null;
    return route.via;
  }

  void forget(MeshTransport via) =>
      _routes.removeWhere((_, r) => identical(r.via, via));

  bool _expired(Route r, DateTime now) =>
      now.difference(r.seenAt) > routeLifetime;
}
```

### `lib/core/mesh/router.dart` (diff, about 15 lines)

```dart
// field, constructed with the same clock as SeenCache
final RoutingTable _routes;

// in _onFrame, right after the duplicate check:
_routes.learn(packet.senderId, from, maxTtl - packet.ttl);

// replace the tail of _onFrame:
final next = _routes.nextHop(packet.recipientId);
final frame = _withTtl(packet, packet.ttl - 1).encode();
if (!packet.isBroadcast && next != null && !identical(next, from)) {
  await next.send(frame);                     // unicast, zero jitter
} else {
  await _delay(_relayJitter());
  await _sendEverywhere(frame, except: from); // flood, unchanged
}

// in removeTransport:
_routes.forget(transport);

// originate(): unchanged. The local node never learns itself as a route.
```

Why `!identical(next, from)`: if the best route to the recipient is the link the packet
just arrived on, the table is stale. Flooding is the right recovery.

Route lifetime is 60 seconds. Handshakes, acks, and every data packet refresh the entry, so
an active conversation never expires, and a relay that was carried away stops attracting
traffic within a minute.

Side benefit: `MeshNode` documents that Noise's in-order nonce drops reordered ciphertexts.
Flooding across unequal paths causes reordering; a single learned path does not.

### Tests (`test/core/mesh/`)

- `routing_table_test.dart`: shortest route wins, longer route replaces only a stale one,
  expiry returns null, `forget` clears a link, table caps at `maxRoutes` and evicts oldest.
- `router_test.dart` additions on a 10-node line using `FakeTopology`:
  - After A sends to J, the reply from J to A causes exactly 9 transmissions (one per
    link) and zero jitter `Pause` calls.
  - Remove a link mid-chain; the next packet floods and still arrives.
  - Broadcasts still reach every node and still take jitter.
- `mesh_limits_test.dart`: spraying random `senderId`s cannot grow the table past
  `maxRoutes`.

## Relay Mode as a device profile

Nothing below touches `lib/core/`. Relay Mode is: keep the radios awake, show the operator
it is working, and stay out of the way.

| Concern | Decision |
| --- | --- |
| Entry point | One switch in the app bar: **Relay Mode**. It pushes `RelayScreen` and starts the foreground service already planned for Phase 3. |
| Keeping radios alive | Android foreground service (type `connectedDevice`) plus `wakelock_plus`. The service is what defeats Doze; the wakelock only keeps the screen from sleeping. |
| Screen | Full `#000000` background, one dim grey line of counters redrawn every few seconds. Near-zero AMOLED draw, and the app stays foreground on vendors that kill background BLE scanning. |
| Counters | Links up, packets forwarded, bytes forwarded, routes known, uptime, battery %. All read from `MeshRouter` and `RoutingTable` getters. Nothing decrypted, nothing new logged. |
| Hotspot | **Not automated in v1.** Show a one-line hint: "For a faster link, turn on your phone's hotspot and let neighbours join it." `startLocalOnlyHotspot` yields random credentials and is fragile across vendors; pushing those over BLE is a Phase 5 problem. |
| Exit | Any tap reveals a "Leave Relay Mode" button. The back gesture is ignored so a pocket press does not drop the chain. |

Dropped from the draft on purpose:

- **Data-mule / DTN relay.** That is Phase 4's store-and-forward engine, not a repeater
  feature. Mixing it in here doubles the scope.
- **Relay-only low jitter.** Collision avoidance is per medium, not per role.
- **Voice-type special cases.** Unicast-vs-broadcast covers voice automatically once voice
  exists, because voice frames are addressed to one peer.
- **Range tables in kilometres.** Phone BLE with Coded PHY reaches tens to a few hundred
  metres line of sight, and many handsets lack Coded PHY. Measure on real hardware in
  Phase 3 and publish numbers then.

## Where it lands in the roadmap

- **Phase 1** (now): `RoutingTable`, the router diff, and the 10-node line tests above.
  This is the entire protocol-level change.
- **Phase 2**: Relay Mode switch, black `RelayScreen`, counters. Useful immediately as a
  desk relay between two LAN segments.
- **Phase 3**: The already-planned foreground service and `BleLink implements
  MeshTransport`. Bridging falls out for free. First real range and hop measurements.
- **Phase 5**: Optional hotspot anchor with credentials shared over BLE, only if Phase 3
  measurements show it is worth the complexity.
