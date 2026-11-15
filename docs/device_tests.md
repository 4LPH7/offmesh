# Device tests

> **Status: MANUAL. NOT YET RUN.** No result below has been observed on real hardware.
> Fill in the results table at the end when the test is run. Until then Phase 2 is not
> closed.

## Phase 2: sealed LAN chat on real devices

ROADMAP device test, quoted:

> Phone A hosts a hotspot; phone B and the PC join. Send 50 messages each way between A
> and B and 20 between B and the PC. All arrive with delivered marks. The PC capture passes
> criterion 3.

This procedure sends **20 messages each way** between B and the PC (40 in total). That is
stricter than the sentence above and satisfies either reading of "20 between".

The test also covers the other Phase 2 success criteria where a device can show them:
identity kept across restart (1), unprovisioned devices cannot link (2), fingerprints (5),
delivered marks (6). Criterion 4 (rotating ID changes each hour) cannot be seen on the
wire, because the rotating ID travels inside the seal behind a random nonce. It is covered
by unit tests only (`test/core/crypto/rotating_id_test.dart` and the LAN tests).

### Prerequisites

1. Two Android phones (A and B) with the same debug APK installed. Set
   `$env:ANDROID_NDK_HOME` to the installed NDK root in PowerShell, then run
   `flutter build apk --debug`. Install with
   `adb install -r build/app/outputs/flutter-apk/app-debug.apk` on each phone, or copy the APK
   to each phone and open it there.
2. A Windows PC running `flutter build windows --debug` or `flutter run -d windows`. The stale
   MSVC 14.51 CMake cache was reset; a clean Windows build and debug app launch succeeded on
   2026-11-15 with MSVC 14.52 and ATL. To repeat the reset, run `flutter clean`, `flutter pub get`,
   then `flutter build windows --debug` from the repo root. `flutter clean` removes generated
   build outputs, which those commands recreate. Windows manual provisioning and network checks
   remain NOT RUN.
3. Wireshark with Npcap on the PC.
4. Windows Firewall allows the OffMesh app on the network profile the hotspot gets (a new
   hotspot network is often classed as Public). Without that, inbound TCP links and UDP
   beacons to the PC are blocked.
5. Automatic date and time on in all three devices. Clocks must agree within 10 minutes,
   or every sealed frame is rejected as stale.
6. Write down, for each device, a short name: `A`, `B`, `PC`.
7. Message text: every test message contains the marker `zqx7` followed by a counter,
   for example `zqx7-AB-01`. The capture checklist searches for this marker.

### Procedure

Record every observation in the results table.

**Setup and network**

1. On phone A, turn on the mobile hotspot. Turn off mobile data if possible so no other
   traffic is mixed in.
2. Join phone B and the PC to A's hotspot.
3. On the PC, run `ipconfig` and note the PC's IPv4 address on the hotspot network. On
   phone B, note its Wi-Fi IP (Settings, Wi-Fi, network details). Phone A's address is the
   hotspot gateway shown on B or the PC (often `192.168.43.1`, but it varies).
4. On the PC, start a Wireshark capture on the Wi-Fi interface now, before any OffMesh
   device is provisioned, and keep it running until step 30. Save it as
   `phase2_capture.pcapng`.

**Unprovisioned devices cannot link (criterion 2)**

5. Fresh install or cleared app data on all three. Launch OffMesh on A, B and the PC.
   Each shows the screen "OffMesh: join a unit" with "This phone is not in a unit and will
   not link to anyone."
6. Confirm there is no way to dial: the Connect field is not shown on that screen.
   Record pass if no device reaches the home screen.

**Provisioning (criteria 2 and 5)**

The PC creates the unit, so the unit secret never leaves a screen as text: the phones
scan it from the PC monitor. Only identity codes, which hold a public key and a name, are
moved as text.

7. On each device, type its name (`A`, `B`, `PC`) in "Your name". Each shows its identity
   code (QR and text) and a fingerprint. Write down each device's fingerprint.
8. On the PC, press "Create unit". The app opens the Messages tab. Open the Unit tab
   from the bottom navigation and note the PC's "My ID" (16 hex characters) and its
   "Listening on port N".
9. In the Unit tab on the PC, paste phone A's identity code text (`OFFM-ID1:...`) into
   "Add a member" and press Add. It is public data, so a USB text file is sufficient.
10. Do the same for phone B.
11. In the PC's Unit tab, confirm the member list shows `PC (this device)`, `A` and `B`.
    Check A and B fingerprints against the values from step 7.
12. In the PC's Unit tab, press Share. A QR of the unit code is shown.
13. On phone A, in "Join a unit", press the scan button and scan the PC screen. A reaches
    the home screen.
14. Do the same on phone B.
15. On A and B, open the Unit tab. Confirm the member list shows all three names and
    each fingerprint matches step 7.
16. In the Unit tab on each device, note "My ID" and "Listening on port N". The port is
    chosen at random on every start, so re-read it after a restart.

The roster must list all three devices before it is shared. A device added after the
share is unknown to devices holding the older code: they drop its beacons and hellos. If
a member is added later, share the unit again and re-import it on every other device.

**Linking**

17. Wait up to 15 seconds. Beacons go out every 3 seconds and each device dials the
    members it hears. The Unit tab's direct-links count should reach 2.
18. If a count stays below 2, Android may not be delivering broadcast datagrams to the
    app. In the Unit tab, expand "Connect by address", enter the other device's IP (step 3)
    and port (step 16), then press Connect. Record which links needed the fallback.

**Messages and delivered marks (criterion 6, device test)**

19. On A, open the Messages tab, select contact `B`, and send 50 messages `zqx7-AB-01` to `zqx7-AB-50`.
20. On B, open the Messages tab, select contact `A`, and send 50 messages `zqx7-BA-01` to `zqx7-BA-50`.
21. On B, in Messages, select contact `PC` and send 20 messages `zqx7-BP-01` to `zqx7-BP-20`.
22. On the PC, in Messages, select contact `B` and send 20 messages `zqx7-PB-01` to `zqx7-PB-20`.
23. On each receiving thread, count received messages: 50 on B from A, 50 on A from B,
    20 on the PC from B, 20 on B from the PC. Note any missing counter values.
24. On each sending thread, count double-tick (Delivered) marks against single-tick
    (Sent) marks. Wait 30 seconds after the last send before counting. Pass requires every
    sent message to show Delivered.
    Messages and marks live in memory only, so count them before step 25.

**Restart keeps identity (criterion 1)**

25. Force-stop OffMesh on phone B (Settings, Apps, OffMesh, Force stop) and launch it again.
26. B goes straight to the home screen, not the provisioning screen. "My ID" and the
    fingerprint equal the values from steps 7 and 16. The member list still shows all
    three. The listening port is new; note it.
27. B links again with A and the PC (step 17 or 18). Send one message each way between B
    and A and check it shows Delivered.
28. Repeat steps 25 to 27 on the PC (close the window, start again).

**Non-member cannot link (criterion 2)**

29. Optional, if a fourth device is available: install OffMesh, create a different unit
    on it, join the hotspot, and dial A by IP and port. A's neighbour count does not
    change, and the link closes within 5 seconds. A device with no unit cannot dial at all
    (step 6).

**Capture**

30. Stop the Wireshark capture and save it. Run the checklist below on it.

### Wireshark capture checklist (criterion 3)

What the PC can see: as an ordinary Wi-Fi client it captures broadcast beacons from all
three devices plus its own links to A and B. It does **not** see the TCP link between A
and B. Criterion 3 is therefore checked on all beacons and on the PC's own links. A
capture of the A-to-B link would need a monitor-mode adapter or a capture on a phone.

Substitute the values recorded in steps 8, 16 and 26:

- `PORT_PC`, `PORT_A`, `PORT_B`: listening ports (every value seen, before and after
  restarts).
- `ID_A`, `ID_B`, `ID_PC`: "My ID" written as eight colon-separated bytes, for example
  `3f:a1:00:7c:9e:42:d0:18` for `3fa1007c9e42d018`.

| # | Filter | Expected | Checks |
|---|--------|----------|--------|
| C1 | `udp.port == 47999` | Beacons from all three IPs, about one every 3 s each | Beacons are captured at all |
| C2 | `udp.port == 47999 && udp.length != 50` | No packets | Every beacon is exactly 42 bytes of payload: seal(rotating ID 8 + port 2) is 10 + 32 overhead |
| C3 | `tcp.port == PORT_PC \|\| tcp.port == PORT_A \|\| tcp.port == PORT_B` | The PC's links to A and B | Link traffic is captured at all |
| C4 | `frame contains "OFFM"` | No packets | No `OFFM1` hello tag and no `OFFM-ID1:` or `OFFM-UNIT1:` code text on the wire |
| C5 | `frame contains ID_A \|\| frame contains ID_B \|\| frame contains ID_PC` | No packets | No static PeerID in cleartext, in any beacon, hello or frame |
| C6 | `frame contains "zqx7"` | No packets | No message text in cleartext |

C7, beacon payloads never repeat. In PowerShell on the PC:

```powershell
$tsharkPayloads = tshark -r .\phase2_capture.pcapng -Y 'udp.port == 47999' -T fields -e udp.payload
$tsharkPayloads | Group-Object | Where-Object Count -gt 1 | Select-Object Name, Count
```

Expected output: empty. Each beacon has a fresh random nonce, so equal payloads would mean
a stable, linkable beacon.

C8, no readable header in a link. In Wireshark, select a packet from C3, then Analyze,
Follow, TCP Stream, shown as ASCII. Expected: no readable words, names, `OFFM`, or
repeated fixed byte runs at the start of each frame. The first 2 bytes of each frame are a
cleartext length (u16 big-endian); that is a known limit, not a failure. The first frame
in each direction is the sealed challenge: 50 bytes on the wire (2 length + 16 random
challenge + 32 seal overhead). The second is the sealed hello: 59 bytes (2 length +
8 rotating ID + 16 echoed challenge + 1 role + 32 seal overhead). An idle link also
carries a 34-byte sealed keepalive (2 length + 32 seal overhead) every 10 seconds.

Known limits that are not failures: frame lengths and timing are visible; IP and MAC
addresses are visible; the beacon UDP port 47999 is fixed and identifies the app as
OffMesh traffic, though not which member sent it.

### Results

Date run: ______  Devices (model, Android or Windows version): ______  Tester: ______

| Step or check | Expected | Observed | Pass/Fail |
|---------------|----------|----------|-----------|
| 6 | No device links before provisioning | | |
| 11, 15 | Fingerprints match by eye on all devices | | |
| 17-18 | All links up (note any manual fallback) | | |
| 23 A to B | 50 of 50 received | | |
| 23 B to A | 50 of 50 received | | |
| 23 B to PC | 20 of 20 received | | |
| 23 PC to B | 20 of 20 received | | |
| 24 | Every sent message shows Delivered | | |
| 26 | B keeps My ID, fingerprint and unit after restart | | |
| 28 | PC keeps My ID, fingerprint and unit after restart | | |
| 29 | Non-member cannot link (optional) | | |
| C1-C3 | Beacons and PC links captured | | |
| C4 | No `OFFM` | | |
| C5 | No static PeerID | | |
| C6 | No message text | | |
| C7 | No repeated beacon payload | | |
| C8 | No readable header in a link | | |
