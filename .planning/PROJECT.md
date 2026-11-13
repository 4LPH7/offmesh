# OffMesh

## What This Is

100% Smartphone-Native Offline Encrypted Mesh Messenger & Voice Communicator. Built in Flutter for Android (with Windows Desktop support for testing), it enables end-to-end encrypted messaging, Push-to-Talk (PTT) voice bursts, and full-duplex voice calls directly between standard smartphones without internet, SIM recharge, central servers, or external radio hardware.

## Core Value

Zero-infrastructure, phone-to-phone private communication combining local high-speed P2P links with multi-hop BLE 5.0 mesh and delay-tolerant store-and-forward custody transfer.

## Requirements

### Validated

- [x] Pure-Dart core protocol: 26-byte packet codec, fragmentation/reassembly, and seen cache deduplication
- [x] Cryptography: Noise XX handshake (`Noise_XX_25519_ChaChaPoly_SHA256`) verified against cacophony test vectors
- [x] In-memory mesh router with TTL-bounded flooding, relay jitter (15–85 ms), and duplicate suppression
- [x] Basic LAN transport: length-prefixed TCP frames, UDP beacon discovery on port 47999, and initial chat UI

### Active

- [ ] Complete Milestone 1 file alignment (`fragmenter.dart`, `dedup.dart`, 10-node simulator test suite)
- [ ] Milestone 2: Tier 1 LAN/Hotspot transport + mDNS + SQLite persistence + 1:1 encrypted chat UI with delivery ACKs & QR verification
- [ ] Milestone 3: Tier 3 Dual-role BLE 5.0 mesh transport (`flutter_blue_plus` + `ble_peripheral`) + Android foreground relay service
- [ ] Milestone 4: Tier 4 Delay-Tolerant Networking (DTN) Spray-and-Wait store-and-forward custody engine with 25 MB quota
- [ ] Milestone 5: Tier 2 Routerless Wi-Fi Direct bridge + Serverless WebRTC (`iceServers: []`) full-duplex voice calls
- [ ] Milestone 6: Native `libcodec2` (1200 bps) FFI integration for ultra-low-bitrate PTT voice bursts over BLE mesh

### Out of Scope

- External radio hardware (ESP32, LoRa SX1262, HF transceivers) — 100% stock-smartphone hardware only
- Central server dependencies, cloud relays, account registration, phone numbers
- Unencrypted mesh forwarding (all payloads must be encrypted before transmission)

## Context

- Target OS: Android 8.0+ (API 26+) for Bluetooth 5.0 LE Coded PHY support; Windows 11 desktop runner for developer testing.
- UI Framework: Flutter with Material 3.
- Network stack:
  - Tier 1: Local WLAN / zero-data hotspot (`LanTransport`)
  - Tier 2: Direct P2P Wi-Fi Direct / Wi-Fi Aware (`WifiDirectTransport`)
  - Tier 3: Multi-hop BLE 5.0 (`BleTransport`)
  - Tier 4: Delay-tolerant store-and-forward custody sync (`DtnStoreRouter`)

## Constraints

- **Hardware**: Stock Android smartphones only. No specialized chips or external dongles.
- **Security**: Mutual authentication via Noise XX; out-of-band key verification via QR codes.
- **Resource limits**: 25 MB maximum DTN custody storage per device; 4096-entry deduplication cache.

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| 100% Smartphone Silicon | Eliminates barrier to entry; no external dongles required | ✓ Good |
| 4-Tier Transport Hierarchy | Optimizes throughput vs range across Wi-Fi, Wi-Fi Direct, BLE, and DTN | ✓ Good |
| Noise XX over X25519/ChaChaPoly | Mutual authentication without PKI or certificate authorities | ✓ Good |
| Spray-and-Wait DTN | Bounded epidemic replication ($K=6$) achieves city-wide reach without flooding storage | ✓ Good |
| Codec2 (1200 bps) for BLE Voice | Allows voice streaming within BLE's narrow bandwidth (~150 bytes/sec) | ✓ Good |
