# Roadmap: OffMesh

## Overview

OffMesh is an offline, end-to-end encrypted messenger for a small pre-provisioned group
("unit") of stock Android phones. It aims to keep message content and identities private
from anyone without the unit's keys, to keep radio emissions short and under operator
control, and to limit what a captured phone gives away. See `docs/mission_plan.md` for the
threat model and the limits.

Five phases. Each ends with one device test that can be run with two Android phones and a
Windows PC. Requirement IDs match `REQUIREMENTS.md`, which is the single source.

## Phases

- [x] **Phase 1: Protocol core** - Codecs, router, sealing, rotating IDs, receipts, key schedule, freshness, fuzzing. Built and tested in simulation.
- [ ] **Phase 2: Sealed LAN chat on real devices** - The app uses what Phase 1 built: persistent identity, roster, sealed links, no static IDs on the wire.
- [ ] **Phase 3: BLE link and background relay** - A BLE transport behind the existing `MeshTransport` interface, kept alive by a foreground service.
- [ ] **Phase 4: Operator controls** - Radio posture switch, panic wipe, Relay Mode screen.
- [ ] **Phase 5: Store-and-forward** - Messages for an offline recipient are carried by other phones.

## Phase Details

### Phase 1: Protocol core
**Goal**: A pure-Dart protocol whose frames, once sealed, reveal nothing to an observer without the unit key, proven in simulation.
**Depends on**: Nothing
**Requirements**: REQ-01 to REQ-11
**Status**: Complete. All five plans implemented, tested, and committed. 147 tests pass. Sealing and rotating IDs are wired into the app in Phase 2.
**Success Criteria** (what must be TRUE):
  1. A relay is skipped on every link that already delivered the same packet during the jitter window (per-link suppression; links are point-to-point).
  2. A sealed frame shows no header field in cleartext, fails to open under a wrong key or any flipped bit, and is rejected when older than the freshness window.
  3. Seal key and ID key are derived separately from the unit secret (HKDF); neither is the raw unit secret.
  4. A rotating discovery ID resolves to a roster member for the previous, current, and next hour only.
  5. A delivery receipt is accepted only when it decrypts on the sender's Noise session; lost and reordered transport frames are tolerated by the explicit counter and replay window.
  6. A seeded fuzz test feeds 100,000 mutated buffers to every decoder with no unhandled exception.
**Exit gate**: `flutter test` and `flutter analyze` clean, work committed, `STATE.md` updated.
**Device test**: None. This phase is simulator-only, and says so.
**Plans**: 5 plans

Plans:
- [x] 01-01: Reverse-path table and per-link flood suppression (as built: table is used by `originateTo` only; relays still flood)
- [x] 01-02: Sealed envelope codec (as built: codec only, not wired)
- [x] 01-03: Rotating IDs and roster resolver (as built: codec and resolver only, not wired)
- [x] 01-04: Delivery receipts, explicit transport counter with replay window, 10-node simulator
- [x] 01-05: Key schedule (HKDF separation), freshness timestamp inside the seal, decoder fuzz test (as built: epoch key chain left as an open decision)

### Phase 2: Sealed LAN chat on real devices
**Goal**: Two phones and a PC chat over a hotspot with every frame sealed and no stable identifier visible to a packet capture.
**Depends on**: Phase 1
**Requirements**: REQ-12 to REQ-18
**Success Criteria** (what must be TRUE):
  1. Restarting the app keeps the same identity; private keys are stored through the platform keystore.
  2. A phone with no roster cannot link; a phone provisioned by QR (PC: paste or file) can.
  3. A Wireshark capture on the PC shows no `OFFM1` tag, no static PeerID, and no readable header in the beacon, the link hello, or any frame.
  4. The beacon and hello carry a rotating ID that changes each hour.
  5. Each contact shows a key fingerprint the two operators can compare by eye.
  6. A sent message shows a delivered mark when its receipt arrives.
**Device test**: Phone A hosts a hotspot; phone B and the PC join. Send 50 messages each way between A and B and 20 between B and the PC. All arrive with delivered marks. The PC capture passes criterion 3.
**Plans**: 5 plans

Plans:
- [x] 02-01: Persistent identity via `flutter_secure_storage` (Android Keystore; Windows DPAPI file), backup disabled (as built: unit secret storage moves to 02-02; Windows build needs the VS C++ ATL component)
- [ ] 02-02: Roster format, QR export and import, fingerprint display
- [ ] 02-03: Sealed link wrapper for `LanLink`; sealed beacon and hello with rotating IDs
- [ ] 02-04: Receipts shown in the chat thread; README updated for what Phase 2 ships
- [ ] 02-05: Device test and capture checklist

### Phase 3: BLE link and background relay
**Goal**: Two pocketed phones exchange messages over Bluetooth with the screen off, and a third device on LAN is reached through one of them.
**Depends on**: Phase 2
**Requirements**: REQ-19 to REQ-22
**Success Criteria** (what must be TRUE):
  1. `BleLink implements MeshTransport`; a 512-byte sealed frame crosses a BLE link byte-identical at the negotiated ATT MTU and at a forced MTU of 23 (link segmentation exists and is tested).
  2. Each phone advertises, scans, serves GATT, and connects as a client at the same time.
  3. A `connectedDevice` foreground service keeps the link working for 30 minutes with the screen off.
  4. BLE advertisements carry a rotating ID and no static identifier.
  5. LAN-to-BLE bridging works with no router change.
**Device test**: Phones A and B in airplane mode with Bluetooth on, screens off, exchange 100 messages in 30 minutes with at least 95 delivered. Then B joins the PC's LAN and a message from A reaches the PC through B.
**Plans**: starts with a spike

Plans:
- [ ] 03-00: Spike, two days, throwaway code: dual-role BLE on the two real phones, 1000 writes of 200 bytes, 30 minutes screen-off. Output: go or no-go on plugin versus platform channel, observed MTU, service survival. Plans 03-01 onward are written from the spike result.

### Phase 4: Operator controls
**Goal**: The operator controls when the phone transmits and can destroy its keys at once.
**Depends on**: Phase 3 (posture cannot be defined before BLE behaviour is known)
**Requirements**: REQ-23 to REQ-25
**Success Criteria** (what must be TRUE):
  1. Silent: no sockets open, no UDP sent, no BLE advertising, all connections dropped, passive scan only.
  2. Quiet: no beacons or advertisements; outgoing messages queue until the operator presses a send-burst button.
  3. Panic wipe deletes the identity key, unit secret, and roster from the keystore and clears memory; the app restarts unprovisioned.
  4. Relay Mode shows a black screen with link and forward counters and keeps the foreground service running.
**Device test**: With phone B in Silent for 5 minutes, the PC capture and a BLE scanner app on phone A show nothing from B. After panic wipe on B, B cannot link and A cannot resolve B's new ID.
**Plans**: TBD

### Phase 5: Store-and-forward
**Goal**: A message for an offline recipient is delivered later by a phone that met both parties.
**Depends on**: Phase 3, Phase 4
**Requirements**: REQ-26 to REQ-28
**Success Criteria** (what must be TRUE):
  1. A message can be encrypted to a roster member's static key without an interactive handshake (one-way mode); the lost properties are documented.
  2. An envelope carries an expiry and a copy budget; carriers exchange lists of held message IDs on contact.
  3. The store is memory-only with a fixed envelope cap; expired envelopes are dropped.
**Device test**: Phone A sends to the PC while the PC is off the network. Phone B meets A over BLE, then joins the PC's LAN. The PC receives the message once.
**Plans**: TBD (first plan is the one-way encryption mode)

## Not planned

Cut or parked so they stop reappearing. Each needs a stated reason to return.

- mDNS discovery: the UDP beacon already works and mDNS adds a cleartext service name.
- Animated multi-frame QR, in-app APK sharing, duress PIN.
- Brevity codes, scheduled transmit windows, clock sync, unit broadcast channel.
- Cellular interlock beyond a warning banner (apps cannot switch the cellular radio off).
- Wi-Fi Direct and Wi-Fi Aware, until a hotspot is shown to be insufficient.
- Live push-to-talk streaming and WebRTC calls. Voice returns as a Codec2-encoded voice note inside an ordinary message; its only spike is building `libcodec2` (LGPL-2.1, check linking terms) with the NDK.
- Coded PHY as a requirement (opportunistic use only), reproducible builds, RF audit with radio test gear.
- Relay-side unicast forwarding and a seal-only relay key tier (see Open decisions).
- iOS.

## Open decisions

1. **Relay key tier.** A sealed header means a relay must hold the seal key. In v1 a relay is a full unit member, so an unattended relay phone holds the unit secret and roster. A seal-only tier would reduce that. Decide before Phase 4 Relay Mode.
2. **Epoch key chain.** Deriving seal keys from a hash chain and deleting old links would stop a captured phone from opening earlier recorded traffic. Not decided in 01-05; decide before Phase 2 plan 02-03, since it changes how the seal key is stored. It needs loosely synced clocks.
3. **TTL.** Code is 7. Revisit only after Phase 3 range measurements; changing it needs a protocol version bump.
4. **Relay-side unicast.** `docs/relay_mode.md` proposes it. Deferred until route entries come from sealed, authenticated frames (after Phase 2).

## Progress

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Protocol core | 5/5 | Complete | 2026-11-14 |
| 2. Sealed LAN chat | 5/5 | Built; device test NOT RUN | - |
| 3. BLE link and relay | 2/2 | Built with fakes and foreground service; spike NOT RUN | - |
| 4. Operator controls | 1/1 | Built, incl. Relay Mode service; device checks NOT RUN | - |
| 5. Store-and-forward | 2/2 | Built; device test NOT RUN | - |
