# OffMesh

**100% Smartphone-Native Offline Encrypted Mesh Messenger & Voice Communicator**  
*Zero internet. Zero SIM recharge. Zero central servers. Zero external hardware.*

OffMesh turns standard, unmodified smartphones into a self-healing, multi-hop communication network. Built in Flutter for Android (with Windows Desktop support for local testing), it routes end-to-end encrypted messages, Push-to-Talk (PTT) voice bursts, and full-duplex voice calls directly between devices using built-in Wi-Fi, Wi-Fi Direct, Multi-Hop Bluetooth 5.0, and Delay-Tolerant Store-and-Forward routing.

---

## Smartphone-Only 4-Tier Architecture

| Tier | Transport Mechanism | Range / Coverage | Capabilities |
|---|---|---|---|
| **Tier 1 (LAN / Hotspot)** | mDNS + UDP Broadcast + TCP over shared Wi-Fi or zero-data Hotspot | 50 m – 150 m | Full-duplex WebRTC Opus calls & instant chat |
| **Tier 2 (Direct P2P)** | Wi-Fi Direct / Wi-Fi Aware routerless phone-to-phone link | 100 m – 200 m | Routerless full-duplex voice calls & fast sync |
| **Tier 3 (Live BLE Mesh)** | Dual-role BLE 5.0 Central + GATT Peripheral (LE Coded PHY) | Up to 15 hops (~1–3 km chain) | Live multi-hop chat & `Codec2` 1200 bps PTT voice |
| **Tier 4 (DTN Store & Forward)** | Spray-and-Wait encrypted custody cache carried by moving peers | City-wide / Unlimited | Asynchronous delivery of text & compressed voice notes |

---

## Security & Protocol Guarantees

* **Identity:** Static `X25519` keypair stored in Android Keystore; `PeerID = SHA-256(pubKey)[0..8]`.
* **Session Cryptography:** `Noise_XX_25519_ChaChaPoly_SHA256` with responder static key verification on Message 2, deterministic glare resolution, and strict monotonic nonce discipline.
* **Zero-Trust Multi-Hop Relaying:** Intermediate BLE and DTN carrier nodes only see the 26-byte outer routing header or sealed DTN envelope; payloads remain encrypted end-to-end.
* **Out-of-Band Key Pinning:** Peers display as `unverified` until full 256-bit public keys are verified via in-app QR scan.

---

## Milestone Roadmap

- [ ] **Milestone 1:** Pure-Dart protocol core (`Packet`, `Fragmenter`, `Dedup`, `Noise_XX`, `Router`, and multi-node `FakeTransport` test suite)
- [ ] **Milestone 2:** Tier 1 LAN/Hotspot transport + SQLite (`sqflite_common_ffi`) persistence + 1:1 encrypted chat & QR verification UI
- [ ] **Milestone 3:** Tier 3 Dual-role BLE 5.0 multi-hop mesh transport + Android foreground relay service
- [ ] **Milestone 4:** Tier 4 Delay-Tolerant Networking (DTN) Spray-and-Wait store-and-forward engine for long-distance offline delivery
- [ ] **Milestone 5:** Tier 2 Routerless Wi-Fi Direct bridge + Serverless WebRTC (`iceServers: []`) full-duplex voice calls
- [ ] **Milestone 6:** Native CMake `libcodec2` (1200 bps) FFI integration for ultra-low-bitrate Push-to-Talk over BLE mesh and DTN voice notes
