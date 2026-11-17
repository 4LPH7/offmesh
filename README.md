# OffMesh

Offline, end-to-end encrypted messaging between stock Android phones. No internet, SIM,
server, or extra radio hardware. Built in Flutter. A Windows desktop build exists as a
LAN test peer.

This is a prototype. Read "Limits" before relying on it. The app keeps messages,
unit setup, and radio controls on separate tabs so the main chat stays focused.
Relay Mode is Android-only; Bluetooth and store-and-forward are not connected to chat yet.

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

The reverse-path table now routes established encrypted messages over a learned first hop; handshakes without a route and receipts still flood. The router floods if the route is unknown or its send fails.

## Internet mode and the relay

Off by default. For members who are not on the same network:

1. On a machine both can reach (a small server, or a PC with a forwarded port), run
   `dart run bin/relay.dart --port 7777`. It forwards sealed frames and stores nothing.
2. On each phone: Controls, Internet mode, enter the relay as `host:7777`, Save, switch on.
   A warning appears the first time.

The relay cannot read messages, headers or names. It does see each phone's IP address,
when it is online, and message sizes. Silent and Quiet switch internet mode off. Both
phones need clocks within a few minutes (frames older than 10 minutes are refused), and
phones on either side of midnight UTC meet in different rooms until both pass it.

Channels and push-to-talk work over the relay like over Wi-Fi. Not tested on a real
mobile connection.

## Prototypes not connected to chat

- **Bluetooth:** the BLE codec, link, and Android radio are built and fake-tested; app discovery/peer management and posture gating are not wired. The two-phone spike is NOT RUN.
- **Store-and-forward:** Noise K, custody envelopes, and the bounded memory store are built and tested; the app does not own or exchange them yet.

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
- **No BLE or store-and-forward messaging in the running app yet.** Their code components are not connected to contacts and message flow. Voice calls are not implemented.
- **A transmitting phone can always be located by radio.** No app changes that. See
  [docs/mission_plan.md](docs/mission_plan.md) for the threat model.

## Planned

Phase 1 is complete in simulation. Phase 2 software is built; its phone/PC capture test is NOT RUN. Phase 3–5 implementation status and device gates are in [.planning/ROADMAP.md](.planning/ROADMAP.md).

1. Phase 2 device acceptance.
2. Phase 3 BLE spike, then app wiring and radio posture gates.
3. Phase 4 phone acceptance, including Silent and screen-off relay behavior.
4. Phase 5 app integration and store-and-forward device acceptance.
5. Phase 6: channels and push-to-talk voice bursts (walkie-talkie use).
6. Phase 7: internet mode through a relay that sees only sealed frames, or by direct IP.
7. Phase 8: one-screen minimal UI with a large talk button.

Not planned: full-duplex voice calls, Wi-Fi Direct, mDNS, iOS, external radios.

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
2. On A, create a unit. Open the Unit tab, add B's identity code and share the unit
   code. On B, scan or paste A's unit code to join.
3. In the Unit tab on both phones, compare fingerprints and note "Listening on port N".
4. Beacons usually link the phones within a few seconds. If not, on B open Unit, expand
   "Connect by address", enter A's IP and port, then connect.
5. Open Messages, select the other phone and send a message. It shows two ticks when the
   recipient's receipt arrives.
6. Turn off mobile data to confirm nothing leaves the local network.

Multi-hop: add a third phone C to the unit, link it to B only, and message C from A.

## Manual acceptance runbooks

- [Phase 2 LAN and capture test](docs/device_tests.md): detailed; needs two phones, Wireshark and a Windows build. The Windows clean build now passes; device acceptance remains NOT RUN.
- [Phase 3 BLE spike](docs/ble_spike.md): NOT RUN; current APK lacks BLE app controls, so a diagnostic harness or BLE integration is required first.
- [Phase 4 operator tests](docs/operator_tests.md): Silent, Quiet, panic wipe, Relay Mode, and foreground-service steps; BLE posture is not testable until BLE is wired.
- [Phase 5 store-and-forward test](docs/dtn_tests.md): detailed but blocked until the app owns and exchanges custody envelopes.
