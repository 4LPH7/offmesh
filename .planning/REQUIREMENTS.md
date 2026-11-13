# Requirements: OffMesh (Tactical Smartphone-Native Mesh)

## Phase 1: Hardened Pure-Dart Protocol Core
- [x] **REQ-01**: 26-byte binary packet header codec with strict validation and TTL up to 15.
- [x] **REQ-02**: Message fragmentation and bounded reassembly buffer (32 slots).
- [x] **REQ-03**: Seen cache deduplication keyed on `(SenderID, PacketID, FragIdx)`.
- [x] **REQ-04**: Noise XX handshake (`Noise_XX_25519_ChaChaPoly_SHA256`) with mutual authentication and glare tie-breaking.
- [ ] **REQ-05**: Managed flood suppression with reverse-path routing table (cancels relay if neighbor relays first).
- [ ] **REQ-06**: Outer frame symmetric unit-key sealing to conceal headers from unkeyed observers.
- [ ] **REQ-07**: Hourly rotating HMAC Peer IDs computable only by unit roster holders.
- [ ] **REQ-08**: Cryptographic end-to-end delivery receipts and 10-node simulated topology verification.

## Phase 2: Tier 1 LAN Transport & Operator UI
- [ ] **REQ-09**: LAN transport combining mDNS (`_offmesh._tcp`) with UDP port 47999 broadcast and TCP framing.
- [ ] **REQ-10**: Three-state EMCON radio posture switch: Silent (passive), Quiet (scheduled/batch), and Normal.
- [ ] **REQ-11**: Ephemeral memory-only message storage by default with one-touch panic wipe and duress PIN.
- [ ] **REQ-12**: Pre-deployment roster exchange via animated 2D QR codes and local APK sharing.

## Phase 3: Tier 3 Dual-Role BLE 5.0 Mesh & Foreground Daemon
- [ ] **REQ-13**: Android 14+ typed foreground service (`connectedDevice`) for persistent pocket mesh relaying.
- [ ] **REQ-14**: Dual-role BLE 5.0 transport running concurrent Central scanner and GATT Peripheral advertiser.
- [ ] **REQ-15**: Dynamic MTU negotiation (request 251 bytes) with opportunistic `PHY_LE_CODED` request.

## Phase 4: Tier 4 Delay-Tolerant Store-and-Forward (DTN)
- [ ] **REQ-16**: Sealed DTN custody envelope with expiration timestamp and hop quota ($K=6$).
- [ ] **REQ-17**: Spray-and-Wait custody transfer with inventory vector synchronization.
- [ ] **REQ-18**: 25 MB device ring buffer storage quota with strict TTL-based pruning.

## Phase 5: Tier 2 Wi-Fi Direct Bridge & Codec2 PTT Voice
- [ ] **REQ-19**: Wi-Fi Direct ad-hoc transport via Android `WifiP2pManager` for high-speed direct peer links.
- [ ] **REQ-20**: Native C `libcodec2` (1200 bps mode) compilation via NDK CMake and `dart:ffi` bindings.
- [ ] **REQ-21**: Half-duplex Push-to-Talk (PTT) burst service (3–5s audio packets) over BLE mesh and DTN notes.

## Phase 6: Hardening, Fuzzing & Red-Team Audit
- [ ] **REQ-22**: Binary protocol fuzzing suite executing 100,000+ permutations without unhandled exceptions.
- [ ] **REQ-23**: Reproducible, deterministic Android APK build configuration.
- [ ] **REQ-24**: Traffic-analysis audit confirming emission boundaries under Silent and Quiet postures.
