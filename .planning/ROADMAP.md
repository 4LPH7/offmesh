# Roadmap: OffMesh

## Overview

OffMesh evolves from a pure-Dart cryptographic and protocol core into a full 4-tier stock smartphone mesh communication system: starting with local LAN/Hotspot links and SQLite storage, scaling through dual-role BLE 5.0 mesh, expanding city-wide via delay-tolerant store-and-forward custody transfer, and culminating in full-duplex WebRTC and ultra-low-bitrate Codec2 PTT voice.

## Phases

- [ ] **Phase 1: Pure-Dart Protocol, Noise XX & Multi-Hop Simulator** - Core packet codec, fragmentation, deduplication, Noise XX, and multi-node simulated mesh.
- [ ] **Phase 2: Tier 1 LAN / Hotspot Transport & Encrypted Chat UI** - mDNS, UDP 47999 broadcast, TCP sockets, SQLite storage, 1:1 chat UI, and QR key verification.
- [ ] **Phase 3: Tier 3 Dual-Role BLE 5.0 Mesh & Background Relay** - Dual-role BLE Central/GATT server, LE Coded PHY, MTU negotiation, and Android foreground relay service.
- [ ] **Phase 4: Tier 4 Delay-Tolerant Store-and-Forward (DTN)** - Sealed custody envelopes, Spray-and-Wait replication, inventory vector sync, and 25 MB quota management.
- [ ] **Phase 5: Tier 2 Wi-Fi Direct & Full-Duplex Voice Calls** - Routerless Wi-Fi Direct high-speed links, serverless WebRTC Opus audio calls over Noise sessions.
- [ ] **Phase 6: Native libcodec2 FFI & BLE Push-to-Talk Voice** - C libcodec2 NDK compilation, Dart FFI bindings, sub-second BLE PTT bursts, and DTN voice notes.

## Phase Details

### Phase 1: Pure-Dart Protocol, Noise XX & Multi-Hop Simulator
**Goal**: Provide a rock-solid, verified pure-Dart networking and crypto foundation testable on all platforms.
**Depends on**: Nothing
**Requirements**: REQ-01, REQ-02, REQ-03, REQ-04, REQ-05
**Success Criteria** (what must be TRUE):
  1. `Packet`, `Fragmenter`, and `SeenCache` handle messages up to 56 KB without memory leaks or duplicate delivery.
  2. Noise XX handshake completes with mutual authentication and glare tie-breaking matching cacophony vectors.
  3. 10-node simulated topology verifies multi-hop delivery, jittered relaying, and loop prevention.
**Plans**: 1 plan

Plans:
- [ ] 01-01: Align protocol files (`fragmenter.dart`, `dedup.dart`) and implement 10-node simulated multi-hop topology test.

### Phase 2: Tier 1 LAN / Hotspot Transport & Encrypted Chat UI
**Goal**: Enable real zero-data local phone and PC communication with persistent storage and key verification.
**Depends on**: Phase 1
**Requirements**: REQ-06, REQ-07, REQ-08, REQ-09
**Success Criteria** (what must be TRUE):
  1. Devices discover each other over Wi-Fi and Android hotspots via mDNS and UDP port 47999 fallback.
  2. Conversations and peer identities persist across restarts in SQLite (`sqflite` / `sqflite_common_ffi`).
  3. Users can view nearby peers, send/receive 1:1 messages with delivery receipts, and verify keys via QR code.
**Plans**: TBD

### Phase 3: Tier 3 Dual-Role BLE 5.0 Mesh & Background Relay
**Goal**: Enable direct phone-to-phone multi-hop communication without any Wi-Fi infrastructure.
**Depends on**: Phase 2
**Requirements**: REQ-10, REQ-11, REQ-12
**Success Criteria** (what must be TRUE):
  1. Android phones run simultaneous BLE Central and GATT Peripheral modes.
  2. BLE links negotiate 251-byte MTU and request LE Coded PHY for extended range.
  3. Pocketed devices in Airplane Mode relay mesh packets via foreground daemon.
**Plans**: TBD

### Phase 4: Tier 4 Delay-Tolerant Store-and-Forward (DTN)
**Goal**: Bridge disconnected mesh partitions across city-wide distances via opportunistic physical carrier nodes.
**Depends on**: Phase 3
**Requirements**: REQ-13, REQ-14, REQ-15
**Success Criteria** (what must be TRUE):
  1. Messages for offline peers are sealed in custody envelopes with hop quota ($K=6$) and expiration timestamps.
  2. Peers synchronize missing envelopes via inventory vectors upon encountering each other.
  3. Ring buffer strictly enforces 25 MB device quota and purges expired envelopes.
**Plans**: TBD

### Phase 5: Tier 2 Wi-Fi Direct & Full-Duplex Voice Calls
**Goal**: High-speed routerless phone-to-phone links and real-time voice calls.
**Depends on**: Phase 2
**Requirements**: REQ-16, REQ-17, REQ-18
**Success Criteria** (what must be TRUE):
  1. Two phones establish ad-hoc Wi-Fi Direct links without manual hotspot setup.
  2. WebRTC audio calls connect peer-to-peer with Opus codec and no STUN/TURN servers.
  3. Full in-call UI operates with ring, accept, speakerphone, and mute controls.
**Plans**: TBD

### Phase 6: Native libcodec2 FFI & BLE Push-to-Talk Voice
**Goal**: Voice communication across narrow-bandwidth multi-hop BLE mesh and offline voice notes.
**Depends on**: Phase 3, Phase 4
**Requirements**: REQ-19, REQ-20, REQ-21
**Success Criteria** (what must be TRUE):
  1. `libcodec2` 1200 bps compiles via NDK CMake and binds through Dart FFI.
  2. Live PTT audio streams over BLE mesh with sub-second relay latency.
  3. 10-second compressed voice notes (<1.5 KB) transfer through Tier 4 DTN custody envelopes.
**Plans**: TBD

## Progress

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Pure-Dart Protocol & Simulator | 0/1 | In progress | - |
| 2. Tier 1 LAN & Encrypted Chat UI | 0/TBD | Not started | - |
| 3. Tier 3 Dual-Role BLE 5.0 Mesh | 0/TBD | Not started | - |
| 4. Tier 4 DTN Store-and-Forward | 0/TBD | Not started | - |
| 5. Tier 2 Wi-Fi Direct & WebRTC Calls | 0/TBD | Not started | - |
| 6. Native libcodec2 & BLE PTT Voice | 0/TBD | Not started | - |
