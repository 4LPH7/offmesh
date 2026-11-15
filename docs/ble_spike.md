# BLE spike: manual two-phone procedure

Status: **NOT RUN.** No Android devices were available for this run. Nothing below is a measured result.

**Execution gate:** the current app does not construct `BlePlatformRadio` or expose BLE
controls, so this procedure cannot be run with the current APK alone. The two-phone spike
needs a diagnostic harness or app BLE integration first. Do not mark the radio rows passed
from unit tests or an APK build.

Covers: ROADMAP phase 3, plan 03-00 (spike) and the hardware checks in plan 03-01.

## What the code does and does not show

Verified by tests and the APK build only:

- Segmentation and reassembly at ATT MTU 23 and above (`test/core/ble`).
- `BleLink` handshake, sealing and roster check over a fake channel pair (`test/transports/ble_link_test.dart`).
- The debug APK builds with the Kotlin radio (`BleRadioPlugin.kt`) and the manifest permissions.

Not verified: that the Kotlin radio advertises, scans, connects or transfers bytes on
real hardware. That needs the procedure below.

## Setup

1. Two Android phones (A and B) running the same debug build: `flutter build apk --debug`,
   with `ANDROID_NDK_HOME=D:/Android/ndk-r28c`. Install on both.
2. Provision both phones into one unit (QR), as in phase 2.
3. Enable Bluetooth on both. Grant Nearby devices permissions when prompted (Android 12+).
   On Android 11 and earlier, grant location permission if the scanner requests it.
4. Keep both phones within one metre for the first run.
5. On the PC, a BLE scanner app (for example nRF Connect) on a third phone or the PC
   adapter is optional. It is used only to confirm that the advertisement carries an
   8-byte service-data payload under the OffMesh service UUID `4f66664d-6573-6800-0000-000000000001`
   and no device name.

## Steps

### 1. Dual role at the same time

1. Use a diagnostic build that exposes the radio start/stop, sighting, inbound and connect
   events; the current chat UI has no such controls.
2. Put both phones in airplane mode, turn Bluetooth back on, and keep them within one metre.
3. Start advertising and scanning on both phones at the same time.
4. Record whether A sees B and B sees A, including the rotating ID and reported address.
5. Connect from the phone with the lower static PeerID. Record inbound-channel and connect
   results on both phones, then verify `BleLink.remotePeerId` resolves to the expected roster
   member. Repeat with the roles reversed after closing both links.

### 2. Negotiated MTU

1. Read the MTU event on both sides after connection. Record the client and server values.
2. Record phone model, Android version/API level, and whether the OS accepted an MTU request.
3. Treat 23 as the valid fallback; do not infer a larger value from a request alone.

### 3. Throughput and integrity: 1000 writes of 200 bytes

1. From the diagnostic harness, send 1000 separate 200-byte frames A to B, awaiting each
   send. Include a sequence number and deterministic payload bytes in every frame.
2. Repeat B to A.
3. Count received frames, missing sequence numbers, duplicate frames, byte mismatches,
   drops and elapsed time for each direction. Save the harness log.

### 4. 30-minute screen-off run

1. Start the Relay Mode foreground service on both phones and confirm its status reads
   `Background service: running` before locking the screens.
2. Keep both phones in airplane mode with Bluetooth on; lock both screens for 30 minutes.
3. Send one test frame per minute in each direction from the diagnostic harness. Record
   sequence numbers, delivery, link drops and timestamps.
4. After unlocking, confirm the Relay notification and service are still present. On the
   PC, `adb shell dumpsys activity services me.offmesh.offmesh` can confirm the service
   state when the Android SDK tools are installed.
5. **Current limitation:** because BLE is not attached to MeshNode, a passing service check
   proves only that the service survives. It does not prove BLE relaying with the screen off.

### 5. Forced MTU 23

1. Repeat the 1000-frame run with ATT MTU 23, either through the harness override or by
   using a peer that refuses a larger MTU.
2. Record the effective MTU on both sides and use the same integrity and delivery checks.

## Go / no-go table

Fill in after the run. Record device/build details above the table. A go requires the dual-role,
throughput, screen-off and advertisement rows to meet their thresholds.

| Check | Threshold | Result (A to B) | Result (B to A) | Go or no-go |
|-------|-----------|-----------------|-----------------|-------------|
| Dual role, both directions | Both sides see each other and complete handshake | NOT RUN | NOT RUN | |
| Negotiated MTU | Recorded, at least 23 | NOT RUN | NOT RUN | |
| 1000 x 200-byte writes | At least 95% delivered and all intact | NOT RUN | NOT RUN | |
| 30-minute screen-off run | At least 95% of messages delivered | NOT RUN | NOT RUN | |
| Advertisement | 8-byte service data, no name, no static ID | NOT RUN | NOT RUN | |

## Decisions the run settles

- Platform channel versus a BLE plugin. This plan chose the platform channel because no
  pub package was checked for GATT server and advertising support in this run. If the run
  shows the Kotlin radio is unreliable, re-check packages before writing more Kotlin.
- Chunk size. The 512-byte cap and MTU-dependent chunks are provisional until the MTU
  numbers are in.
- Scan filter. The scan is unfiltered and checks service data in software. Measure scan
  power before deciding whether a hardware filter is needed.
