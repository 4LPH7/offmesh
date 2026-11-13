# Requirements: OffMesh

## Milestone 1: Pure-Dart Protocol & Multi-Hop Simulator
- [x] **REQ-01**: 26-byte binary packet header codec with strict validation and TTL up to 15.
- [x] **REQ-02**: Message fragmentation and bounded reassembly buffer.
- [x] **REQ-03**: Seen cache deduplication keyed on `(SenderID, PacketID, FragIdx)`.
- [x] **REQ-04**: `Noise_XX_25519_ChaChaPoly_SHA256` handshake with responder key check and glare tie-breaking.
- [ ] **REQ-05**: 10-node `FakeTransport` simulator verifying multi-hop delivery, fragment reassembly, and relay jitter.

## Milestone 2: Tier 1 LAN / Hotspot & 1:1 Encrypted Chat UI
- [ ] **REQ-06**: `LanTransport` combining mDNS (`_offmesh._tcp`) with UDP port 47999 broadcast and TCP framing.
- [ ] **REQ-07**: SQLite persistence (`sqflite` on Android, `sqflite_common_ffi` on desktop) for peers and messages.
- [ ] **REQ-08**: 1:1 encrypted chat UI with delivery receipts and status indicators.
- [ ] **REQ-09**: Out-of-band QR code key verification (`qr_flutter` + `mobile_scanner`).

## Milestone 3: Tier 3 Dual-Role BLE 5.0 Mesh & Relay Daemon
- [ ] **REQ-10**: `BleTransport` with simultaneous Central and GATT Peripheral roles.
- [ ] **REQ-11**: MTU negotiation (request 251 bytes) and Android `PHY_LE_CODED` long-range request.
- [ ] **REQ-12**: Android foreground service (`flutter_foreground_task`) for continuous pocket relaying.

## Milestone 4: Tier 4 Delay-Tolerant Store-and-Forward
- [ ] **REQ-13**: Sealed DTN custody envelope with expiration timestamp and hop quota ($K=6$).
- [ ] **REQ-14**: Spray-and-Wait custody manager with bloom/inventory vector synchronization.
- [ ] **REQ-15**: 25 MB ring buffer storage quota and TTL garbage collection.

## Milestone 5: Tier 2 Wi-Fi Direct & Full-Duplex Voice Calls
- [ ] **REQ-16**: `WifiDirectTransport` via Android `WifiP2pManager` for high-speed direct links.
- [ ] **REQ-17**: Serverless WebRTC call service (`flutter_webrtc`, `iceServers: []`) signaling through Noise session.
- [ ] **REQ-18**: In-call UI: ring, accept, mute, speaker, hang-up.

## Milestone 6: Native libcodec2 FFI & BLE Push-to-Talk Voice
- [ ] **REQ-19**: NDK CMake compilation of `libcodec2` (1200 bps mode) and `dart:ffi` bindings.
- [ ] **REQ-20**: PTT mesh service for recording, compressing, and streaming audio bursts over BLE.
- [ ] **REQ-21**: Compressed voice notes attached to Tier 4 DTN custody envelopes.
