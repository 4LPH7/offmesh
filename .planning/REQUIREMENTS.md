# Requirements: OffMesh

Single source for requirement IDs. `ROADMAP.md` and plan files cite these IDs.
A box is ticked only when the behaviour is implemented, tested, committed, and matches the
wording. "Built" in the table means code and tests are committed but the feature is not
wired into the running app.

## Phase 1: Protocol core
- [x] **REQ-01**: 26-byte binary packet header codec with strict validation; TTL 0 to 7 (`maxTtl = 7`).
- [x] **REQ-02**: Message fragmentation and bounded reassembly (32 in-flight messages).
- [x] **REQ-03**: Seen-cache deduplication keyed on `(SenderID, PacketID, FragIdx)`, 2048 entries, 300 s.
- [x] **REQ-04**: Noise XX handshake (`Noise_XX_25519_ChaChaPoly_SHA256`) with mutual authentication and glare tie-break.
- [x] **REQ-05**: Per-link flood suppression: a relay is skipped on any link that already delivered the same packet during the jitter window. Reverse-path table used for the originator's first hop.
- [x] **REQ-06**: Sealed envelope codec: whole frame encrypted under a 32-byte key with ChaCha20-Poly1305, random nonce, domain label.
- [x] **REQ-07**: Rotating 8-byte discovery IDs from HMAC-SHA256 over public key and hourly epoch, with a roster resolver covering the previous, current, and next epoch.
- [x] **REQ-08**: End-to-end delivery receipt carried as a Noise transport message; never acknowledged itself.
- [x] **REQ-09**: Explicit transport counter and replay window so lost or reordered frames do not break a session.
- [x] **REQ-10**: Key schedule and freshness: seal key and ID key derived separately from the unit secret with HKDF; a timestamp inside the seal bounds replay of recorded frames.
- [x] **REQ-11**: Seeded fuzz test over every decoder (packet, sealed envelope, reassembly, receipt, LAN framing): 100,000 mutated inputs, no unhandled exception.

## Phase 2: Sealed LAN chat on real devices
- [x] **REQ-12**: Persistent identity: static key created once and stored through the platform keystore.
- [x] **REQ-13**: Unit secret and roster stored at rest through the same store; app refuses to link when unprovisioned.
- [x] **REQ-14**: Roster provisioning by one static QR code (Windows: paste or file).
- [x] **REQ-15**: Every LAN frame sealed, including the link hello and the UDP beacon.
- [x] **REQ-16**: No static identifier on the wire: beacon and hello carry rotating IDs; static PeerIDs appear only inside sealed frames.
- [x] **REQ-17**: Key fingerprint shown per contact for comparison by eye.
- [x] **REQ-18**: Delivery receipt shown in the chat thread.

## Phase 3: BLE link and background relay
- [x] **REQ-19**: `BleLink implements MeshTransport` with link-layer segmentation that works at ATT MTU 23.
- [ ] **REQ-20**: Dual role: advertise, scan, GATT server, and GATT client at the same time, with Android 12+ Bluetooth permissions.
- [ ] **REQ-21**: Typed foreground service (`connectedDevice`) that keeps links alive with the screen off; service builds, screen-off behavior not device-verified and BLE is not yet wired.
- [ ] **REQ-22**: BLE advertisements carry a rotating ID and no static identifier; implementation is not app-wired or device-verified.

## Phase 4: Operator controls
- [ ] **REQ-23**: Radio posture switch with per-transport definitions: Silent, Quiet, Normal; LAN is gated, BLE is not app-wired.
- [x] **REQ-24**: Panic wipe as key deletion from the keystore plus memory clear.
- [x] **REQ-25**: Relay Mode screen: black display, counters, foreground service on.

## Phase 5: Store-and-forward
- [x] **REQ-26**: One-way encryption to a roster member's static key, with its lost properties documented.
- [x] **REQ-27**: Custody envelope with expiry and copy budget; exchange of held message IDs on contact.
- [x] **REQ-28**: Memory-only envelope store with a fixed cap and expiry pruning.

## Traceability

| REQ | Phase | Plan | Status |
|-----|-------|------|--------|
| REQ-01 to REQ-04 | 1 | pre-roadmap | Done, committed and tested |
| REQ-05 | 1 | 01-01 | Done: established encrypted sends use the learned first hop; missing/failed routes flood |
| REQ-06 | 1 | 01-02 | Built, codec tests pass; app framing does not use this codec |
| REQ-07 | 1 | 01-03 | Built, resolver and epoch tests pass |
| REQ-08, REQ-09 | 1 | 01-04 | Done, committed and tested |
| REQ-10, REQ-11 | 1 | 01-05 | Done, committed and tested |
| REQ-12 | 2 | 02-01 | Implemented; device restart check NOT RUN |
| REQ-13 | 2 | 02-02 | Implemented and automated-tested; device check NOT RUN |
| REQ-14, REQ-17 | 2 | 02-02 | Implemented and automated-tested; device check NOT RUN |
| REQ-15, REQ-16 | 2 | 02-03 | Implemented and automated-tested; capture check NOT RUN |
| REQ-18 | 2 | 02-04 | Implemented and automated-tested; device check NOT RUN |
| REQ-19 | 3 | 03-01 | Built and fake-tested; real radio NOT RUN |
| REQ-20, REQ-22 | 3 | 03-00, 03-01 | Radio code exists; app wiring and hardware verification incomplete |
| REQ-21 | 3 | 04-01 | Foreground service builds; screen-off behavior NOT RUN |
| REQ-23 | 4 | 04-01 | LAN posture gates tested; BLE gate missing |
| REQ-24, REQ-25 | 4 | 04-01 | Implemented and automated-tested; device checks NOT RUN |
| REQ-26 to REQ-28 | 5 | 05-01 | Built and tested as primitives; no app contact flow |

## Status notes (2026-11-15)
- Verified in this run: `flutter test` (353 passed), `flutter analyze` (clean), format check (clean), and `flutter build apk --debug` (success).
- No Android device is attached; `flutter devices` lists Windows, Chrome and Edge. The BLE spike and all phone procedures are NOT RUN.
- BLE radio and foreground-service code compile into the APK, but the BLE radio is not attached to app startup; do not count this as dual-role or screen-off verification.
- Phase 5 Noise K and envelope/store code pass automated tests but have no app contact flow.
- Fresh Windows build and debug launch passed with MSVC 14.52 and ATL; manual provisioning and network acceptance remain NOT RUN.
