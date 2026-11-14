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
- **Multi-hop relaying.** Flood routing with duplicate drop, TTL of 7, and jittered
  relays. Relays forward ciphertext they cannot read.
- **Fragmentation** of messages larger than one 220-byte packet.
- **LAN links.** Framed TCP, discovery by UDP beacon on port 47999, manual IP:port connect.
- **One screen.** My ID, connect, add a contact by pasting their ID, chat.

Built and tested, but not yet used by the running app (uncommitted):

- Per-link flood suppression and a reverse-path table.
- Sealed envelope: whole frames encrypted under a shared unit key.
- Rotating hourly discovery IDs with a roster resolver.
- Delivery receipts, and a transport counter with a replay window so lost or reordered
  frames no longer break a session.

## Limits

- **Identity is not persistent.** A new key is generated on every launch. Nothing is
  stored in the Android Keystore yet.
- **No key verification.** A contact is trusted by pasting their ID. There is no QR scan
  or fingerprint check yet.
- **Identities are visible on the LAN.** The beacon and link hello send a static ID in
  cleartext, and packet headers are not sealed yet.
- **Messages are memory-only** and are lost on restart.
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
2. Open the app on both. Each shows its ID and "Listening on port N".
3. Beacons usually link the phones within a few seconds. If not, on B enter A's IP and
   port, then Connect.
4. Copy A's ID into B's contact field and send a message. Reply from A.
5. Turn off mobile data to confirm nothing leaves the local network.

Multi-hop: add a third phone C linked to B only, and message C from A using C's ID.
