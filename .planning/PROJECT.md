# OffMesh

## What This Is

An offline, end-to-end encrypted messenger for a small pre-provisioned group of stock
Android phones. No internet, SIM, server, or extra radio hardware. Built in Flutter. A
Windows desktop build exists as a LAN-only test peer and packet-capture station.

## Core Value

Phone-to-phone private messaging where frames are sealed under a unit key, identities are
not visible to outside observers, emissions are under operator control, and a captured
phone can be wiped by deleting its keys.

## Requirements

`REQUIREMENTS.md` is the single source for requirement IDs and status. `ROADMAP.md` holds
phases, success criteria, and device tests.

### Validated (committed)

- [x] 26-byte packet codec, fragmentation and reassembly, seen-cache deduplication (2048 entries)
- [x] Noise XX handshake checked against a published cacophony test vector
- [x] Flood router with TTL (max 7), relay jitter 15 to 85 ms, duplicate drop
- [x] LAN transport: length-prefixed TCP frames, UDP beacon on port 47999, one-screen chat UI

### Active

- [ ] Phase 1 close-out: commit built work; key schedule, seal freshness, decoder fuzzing
- [ ] Phase 2: sealed LAN chat on real devices with persistent identity and roster
- [ ] Phase 3: BLE link and foreground-service relay
- [ ] Phase 4: operator controls (radio posture, panic wipe, Relay Mode)
- [ ] Phase 5: store-and-forward for offline recipients

### Out of Scope

- External radio hardware (LoRa, HF, dongles)
- Servers, cloud relays, accounts, phone numbers
- iOS
- Voice calls and live push-to-talk (voice notes are parked; see ROADMAP "Not planned")
- Message history on disk (messages are memory-only; only keys and the roster persist)

## Context

- Target: Android 8.0+ (API 26+). Windows 11 runner for LAN testing; roster import there is paste or file, not camera.
- UI: Flutter, Material 3, plain `ChangeNotifier`.
- Transports, all behind `MeshTransport` (one object = one link):
  - LAN over Wi-Fi or hotspot (`LanLink`) — exists
  - BLE (`BleLink`) — Phase 3
- Test hardware: two or more Android phones, one Windows PC. No radio test gear.

## Constraints

- **Hardware**: Stock Android phones only.
- **Security**: Noise XX between peers; unit-key sealing of whole frames; key fingerprint comparison between operators.
- **Limits in code**: TTL 7, payload 220 bytes per packet, 2048-entry seen cache, 32 in-flight reassemblies, 256 routes.
- **Honest limits**: a transmitter can always be located by radio; a captured unlocked phone gives up its unit secret and roster until wiped. See `docs/mission_plan.md`.

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Stock phones only | No barrier to entry | Good |
| Noise XX on `cryptography` | Mutual authentication without a PKI; the `noise_protocol` package is discontinued | Good |
| Managed flooding, per-link suppression | Survives mobility; links are point-to-point so a full relay cancel would starve neighbours | Good |
| Static IDs inside the seal, rotating IDs on discovery only | Rotation adds nothing inside an encrypted header and would complicate session keying | Good |
| Receipts inside the Noise session | The handshake hash is not secret, so a separate MAC would prove nothing | Good |
| Five phases, hardening folded in | Fuzzing is cheap now; a late hardening phase hides defects | Pending |
| Voice dropped from the schedule | Continuous transmission conflicts with emission control | Pending |
