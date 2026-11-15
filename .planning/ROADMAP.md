# Roadmap: OffMesh

## Overview

OffMesh is an offline, end-to-end encrypted messenger for a small pre-provisioned group
("unit") of stock Android phones. It aims to keep message content and identities private
from anyone without the unit's keys, to keep radio emissions short and under operator
control, and to limit what a captured phone gives away. See `docs/mission_plan.md` for the
threat model and the limits.

Eight phases. Each ends with one device test that can be run with two Android phones and a
Windows PC. Requirement IDs match `REQUIREMENTS.md`, which is the single source.

## Phases

- [x] **Phase 1: Protocol core** - Codecs, router, sealing, rotating IDs, receipts, key schedule, freshness, fuzzing. Built and tested in simulation.
- [ ] **Phase 2: Sealed LAN chat on real devices** - The app uses what Phase 1 built: persistent identity, roster, sealed links, no static IDs on the wire.
- [ ] **Phase 3: BLE link and background relay** - A BLE transport behind the existing `MeshTransport` interface, kept alive by a foreground service.
- [ ] **Phase 4: Operator controls** - Radio posture switch, panic wipe, Relay Mode screen.
- [ ] **Phase 5: Store-and-forward** - Messages for an offline recipient are carried by other phones.
- [ ] **Phase 6: Channels and push-to-talk** - Unit channels for group text and hold-to-talk voice bursts over LAN.
- [ ] **Phase 7: Internet mode** - Members reach each other over the internet through a relay that sees only sealed frames, or by direct IP.
- [ ] **Phase 8: Minimal UI** - One talk screen with a large push-to-talk button; everything else one tap away.

## Phase Details

### Phase 1: Protocol core
**Goal**: A pure-Dart protocol whose frames, once sealed, reveal nothing to an observer without the unit key, proven in simulation.
**Depends on**: Nothing
**Requirements**: REQ-01 to REQ-11
**Status**: Complete. All five plans implemented and tested. Current full suite passes 353 tests. Established encrypted sends use the learned reverse path; sealing and rotating IDs are wired into the app in Phase 2.
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
- [x] 01-01: Reverse-path table and per-link flood suppression (MeshNode uses `originateTo` for established encrypted sends; relays and initial handshakes still flood)
- [x] 01-02: Sealed envelope codec (as built: codec only, not wired)
- [x] 01-03: Rotating IDs and roster resolver (as built: codec and resolver only, not wired)
- [x] 01-04: Delivery receipts, explicit transport counter with replay window, 10-node simulator
- [x] 01-05: Key schedule (HKDF separation), freshness timestamp inside the seal, decoder fuzz test (as built: epoch key chain left as an open decision)

### Phase 2: Sealed LAN chat on real devices
**Goal**: Two phones and a PC chat over a hotspot with every frame sealed and no stable identifier visible to a packet capture.
**Depends on**: Phase 1
**Requirements**: REQ-12 to REQ-18
**Status**: App implementation and automated checks complete. Messages, Unit and Controls use focused tabs; Android-only Relay Mode and the unwired BLE status are explicit. APK rebuild, fresh Windows build and debug launch passed on 2026-11-15. The two-phone/PC capture and all on-device acceptance remain NOT RUN because no Android device is attached.
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
- [x] 02-02: Roster format, QR export and import, fingerprint display
- [x] 02-03: Sealed link wrapper for `LanLink`; sealed beacon and hello with rotating IDs
- [x] 02-04: Receipts shown in the chat thread; README updated for what Phase 2 ships
- [x] 02-05: Device test and capture checklist written (execution NOT RUN)

### Phase 3: BLE link and background relay
**Goal**: Two pocketed phones exchange messages over Bluetooth with the screen off, and a third device on LAN is reached through one of them.
**Depends on**: Phase 2
**Requirements**: REQ-19 to REQ-22
**Status**: BLE codec, link and Android radio code are built and fake-tested, but still provisional. The 03-00 phone spike is NOT RUN; the radio is not attached to app startup, and BLE posture gating is absent.
**Success Criteria** (what must be TRUE):
  1. `BleLink implements MeshTransport`; a 512-byte sealed frame crosses a BLE link byte-identical at the negotiated ATT MTU and at a forced MTU of 23 (link segmentation exists and is tested).
  2. Each phone advertises, scans, serves GATT, and connects as a client at the same time.
  3. A `connectedDevice` foreground service keeps the link working for 30 minutes with the screen off.
  4. BLE advertisements carry a rotating ID and no static identifier.
  5. LAN-to-BLE bridging works with no router change.
**Device test**: Phones A and B in airplane mode with Bluetooth on, screens off, exchange 100 messages in 30 minutes with at least 95 delivered. Then B joins the PC's LAN and a message from A reaches the PC through B.
**Plans**: starts with a spike

Plans:
- [ ] 03-00: Spike, two days, throwaway code: dual-role BLE on the two real phones, 1000 writes of 200 bytes, 30 minutes screen-off. Output: go or no-go on plugin versus platform channel, observed MTU, service survival. NOT RUN.
- [x] 03-01: Provisional BLE link, Android radio and fake-backed tests implemented before spike results; no hardware claim. App peer management and BLE posture gating remain.

### Phase 4: Operator controls
**Goal**: The operator controls when the phone transmits and can destroy its keys at once.
**Depends on**: Phase 3 (posture cannot be defined before BLE behaviour is known)
**Requirements**: REQ-23 to REQ-25
**Status**: Operator UI, LAN posture controls, panic wipe, Relay Mode and Android foreground-service plumbing are implemented and automated-tested. BLE posture is not wired; phone checks are NOT RUN.
**Success Criteria** (what must be TRUE):
  1. Silent: no sockets open, no UDP sent, no BLE advertising, all connections dropped, passive scan only.
  2. Quiet: no beacons or advertisements; outgoing messages queue until the operator presses a send-burst button.
  3. Panic wipe deletes the identity key, unit secret, and roster from the keystore and clears memory; the app restarts unprovisioned.
  4. Relay Mode shows a black screen with link and forward counters and keeps the foreground service running.
**Device test**: With phone B in Silent for 5 minutes, the PC capture and a BLE scanner app on phone A show nothing from B. After panic wipe on B, B cannot link and A cannot resolve B's new ID.
**Plans**: 1 plan

Plans:
- [x] 04-01: Operator controls and Relay Mode implementation; hardware checks remain NOT RUN.

### Phase 5: Store-and-forward
**Goal**: A message for an offline recipient is delivered later by a phone that met both parties.
**Depends on**: Phase 3, Phase 4
**Requirements**: REQ-26 to REQ-28
**Status**: One-way Noise K, custody envelope codecs and bounded memory store are implemented and tested as primitives. No app flow owns or exchanges envelopes; the device test is NOT RUN.
**Success Criteria** (what must be TRUE):
  1. A message can be encrypted to a roster member's static key without an interactive handshake (one-way mode); the lost properties are documented.
  2. An envelope carries an expiry and a copy budget; carriers exchange lists of held message IDs on contact.
  3. The store is memory-only with a fixed envelope cap; expired envelopes are dropped.
**Device test**: Phone A sends to the PC while the PC is off the network. Phone B meets A over BLE, then joins the PC's LAN. The PC receives the message once.
**Plans**: 1 plan

Plans:
- [x] 05-01: One-way encryption and custody/store primitives; app integration is outside this plan and remains undone.

### Phase 6: Channels and push-to-talk
**Goal**: A unit talks like a walkie-talkie: pick a channel, hold a button, everyone on the channel hears it.
**Depends on**: Phase 2 (sealed LAN). Runs on LAN first; BLE and internet carry it once those links are wired.
**Requirements**: REQ-29 to REQ-33
**Decision reversed**: push-to-talk was "Not planned" because continuous transmission conflicts with emission control. It returns as short bursts under operator control, blocked in Silent and held in Quiet.
**Success Criteria** (what must be TRUE):
  1. A channel is a name plus a key derived from the unit secret; members on the same channel name decrypt each other, others in the unit do not.
  2. Text sent to a channel reaches every linked member on it, once, with no per-member handshake.
  3. Holding the talk button records and sends voice in frames; releasing ends the burst. A listener hears it with under one second of delay on LAN.
  4. Only one speaker is played at a time per channel; a second speaker is shown as busy.
  5. Silent blocks talk and channel sends; Quiet holds text and refuses voice.
  6. A burst is capped (default 30 seconds) and the cap is shown as a countdown.
**Device test**: Three devices on one hotspot, same channel. Each speaks a 5-second burst in turn; the other two hear it. A device on another channel hears nothing.
**Plans**: starts with a spike

Plans:
- [ ] 06-00: Spike, one day: record and play Opus (or the platform codec) on Android and Windows through one plugin; measure frame size and latency. Output: codec and plugin choice.
- [ ] 06-01: Channel keys (HKDF from unit secret and channel name), broadcast packet type sealed under the channel key, replay window per sender, group text.
- [ ] 06-02: Voice burst framing (start, frames, end), jitter buffer, single-speaker rule, burst cap.
- [ ] 06-03: Posture gates, roger beep, last-heard indicator.

### Phase 7: Internet mode
**Goal**: Two members in different places talk and text when both have internet, with the same keys and no accounts.
**Depends on**: Phase 6
**Requirements**: REQ-34 to REQ-37
**Honest limits**: internet mode gives up the "no infrastructure" property while it is on. The relay learns each member's IP address, when they are online, and frame sizes. It cannot read content, headers, or identities. It is off by default and Silent turns it off.
**Success Criteria** (what must be TRUE):
  1. A small relay server forwards sealed frames between connections that present the same rendezvous ID; it stores nothing and needs no accounts.
  2. The rendezvous ID is derived from the unit secret and rotates daily, so the relay cannot link a unit across days by ID.
  3. The app connects to a relay by address (IP or hostname and port) typed or scanned once; the link is a normal `MeshTransport`, sealed and roster-checked like LAN.
  4. Direct mode: a member with a reachable address accepts a link from another member by IP and port (already works on LAN; documented for port forwarding or a VPN).
  5. Internet mode is a visible switch, off by default, off in Silent, and shows a warning the first time.
  6. A relay that drops, replays, or reorders frames cannot make a node accept a forged message.
**Device test**: Phone A on mobile data and the PC on home Wi-Fi, both pointed at a relay running on a third machine. Text both ways and one voice burst each way. A capture at the relay shows no readable header or identifier.
**Plans**: 3 plans

Plans:
- [ ] 07-01: Relay server (single Dart file, WebSocket or TCP), rendezvous ID derivation, rate limits, run instructions.
- [ ] 07-02: `RelayLink implements MeshTransport` over the existing sealed link; reconnect with backoff.
- [ ] 07-03: Internet switch, relay address entry and QR, first-use warning, posture gates.

### Phase 8: Minimal UI
**Goal**: A new user talks within one minute, with one hand.
**Depends on**: Phase 6 (talk button needs voice)
**Requirements**: REQ-38 to REQ-40
**Success Criteria** (what must be TRUE):
  1. Home is one screen: channel or contact name, link status in one line, a large hold-to-talk button, and a text field. Nothing else.
  2. Channels, members, posture, internet mode, relay, and wipe live behind one menu, at most two taps from home.
  3. Status uses words and one colour dot (Linked, Searching, Silent, Internet); no codes or port numbers on the home screen.
  4. Touch targets are at least 48 dp, text scales with the system font size, and every control has a screen-reader label.
  5. First run is three steps: name, create or join, done.
**Device test**: A person who has not seen the app joins a unit by QR and sends a voice burst in under one minute, unaided.
**Plans**: 2 plans

Plans:
- [ ] 08-01: Talk screen and navigation; move port, fingerprint, and connect details to a details page.
- [ ] 08-02: First-run flow, accessibility pass, empty and error states.

## Suggested additions (not scheduled)

Small features that fit the design; each needs a go-ahead before it becomes a requirement.

- Voice notes: record, send as an ordinary message, play later. Reuses Phase 6 recording.
- Quick replies: six preset one-tap messages (OK, Wait, Come here, ...). Cheap and useful with gloves.
- Last heard: per member, how long since their last frame.
- SOS: one long-press sends a high-priority channel message with an alarm sound.
- Location share: opt-in, one-shot, sent as a message; never continuous.
- Resend: a message with no receipt after a timeout offers a resend.
- Message history on disk: opt-in, encrypted; conflicts with the memory-only default, so off by default.

## Not planned

Cut or parked so they stop reappearing. Each needs a stated reason to return.

- mDNS discovery: the UDP beacon already works and mDNS adds a cleartext service name.
- Animated multi-frame QR, in-app APK sharing, duress PIN.
- Brevity codes (see quick replies under Suggested additions), scheduled transmit windows, clock sync.
- Cellular interlock beyond a warning banner (apps cannot switch the cellular radio off).
- Wi-Fi Direct and Wi-Fi Aware, until a hotspot is shown to be insufficient.
- WebRTC calls and full-duplex voice. Push-to-talk bursts and channels moved to Phase 6. Codec2 for BLE voice stays parked until BLE links are verified on phones.
- Coded PHY as a requirement (opportunistic use only), reproducible builds, RF audit with radio test gear.
- Relay-side unicast forwarding and a seal-only relay key tier (see Open decisions).
- iOS.

## Open decisions

1. **Relay key tier.** A sealed header means a relay must hold the seal key. In v1 a relay is a full unit member, so an unattended relay phone holds the unit secret and roster. A seal-only tier would reduce that. Current Relay Mode uses the full-member model; revisit before distributing unattended relays or changing the trust model.
2. **Epoch key chain.** Deriving seal keys from a hash chain and deleting old links would stop a captured phone from opening earlier recorded traffic. This was not decided before 02-03 as planned. Record a decision before adding key rotation or claiming past-traffic protection; a chain needs loosely synced clocks.
3. **TTL.** Code is 7. Revisit only after Phase 3 range measurements; changing it needs a protocol version bump.
4. **Relay-side unicast.** `docs/relay_mode.md` proposes it. Deferred until route entries are derived from sealed, authenticated traffic; revisit before implementing relay-side unicast.

## Progress

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Protocol core | 5/5 | Complete; simulator validation pass | 2026-11-14 |
| 2. Sealed LAN chat | 5/5 | Software and test procedure complete; phone/PC test NOT RUN | - |
| 3. BLE link and relay | 1/2 | Provisional link/radio built; spike NOT RUN; app wiring incomplete | - |
| 4. Operator controls | 1/1 | Software built; BLE posture and device checks open | - |
| 5. Store-and-forward | 1/1 | Primitives built; app integration and device test open | - |
| 6. Channels and push-to-talk | 0/4 | Not started | - |
| 7. Internet mode | 0/3 | Not started | - |
| 8. Minimal UI | 0/2 | Not started | - |
