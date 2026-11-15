# BLE spike: manual two-phone procedure

Status: **NOT RUN.** No second phone with Bluetooth was available when this was written.
Nothing below is a measured result. Every row of the go/no-go table is blank until a
two-phone run fills it in.

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
3. Enable Bluetooth on both. Grant the Bluetooth permissions when prompted (Android 12+:
   Nearby devices).
4. Keep both phones within one metre for the first run.
5. On the PC, a BLE scanner app (for example nRF Connect) on a third phone or the PC
   adapter is optional. It is used only to confirm that the advertisement carries an
   8-byte service-data payload under the OffMesh service UUID `4f66664d-6573-6800-0000-000000000001`
   and no device name.

## Steps

### 1. Dual role at the same time

- Both phones advertise, scan, run the GATT server, and connect as client, simultaneously.
- Record: does A see B's sighting? Does B see A's? Does each side report `inbound` and a
  client `connect` success? Does the handshake reach `remotePeerId` on both sides?

### 2. Negotiated MTU

- Read the `mtu` events on both sides. Record the negotiated value for the client and the server.
- Record the phone model and Android version for each phone.

### 3. Throughput and integrity: 1000 writes of 200 bytes

- Send 1000 packets of 200 bytes from A to B with the spike harness (one `BleLink.send` per
  packet, one packet per call, awaited).
- Count packets received on B and check each payload matches. Record: received count,
  mismatched count, elapsed time, and any `drop` count.

### 4. 30-minute screen-off run

- Phones in airplane mode with Bluetooth on.
- Screens off for 30 minutes. Send one message per minute from A and one from B.
- Record: messages sent and delivered, whether a link dropped, and the time of each drop.
  The app has no foreground service yet (REQ-21), so Android may kill the process;
  record that case separately from a radio failure.

### 5. Forced MTU 23

- Repeat step 3 with the negotiated MTU forced to 23, if the stack allows it, or with a
  peer that refuses MTU negotiation.

## Go / no-go table

Fill in after the run. Go means all three rows meet the threshold.

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
