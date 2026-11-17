---
phase: 07-internet
plans: [07-01, 07-02, 07-03]
type: execute
depends_on: ["06-01"]
requirements: [REQ-34, REQ-35, REQ-36, REQ-37]
files_modified: [lib/relay/relay_server.dart, bin/relay.dart, lib/core/relay/rendezvous.dart, lib/transports/relay_transport.dart, lib/app/internet_store.dart, lib/app/panic_wipe.dart, lib/app/chat_controller.dart, lib/ui/internet_card.dart, lib/ui/controls_page.dart, test/relay/relay_test.dart, test/app/internet_controller_test.dart]
autonomous: true
---

<design>
- **07-01 Relay server** (`lib/relay/relay_server.dart`, run with `dart run bin/relay.dart --port 7777`).
  First frame of a connection is the join: ASCII "OFMR1" plus a 16-byte rendezvous ID.
  Every later frame (length-prefixed, 512 bytes at most) goes to the other members of the
  room. Zero-length frames are keepalives. The relay never opens a frame and stores nothing.
  Limits: 16 members per room, 256 rooms, 1024 connections, 5 s to join, 90 s idle, 200
  frames per second per client, 256 frames queued per slow receiver, oversize frame closes.
- **07-02 Transport** (`RelayTransport implements MeshTransport`). One TCP connection;
  every frame sealed under the unit seal key (`SealedEnvelope`); frames that fail to open
  are dropped and counted. Rendezvous ID = HKDF(unit secret, "offmesh/rendezvous/v1/<UTC day>"),
  so the room changes daily; the transport rejoins after midnight UTC. Reconnect with
  backoff 1 s to 30 s; keepalive every 30 s. The mesh above (Noise, roster check, receipts,
  channels, voice) runs unchanged.
- **07-03 Switch.** Controls tab, Internet card: relay address (stored in the secret store,
  deleted by panic wipe), a switch that is off at every launch, and a warning shown once.
  On needs a unit, an address and Normal posture; Silent and Quiet switch it off.
</design>

<limits>
- The relay learns each client's IP address, when it is online, frame sizes and timing, and
  the daily room ID. It cannot read content, headers or identities.
- Phones whose clocks sit either side of midnight UTC are in different rooms until both pass it.
- Anyone who knows a room ID can join it and see ciphertext sizes, but cannot open or inject
  frames without the unit key.
- No relay authentication or TLS: the traffic is already sealed, but a network observer sees
  that the phone talks to the relay. TLS, and multiple relays, are not built.
- Voice (about 55 kbit/s per speaker) over a mobile connection is untested.
</limits>

<verification>
flutter test: test/relay/relay_test.dart (rendezvous ID, server rooms and limits, two nodes
chatting end to end through a real relay with a spy that sees only ciphertext, wrong-key
frames dropped, reconnect after relay restart) and test/app/internet_controller_test.dart
(address parsing, switch preconditions, posture switch-off, persistence, wipe). Analyze,
APK, Windows. Device check NOT RUN: phone on mobile data and the PC through a relay on a third machine.
</verification>
