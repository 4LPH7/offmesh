# OffMesh Mission Plan: Tactical Smartphone-Native Mesh

## 1. Operational Reality & The Honest Limit

No software application can make a radio transmitter invisible. A directional antenna or RF scanner detects transmissions regardless of software obfuscation:
- Low-power BLE in open/wooded terrain is detectable at ~100 meters.
- Wi-Fi and Wi-Fi Direct hotspots are detectable at significantly longer ranges.

### The Three Protective Pillars
1. **Zero-Yield Captured Nodes**: Content and routing metadata are worthless without the unit's cryptographic keys. Ephemeral, memory-only storage by default; instant panic wipe and duress PIN erase all keying material.
2. **Emission Control (EMCON)**: Radios do not broadcast continuously. Operators control three radio postures (Silent, Quiet, Normal) and use scheduled transmit windows to minimize RF signature.
3. **Metadata Sanitization**: Eliminate cleartext identifiers. Packets are masked with symmetric unit keys, and peer addresses rotate hourly via HMAC ratchet so outside observers cannot link transmissions to nodes.

---

## 2. Lessons from Proven Field Systems

### Reticulum (RNS)
- Cleartext source and destination addresses represent critical surveillance leaks.
- Packets sealed with an outer symmetric network/unit key protect hop count, packet type, and routing metadata from unkeyed observers.

### BitChat
- Fixed static public keys in packet headers allow physical location tracking.
- Dynamic hourly HMAC ratchets derive temporary 8-byte IDs that only authorized roster holders can map back to an identity.

### Meshtastic
- Dynamic tree routing and multi-hop link-state algorithms fail in volatile mobile environments.
- Managed flooding is the most resilient: relay jitter (15–85 ms) combined with neighbor snooping (canceling a planned relay if a peer relays the packet first) prevents broadcast storms.

### Briar & Berty
- Continuous background connections drain battery and leak beacons.
- Store-and-forward custody transfer with bounded replication allows messages to traverse partitioned networks without real-time end-to-end paths.

---

## 3. Radio Constraints & Architectural Adjustments

1. **Bluetooth LE Reality**: BLE Long Range (LE Coded PHY) cannot be treated as a baseline dependency—many Android devices advertise on Coded PHY but cannot scan for it. Coded PHY is negotiated opportunistically; standard 1M PHY is the fallback baseline.
2. **Android 14+ Background Execution**: Android kills background mesh processes aggressively. A typed foreground service (`android:foregroundServiceType="connectedDevice"`) is mandatory.
3. **Voice Strategy**: Full-duplex WebRTC is discarded—continuous streaming creates prolonged RF beacons. Half-duplex Push-to-Talk (PTT) using `libcodec2` (1200 bps = 150 bytes/sec) transmits in short, bursty packets (3–5 seconds), minimizing RF exposure.

---

## 4. Operator Tooling

- **EMCON Posture Switch**:
  - **Silent**: Radios strictly passive (listen-only); no broadcasts, ACKs, or beacons emitted.
  - **Quiet**: Transmissions batched into periodic scheduled windows or emergency outgoing manual bursts.
  - **Normal**: Standard mesh routing and automatic discovery active.
- **Brevity Codes**: Pre-shared numeric codes for critical status updates (under 10 bytes), avoiding large payloads.
- **Cellular Interlock**: Active warning and transmission inhibition if cellular radio or internet connectivity is detected.
- **Zero-Internet Provisioning**: Pre-deployment roster exchange via animated 2D QR codes and local APK sharing over Wi-Fi Direct.

---

## 5. Roadmap Summary

- **Phase 1: Pure-Dart Hardened Protocol & Simulation**: Routing table, flood suppression, unit-sealed envelopes, rotating HMAC IDs, end-to-end ACKs, and 10-node simulated topology.
- **Phase 2: Tier 1 LAN / Hotspot Transport & Memory-First UI**: mDNS + UDP port 47999, optional encrypted SQLite persistence with panic wipe, EMCON UI switch, and QR provisioning.
- **Phase 3: Tier 3 Dual-Role BLE 5.0 Mesh & Foreground Relay**: Typed foreground service, dynamic MTU, opportunistic Coded PHY, and managed flood cancellation.
- **Phase 4: Tier 4 Delay-Tolerant Store-and-Forward**: Sealed custody envelopes, Spray-and-Wait custody transfer ($K=6$), and 25 MB quota ring buffer.
- **Phase 5: Tier 2 Wi-Fi Direct Ad-Hoc Bridge & PTT Burst Voice**: Routerless direct link establishment, Codec2 1200 bps PTT bursts over BLE and Wi-Fi Direct.
- **Phase 6: Hardening, Fuzzing & Red-Team Traffic Analysis**: Protocol fuzzer, reproducible APK builds, and RF emission auditing.
