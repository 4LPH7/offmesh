# OffMesh

Offline, end-to-end encrypted messaging between stock Android phones. No internet, SIM,
server, or extra radio hardware. Built in Flutter. A Windows desktop build exists as a
LAN test peer.

This is a prototype. Read "Limits" before relying on it. The app is one talk screen:
the channel or contact name (tap it to switch), a status line, a large hold-to-talk
button and a text field. Unit setup and radio controls are in the menu.
Relay Mode and Bluetooth are Android-only.

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
2. On each phone: menu, Radio and internet, Internet mode, enter the relay as `host:7777`, Save, switch on.
   A warning appears the first time.

The relay cannot read messages, headers or names. It does see each phone's IP address,
when it is online, and message sizes. Silent and Quiet switch internet mode off. Both
phones need clocks within a few minutes (frames older than 10 minutes are refused), and
phones on either side of midnight UTC meet in different rooms until both pass it.

Channels and push-to-talk work over the relay like over Wi-Fi. Not tested on a real
mobile connection.

## Bluetooth, store-and-forward and history

- **Bluetooth (Android).** Once the phone is in a unit and Nearby devices permission is
  granted, it advertises only its hourly rotating ID, scans for unit members, and links
  to up to 6 of them over sealed GATT links, alongside Wi-Fi. Silent stops the radio and
  closes links; Quiet stops advertising and scanning but keeps open links. Tested with a
  fake radio only; the two-phone run is NOT RUN.
- **Store-and-forward.** A direct message with no receipt after 15 seconds is sealed to
  the recipient (Noise K) and handed to linked members, who carry it (at most 6 copies,
  72 hours) until one meets the recipient. Carriers cannot read it. Normal posture only;
  carried messages are held in memory and lost on restart.
- **History.** Threads (the newest 100 per conversation) are kept in the secret store
  and survive a restart. Panic wipe deletes them.
- **Relay address by QR.** Radio and internet can show the saved relay address as a QR
  code, and on Android scan one.

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
  it. A message carried by store-and-forward keeps "Sent", since its receipt is not
  carried back; a rare lost receipt can also deliver it twice. Messages held for a Quiet
  burst are not saved across a restart.
- Full-duplex voice calls are not implemented; push-to-talk is.
- **A transmitting phone can always be located by radio.** No app changes that. See
  [docs/mission_plan.md](docs/mission_plan.md) for the threat model.

## Planned

Phase 1 is complete in simulation. Phase 2 software is built; its phone/PC capture test is NOT RUN. Phase 3–5 implementation status and device gates are in [.planning/ROADMAP.md](.planning/ROADMAP.md).

1. Phase 2 device acceptance.
2. Phase 3 BLE two-phone run (the app wiring and posture gates are built).
3. Phase 4 phone acceptance, including Silent and screen-off relay behavior.
4. Phase 5 store-and-forward device run with three phones (the app wiring is built).
5. Phase 6: channels and push-to-talk voice bursts (walkie-talkie use).
6. Phase 7: internet mode through a relay that sees only sealed frames, or by direct IP.
7. Phase 8 (built): one-screen minimal UI with a large talk button.

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
2. On A, enter a name and create a unit. Open menu, Unit and members, add B's identity
   code and share the unit code. On B, enter a name, then scan or paste A's unit code.
3. In Unit and members on both phones, compare fingerprints and note "Listening on port N".
4. Beacons usually link the phones within a few seconds (the status line shows
   "1 linked"). If not, on B expand "Connect by address", enter A's IP and port, connect.
5. Tap the name at the top, pick the other phone and send a message. It shows two ticks when the
   recipient's receipt arrives.
6. Turn off mobile data to confirm nothing leaves the local network.

Multi-hop: add a third phone C to the unit, link it to B only, and message C from A.

## Manual acceptance runbooks

- [Phase 2 LAN and capture test](docs/device_tests.md): detailed; needs two phones, Wireshark and a Windows build. The Windows clean build now passes; device acceptance remains NOT RUN.
- [Phase 3 BLE spike](docs/ble_spike.md): NOT RUN; current APK lacks BLE app controls, so a diagnostic harness or BLE integration is required first.
- [Phase 4 operator tests](docs/operator_tests.md): Silent, Quiet, panic wipe, Relay Mode, and foreground-service steps; BLE posture is not testable until BLE is wired.
- [Phase 5 store-and-forward test](docs/dtn_tests.md): detailed but blocked until the app owns and exchanges custody envelopes.
