# Roadmap: OffMesh (Tactical Smartphone-Native Mesh)

## Overview

OffMesh implements an emission-controlled, smartphone-native mesh communicator designed to minimize RF footprint, prevent metadata leakage, and ensure zero-yield upon capture. Built in Flutter/Dart across 6 phases from pure-Dart crypto and protocol routing to BLE dual-role mesh, DTN custody transfer, Codec2 PTT voice, and traffic-analysis hardening.

## Phases

- [ ] **Phase 1: Hardened Pure-Dart Protocol Core** - Routing table with flood suppression, unit-sealed frames, rotating HMAC IDs, and end-to-end ACKs tested on a 10-node simulator.
- [ ] **Phase 2: Tier 1 LAN Transport & Operator UI** - mDNS/UDP 47999 transport, EMCON switch (Silent/Quiet/Normal), panic wipe / duress PIN, and QR offline provisioning.
- [ ] **Phase 3: Tier 3 Dual-Role BLE 5.0 Mesh & Foreground Daemon** - Android 14+ typed foreground service, simultaneous Central/GATT, MTU negotiation, and opportunistic Coded PHY.
- [ ] **Phase 4: Tier 4 Delay-Tolerant Store-and-Forward (DTN)** - Sealed custody envelopes, Spray-and-Wait custody transfer ($K=6$), and 25 MB device ring buffer.
- [ ] **Phase 5: Tier 2 Wi-Fi Direct Bridge & Codec2 PTT Voice** - Routerless direct P2P link, CMake `libcodec2` (1200 bps) FFI integration, and burst Push-to-Talk.
- [ ] **Phase 6: Hardening, Fuzzing & Red-Team Audit** - Binary protocol fuzzer, reproducible APK builds, and RF traffic-analysis red-team validation.

## Phase Details

### Phase 1: Hardened Pure-Dart Protocol Core
**Goal**: Build a robust, metadata-resistant pure-Dart protocol with flood suppression and rotating IDs.
**Depends on**: Nothing
**Requirements**: REQ-01, REQ-02, REQ-03, REQ-04, REQ-05
**Success Criteria** (what must be TRUE):
  1. Mesh router cancels pending relays if a neighboring node relays the same packet first.
  2. Frames are sealed with a shared unit key; 26-byte headers conceal packet types and hop counts from unkeyed observers.
  3. Node addresses rotate hourly via HMAC ratchets computable only by roster holders.
  4. End-to-end cryptographic delivery receipts confirm message arrival without leaking recipient location.
**Plans**: 4 plans

Plans:
- [ ] 01-01: Reverse-path routing table & managed flood suppression
- [ ] 01-02: Unit-sealed envelope (outer frame symmetric encryption)
- [ ] 01-03: Rotating hourly HMAC Peer IDs & roster resolution
- [ ] 01-04: End-to-end cryptographic delivery ACKs & 10-node simulator suite

### Phase 2: Tier 1 LAN Transport & Operator UI
**Goal**: Zero-data local network communication with EMCON radio posture control and capture protection.
**Depends on**: Phase 1
**Requirements**: REQ-06, REQ-07, REQ-08, REQ-09
**Success Criteria** (what must be TRUE):
  1. Operator can toggle Silent (listen-only), Quiet (batched transmit), and Normal radio postures.
  2. Memory-only message storage by default; panic wipe and duress PIN erase all roster keys immediately.
  3. Pre-deployment offline roster synchronization and APK distribution operate over QR codes and local hotspot.
**Plans**: TBD

### Phase 3: Tier 3 Dual-Role BLE 5.0 Mesh & Foreground Daemon
**Goal**: Pocketed phone-to-phone multi-hop communication without external hardware.
**Depends on**: Phase 2
**Requirements**: REQ-10, REQ-11, REQ-12
**Success Criteria** (what must be TRUE):
  1. Android 14+ typed foreground service keeps BLE Central and GATT server alive in pockets.
  2. MTU dynamically negotiates to 251 bytes with 20-byte fallback; Coded PHY requested opportunistically.
  3. Phones relay packets across up to 15 hops using managed flood cancellation.
**Plans**: TBD

### Phase 4: Tier 4 Delay-Tolerant Store-and-Forward (DTN)
**Goal**: Asynchronous city-wide message delivery via physical carrier mobility.
**Depends on**: Phase 3
**Requirements**: REQ-13, REQ-14, REQ-15
**Success Criteria** (what must be TRUE):
  1. Sealed custody envelopes replicate up to $K=6$ carrier nodes using inventory vector exchange.
  2. Envelopes expire automatically upon TTL expiration; device ring buffer enforces 25 MB quota strictly.
**Plans**: TBD

### Phase 5: Tier 2 Wi-Fi Direct Bridge & Codec2 PTT Voice
**Goal**: High-speed direct data synchronization and low-bandwidth tactical voice bursts.
**Depends on**: Phase 3, Phase 4
**Requirements**: REQ-16, REQ-17, REQ-18
**Success Criteria** (what must be TRUE):
  1. BLE-discovered nodes negotiate ad-hoc Wi-Fi Direct links for bulk custody exchange.
  2. `libcodec2` 1200 bps compiles via NDK CMake and binds through Dart FFI.
  3. Operators can record and stream 3–5 second half-duplex PTT bursts over BLE mesh and store voice notes in DTN envelopes.
**Plans**: TBD

### Phase 6: Hardening, Fuzzing & Red-Team Audit
**Goal**: Verification of protocol resilience, reproducible builds, and emission audit.
**Depends on**: Phase 5
**Requirements**: REQ-19, REQ-20, REQ-21
**Success Criteria** (what must be TRUE):
  1. Automated protocol fuzzer executes 100,000+ malformed packets without crashes or state corruption.
  2. Deterministic, reproducible Android APK builds match bit-for-bit across clean environments.
  3. RF emission profile confirms zero leakage in Silent mode and strict adherence to transmit windows in Quiet mode.
**Plans**: TBD

## Progress

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Hardened Protocol Core | 0/4 | In progress | - |
| 2. Tier 1 LAN & Operator UI | 0/TBD | Not started | - |
| 3. Tier 3 BLE Mesh & Daemon | 0/TBD | Not started | - |
| 4. Tier 4 DTN Store-and-Forward | 0/TBD | Not started | - |
| 5. Tier 2 Wi-Fi Direct & PTT Voice | 0/TBD | Not started | - |
| 6. Hardening, Fuzzing & Audit | 0/TBD | Not started | - |
