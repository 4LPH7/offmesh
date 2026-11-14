# OffMesh

Offline, end-to-end encrypted messaging between stock Android phones. No internet, SIM,
server, or extra radio hardware. Built in Flutter. A Windows desktop build exists as a
LAN test peer.

This is a prototype. Read "Limits" before relying on it.

## Implemented

Works today over Wi-Fi or a phone hotspot:

- **Encrypted chat.** `Noise_XX_25519_ChaChaPoly_SHA256` session per pair of peers,
  checked against a published test vector. The responder's key is checked against the
  dialled ID before the initiator reveals its own.
- **Multi-hop relaying.** Flood routing with duplicate drop, per-link flood suppression,
  TTL of 7, and jittered relays. Relays forward ciphertext they cannot read.
- **Fragmentation** of messages larger than one 220-byte packet.
- **Lossy links tolerated.** Each transport frame carries an explicit counter checked
  against a replay window, so lost or reordered frames do not break a session.
- **Delivery receipts.** The recipient answers each message with an end-to-end encrypted
  receipt. A sent message shows one tick, then two once its receipt arrives.
- **Persistent identity** in the Android Keystore-backed store (Windows: a DPAPI-encrypted
  file).
- **Unit roster.** One phone creates a unit; others join by showing their identity code
  (QR or text) to a member, who adds it and shares the unit code back. Every member and
  this phone show a key fingerprint to compare in person. Messages from phones outside
  the roster are dropped.
- **Sealed LAN.** Every TCP frame, the link hello and the UDP beacon (port 47999) are
  encrypted under the unit's seal key. Peers identify themselves only by an hourly
  rotating ID inside the seal; static IDs and packet headers never leave a phone in
  cleartext. Each link starts with a challenge from both sides, and the hello must echo
  it, so a hello copied from another connection is refused. A phone without the unit key,
  or outside the roster, cannot link. A link that goes silent for 30 seconds is closed
  (healthy links send keepalives). Manual IP:port connect is still available.

Built and tested, but not yet used by the running app: a reverse-path table for unicast
return traffic (`MeshRouter.originateTo`). Receipts are flooded instead.

## Limits

- **New phone, new identity.** The identity store is excluded from backup, so a new or
  restored phone must rejoin the unit.
- **The roster is unsigned.** Anyone holding the unit code is trusted as a member, and can
  claim another member's link slot until the real member links again (the newer link
  wins). Message content stays protected by the per-pair Noise sessions. Show the unit
  code only to members, in person.
- **No epoch key chain.** The seal key lasts the unit's lifetime, so a leaked unit code
  opens the headers of all recorded LAN traffic.
- **Replay window.** A recorded sealed beacon opens for up to 10 minutes. A phone ignores
  a copy of a beacon it has already seen, but one it missed can still trigger a dial, and
  a failed dial pauses beacon dials to that member for 3 seconds.
- **Relays.** If someone gets a member to dial them (a replayed beacon, or a typed
  address), they can pass that member's link through to another member. They see only
  sealed frames, but they can drop or delay them.
- Frame lengths and timing stay visible on the wire.
- **"Delivered" means the recipient's phone decrypted the message**, not that anyone read
  it. Messages and their marks are memory-only and are lost on restart; there is no resend.
- **No Bluetooth, no voice, no store-and-forward.**
- **A transmitting phone can always be located by radio.** No app changes that. See
  [docs/mission_plan.md](docs/mission_plan.md) for the threat model.

## Planned

Five phases; details, success criteria, and device tests are in
[.planning/ROADMAP.md](.planning/ROADMAP.md).

1. Protocol core close-out: key schedule, replay freshness, decoder fuzzing.
2. Sealed LAN chat on real devices: persistent identity, roster by QR, no static IDs on the wire.
3. BLE link and background relay.
4. Operator controls: radio posture switch, panic wipe, Relay Mode.
5. Store-and-forward for offline recipients.

Not planned: voice calls, live push-to-talk, Wi-Fi Direct, mDNS, iOS, external radios.

## Build and test

```bash
flutter pub get
flutter test
flutter analyze
flutter run -d windows
flutter build apk --debug
```

The APK is written to `build/app/outputs/flutter-apk/app-debug.apk`.

## Two-phone test

1. Phone A turns on a Wi-Fi hotspot. Phone B joins it.
2. On A, create a unit. On B, show B's identity code; on A, use Add member to scan or
   paste it, then Share unit. On B, scan or paste A's unit code to join.
3. Compare the fingerprints shown on both phones. Each shows "Listening on port N".
4. Beacons usually link the phones within a few seconds. If not, on B enter A's IP and
   port, then Connect.
5. Select A on B and send a message. It shows two ticks when A's receipt arrives. Reply
   from A.
6. Turn off mobile data to confirm nothing leaves the local network.

Multi-hop: add a third phone C to the unit, link it to B only, and message C from A.
