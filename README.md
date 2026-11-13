# OffMesh v0.1 (test build)

Offline, end-to-end encrypted messaging over phone-to-phone links. No internet, SIM or server.
Based on the "Decentralized Offline Voice and Mesh Communication" whitepaper, Tiers 1 and 2 only.

## What works in v0.1

- Noise XX handshake (`Noise_XX_25519_ChaChaPoly_SHA256`) checked against the published
  cacophony test vector. The responder's identity is checked before the initiator reveals its own key.
- Mesh routing by flooding, with duplicate suppression, TTL, and jittered relays.
  Relays forward ciphertext they cannot read (tested).
- Multi-hop encrypted messages with fragmentation for payloads up to ~56 KB.
- LAN links over Wi-Fi or a phone hotspot: TCP with framed packets, UDP beacons for discovery,
  manual IP:port connect.
- A single screen: my ID, connect, add contact by ID, chat.

## Architecture & Module Organization

OffMesh is structured into decoupled core layers:

- **Crypto (`lib/core/crypto/`)**: Noise XX (`Noise_XX_25519_ChaChaPoly_SHA256`) state machine and static key management with mutual authentication.
- **Protocol (`lib/core/protocol/`)**: 26-byte binary packet header codec, message fragmentation / reassembly (up to ~56 KB payload), and seen cache for flood deduplication.
- **Mesh (`lib/core/mesh/`)**: Mesh router implementing TTL-bounded flooding, relay jitter, loop suppression, and per-peer transmission queues.
- **Transports (`lib/transports/`)**: Length-prefixed TCP socket framing, UDP beacon broadcast discovery on port 47999, and connection lifecycle management.
- **App & UI (`lib/app/`, `lib/ui/`)**: State controllers, contact threading, and responsive Flutter interface.

## Not in v0.1

- Bluetooth mesh (Tier 2 radio). The router is ready for it; no BLE transport yet.
- Voice calls, LoRa, HF.
- Persistent identity and message history: both live in memory and reset on app restart.
- Out-of-order transport messages: a message that arrives after a later one on the same
  session is dropped (Noise's implicit nonce). Fine on a single hop; to be fixed in v0.2.
- Key verification (QR/safety numbers). Contacts are trusted by pasting their ID.
- Simultaneous duplicate TCP links can briefly drop both; beacons reconnect within a few seconds.

## Run the tests

```bash
flutter test
flutter analyze
```

## Build for phones

```bash
flutter build apk --debug
```

Install `build/app/outputs/flutter-apk/app-debug.apk` on Android phones.

## Two-phone test

1. Phone A turns on a Wi-Fi hotspot. Phone B joins it.
2. Open the app on both. Each shows its ID and "Listening on port N".
3. On B, enter A's IP (usually `192.168.43.1`) and port, then Connect. Beacons usually link them automatically.
4. Copy A's ID, paste it into B's contact field, and send a message. Then reply from A.
5. Turn off mobile data and Wi-Fi internet to confirm nothing leaves the local network.

For multi-hop: add a third phone C linked to B only, and message C from A using C's ID.
A's message must pass through B.
