# OffMesh Mission Plan

This document holds the threat model, the limits, and the design decisions.
Phases, success criteria, and status live in `.planning/ROADMAP.md` and
`.planning/REQUIREMENTS.md`; this document does not repeat them.

## 1. The honest limit

No app makes a radio transmitter invisible. A receiver with a directional antenna can
detect and locate any phone that transmits, whatever the software does. Range depends on
power, terrain, and the receiver; this project has not measured it and quotes no figures
until Phase 3 measures them on real phones.

What the app can do:

1. **Make captured traffic worthless without keys.** Content is end-to-end encrypted, and
   whole frames are sealed so an outsider sees no header, sender, or recipient.
2. **Keep emissions short and under operator control.** The operator chooses when the
   phone transmits.
3. **Limit what a captured phone gives away.** Messages are memory-only, and a wipe
   deletes the keys.

## 2. Threat model

| Adversary | Can do | OffMesh aims to | Does not defend |
|-----------|--------|-----------------|-----------------|
| Outside listener, no keys | Record every frame, replay frames, measure timing and size, locate transmitters | Hide content, headers, and identities; reject stale replays | Being detected or located; traffic volume and timing; radio fingerprinting; link-layer addresses the OS controls |
| Captured phone, locked, wiped in time | Read flash storage | Leave no keys and no messages | Nothing recoverable is claimed, but flash erase is only as good as the keystore's key deletion |
| Captured phone, unlocked or not wiped | Read unit secret, roster, identity key, live sessions | Limit to that phone's sessions and the unit's metadata until the unit is rekeyed | Past sealed traffic recorded by the adversary becomes readable at the header level (see 4.3); impersonation of that member until rekey |
| Malicious or compromised unit member | Everything a member can | Keep other members' message content private (Noise sessions are pairwise) | Metadata inside the unit; flooding; false routes |

Earlier drafts said "zero-yield", "HMAC ratchet", and "observers cannot link
transmissions to nodes". All three overstated the design and are withdrawn.

## 3. What was learned from other systems

- **Reticulum**: no source address on the wire, and a network key can mask whole packets.
  OffMesh seals whole frames under a unit key.
- **BitChat**: identifiers that rotate so observers cannot follow a device. OffMesh rotates
  the identifiers that must appear outside the seal.
- **Meshtastic**: managed flooding outlasts smarter routing on mobile nodes. Its relay
  cancel assumes a shared radio channel. OffMesh links are point-to-point, so it skips a
  relay per link instead.
- **Briar, Berty**: store-and-forward carries messages across a partitioned network.
  OffMesh plans a small version in Phase 5.

## 4. Design decisions

### 4.1 Layers

1. **Noise XX session** between two members: content confidentiality and authentication.
   Transport frames carry an explicit counter with a replay window, so loss and reordering
   do not break a session.
2. **Packet**: 26-byte header (type, TTL up to 7, packet ID, sender, recipient, fragment
   fields) plus up to 220 bytes of payload.
3. **Seal**: the whole packet encrypted with ChaCha20-Poly1305 under a key derived from
   the unit secret. Applied per link; a relay opens and re-seals.
4. **Link**: LAN TCP today, BLE in Phase 3.

### 4.2 Identifiers

- Inside the seal, packets use static 8-byte PeerIDs (hash of the public key). Sessions,
  queues, and routes are keyed by them.
- Outside the seal, on discovery surfaces only (UDP beacon, link hello, BLE
  advertisement), a member shows a rotating ID: HMAC-SHA256 over its public key and the
  hour, truncated to 8 bytes. Roster holders resolve it for the previous, current, and
  next hour. This is a keyed function of the hour, not a ratchet: anyone who obtains the
  ID key can compute every hour, past and future.

### 4.3 Keys

- **Unit secret**: shared by all members, provisioned before deployment. Seal key and ID
  key are derived from it separately with HKDF-SHA256 (`UnitKeys`, labels
  `offmesh/seal/v1` and `offmesh/id/v1`).
- **Identity key**: one X25519 key per phone, created once, stored through the platform
  keystore (Phase 2). Today it is regenerated on every launch.
- **Capture consequence**: a phone captured before a wipe yields the unit secret. With it,
  headers of traffic recorded earlier can be opened. Message content stays protected by
  the pairwise Noise sessions. An epoch key chain with deletion would close the header gap
  and is an open decision in the roadmap.
- **Rekey and revocation**: not designed yet. Until it is, losing one phone means
  re-provisioning the unit in person.

### 4.4 Replay

The seen cache forgets a packet after 300 seconds. Without a freshness check, an outsider
could replay a recorded sealed frame later and make every relay flood it again. Each sealed
frame carries the sender's clock (Unix seconds) inside the ciphertext, and a frame more
than 10 minutes from the receiver's clock is rejected. Phone clocks must agree within that
window; it is wide because phones drift without network time. A replay inside the window
is still caught by the seen cache for its first 300 seconds; the remaining gap (300 s to
10 min) would need a per-link nonce cache, which is not built.

### 4.5 Relays

A relay never holds Noise session keys, so it never reads content. Because the header is
sealed, a relay must hold the seal key to forward. In v1 a relay is a full unit member. An
unattended relay phone is therefore the easiest device to capture and holds the unit
secret. A seal-only relay key tier is an open decision.

### 4.6 Radio posture

Defined per transport in Phase 4, once BLE behaviour is measured:

- **Silent**: nothing transmitted. No sockets, no UDP, no advertising, connections
  dropped. Scanning is passive only. A TCP or BLE connection always emits at link level,
  so Silent means no connections at all.
- **Quiet**: no beacons or advertisements. Outgoing messages wait for the operator's
  send-burst button.
- **Normal**: discovery and relaying run.

### 4.7 Android constraints to verify by spike

These came from research and are not yet confirmed on the project's phones. Phase 3
starts with a spike that measures them.

- Whether both phones can advertise, scan, serve GATT, and connect at once.
- The ATT MTU the phones negotiate. A sealed frame (26-byte header, 32-byte seal overhead,
  payload) does not fit the 20-byte payload of the default MTU, so link segmentation is
  required either way.
- Whether a `connectedDevice` foreground service keeps BLE alive with the screen off.
- Coded PHY support. It is used only if both ends offer it; nothing depends on it.

## 5. What is deliberately absent

See "Not planned" in `.planning/ROADMAP.md`. In short: no voice calls, no live
push-to-talk, no Wi-Fi Direct, no mDNS, no duress PIN, no scheduled transmit windows, no
iOS, and no claim of protection against a located transmitter.
