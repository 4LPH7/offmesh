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
- [ ] **REQ-05**: Per-link flood suppression: a relay is skipped on any link that already delivered the same packet during the jitter window. Reverse-path table used for the originator's first hop.
- [ ] **REQ-06**: Sealed envelope codec: whole frame encrypted under a 32-byte key with ChaCha20-Poly1305, random nonce, domain label.
- [ ] **REQ-07**: Rotating 8-byte discovery IDs from HMAC-SHA256 over public key and hourly epoch, with a roster resolver covering the previous, current, and next epoch.
- [x] **REQ-08**: End-to-end delivery receipt carried as a Noise transport message; never acknowledged itself.
- [x] **REQ-09**: Explicit transport counter and replay window so lost or reordered frames do not break a session.
- [ ] **REQ-10**: Key schedule and freshness: seal key and ID key derived separately from the unit secret with HKDF; a timestamp inside the seal bounds replay of recorded frames.
- [ ] **REQ-11**: Seeded fuzz test over every decoder (packet, sealed envelope, reassembly, receipt): 100,000 mutated inputs, no unhandled exception.

## Phase 2: Sealed LAN chat on real devices
- [ ] **REQ-12**: Persistent identity: static key created once and stored through the platform keystore.
- [ ] **REQ-13**: Unit secret and roster stored at rest through the same store; app refuses to link when unprovisioned.
- [ ] **REQ-14**: Roster provisioning by one static QR code (Windows: paste or file).
- [ ] **REQ-15**: Every LAN frame sealed, including the link hello and the UDP beacon.
- [ ] **REQ-16**: No static identifier on the wire: beacon and hello carry rotating IDs; static PeerIDs appear only inside sealed frames.
- [ ] **REQ-17**: Key fingerprint shown per contact for comparison by eye.
- [ ] **REQ-18**: Delivery receipt shown in the chat thread.

## Phase 3: BLE link and background relay
- [ ] **REQ-19**: `BleLink implements MeshTransport` with link-layer segmentation that works at ATT MTU 23.
- [ ] **REQ-20**: Dual role: advertise, scan, GATT server, and GATT client at the same time, with Android 12+ Bluetooth permissions.
- [ ] **REQ-21**: Typed foreground service (`connectedDevice`) that keeps links alive with the screen off.
- [ ] **REQ-22**: BLE advertisements carry a rotating ID and no static identifier.

## Phase 4: Operator controls
- [ ] **REQ-23**: Radio posture switch with per-transport definitions: Silent, Quiet, Normal.
- [ ] **REQ-24**: Panic wipe as key deletion from the keystore plus memory clear.
- [ ] **REQ-25**: Relay Mode screen: black display, counters, foreground service on.

## Phase 5: Store-and-forward
- [ ] **REQ-26**: One-way encryption to a roster member's static key, with its lost properties documented.
- [ ] **REQ-27**: Custody envelope with expiry and copy budget; exchange of held message IDs on contact.
- [ ] **REQ-28**: Memory-only envelope store with a fixed cap and expiry pruning.

## Traceability

| REQ | Phase | Plan | Status |
|-----|-------|------|--------|
| REQ-01 to REQ-04 | 1 | (pre-roadmap) | Done, committed |
| REQ-05 | 1 | 01-01 | Built (5534f72); suppression live, reverse path unused by the app |
| REQ-06 | 1 | 01-02 | Built (5534f72), not wired |
| REQ-07 | 1 | 01-03 | Built (5534f72), not wired |
| REQ-08, REQ-09 | 1 | 01-04 | Done, committed (5534f72) |
| REQ-10, REQ-11 | 1 | 01-05 | Not started |
| REQ-12, REQ-13 | 2 | 02-01 | Not started |
| REQ-14, REQ-17 | 2 | 02-02 | Not started |
| REQ-15, REQ-16 | 2 | 02-03 | Not started |
| REQ-18 | 2 | 02-04 | Not started |
| REQ-19 to REQ-22 | 3 | 03-00 spike first | Not started |
| REQ-23 to REQ-25 | 4 | TBD | Not started |
| REQ-26 to REQ-28 | 5 | TBD | Not started |
