# Operator controls: manual device tests

Status: NOT RUN. No device has been tested. Automated checks pass (`flutter test`,
`flutter analyze`, format check, and `flutter build apk --debug`). The steps below are the
manual procedure; record date, device model/API level, app build and PC capture file.

Covers REQ-23 (posture), REQ-24 (panic wipe), REQ-25 (Relay Mode). Phase 4 device test is in
`.planning/ROADMAP.md`.

## Equipment

- Phone A and phone B, both provisioned into the same unit, on the same hotspot.
- A Windows PC on the hotspot, running Wireshark capturing UDP port 47999 and TCP traffic on
  the hotspot interface.
- A BLE scanner app on phone A (for example nRF Connect). The current app does not construct
  `BlePlatformRadio`, so it emits no BLE in any posture. Test 1's BLE observation is a
  wiring-gap check, not proof that Silent gates BLE; do not record it as a posture pass.
- Android Debug Bridge (`adb`) on the PC for the foreground-service check.

## Test 1: Silent on phone B for 5 minutes (roadmap device test)

1. On B, open Home, tap Silent in the radio posture selector.
2. Confirm B shows "Listening on port -".
3. Start the Wireshark capture on the PC at the same time as the switch. Run it 5 minutes.
4. Expected: no UDP datagrams from B's address to 255.255.255.255:47999 or to any port; no TCP
   SYN from or to B; no frames from B on the capture.
5. On A, watch the BLE scanner for B's advertisements. None are expected because BLE is not
   app-wired. Record `NOT APPLICABLE — BLE manager absent`, not Pass; rerun after Phase 3
   integration.
6. On B, try to send a message to A. Expected: the error "Silent: nothing is sent" and no
   message in the thread.

## Test 2: Quiet on phone B

1. On B, tap Quiet. Expected: "Send burst (0 held)" appears.
2. Capture for 2 minutes. Expected: no beacons from B (UDP port 47999). Open TCP links that
   were already up stay up and show keepalives; that is by design.
3. On B, send 3 messages to A. Expected: each shows as held and the counter reads
   "Send burst (3 held)". On A, nothing arrives.
4. Tap Send burst on B. Expected: the counter returns to 0 and A receives the 3 messages in
   order with delivered marks on B.

## Test 3: Silent survives a restart

1. Set B to Silent. Force-stop the app and reopen it.
2. Expected: the posture selector shows Silent, the phone shows no listening port, and the
   capture shows no UDP or TCP from B.
3. Set B to Normal. Expected: a listening port appears and beacons resume.

## Test 4: Panic wipe on phone B

1. On B, tap Panic wipe. Expected: a dialog. The Wipe button is disabled.
2. Type a word other than WIPE. Expected: Wipe stays disabled.
3. Type WIPE and tap Wipe. Expected: the phone returns to the provisioning screen with no
   members and no messages.
4. Force-stop the app and reopen it. Expected: the provisioning screen. Its fingerprint differs
   from the one shown before the wipe, and so does the identity code shown after a name is typed.
   The name field may still hold the last name typed; that is not key material.
5. On A, watch the capture for B's old beacon ID. Expected: none resolves to B. B cannot link
   to A because it is not on A's roster.
6. Re-join B to the unit by its new identity code, if that test is needed. Record whether the
   old keys remain anywhere visible; they should not.

## Test 5: Relay Mode and foreground service

1. On B, in Normal, tap Relay Mode. Grant the Android Nearby devices permissions if prompted.
   Expected: a black screen with Forwarded, Suppressed and Links counters, Normal posture,
   and `Background service: running`.
2. If permission is denied, record the displayed error, grant permission in Android Settings,
   leave Relay Mode and enter it again. Confirm the service starts only after permission is
   granted.
3. Send LAN messages from A through B to the PC. Expected: Forwarded rises when B relays;
   Links reflects the current LAN links.
4. Lock B's screen for 30 minutes. Keep A and the PC sending one marked message per minute
   through B. Record delivered count, drop times and whether the foreground notification
   remains visible. Do not use this to claim BLE screen-off behavior; BLE is not wired.
5. Unlock B. Confirm Relay Mode still shows the service as running and traffic resumes.
   Optional PC check: run `adb shell dumpsys activity services me.offmesh.offmesh` and save
   the service section with the test result.
6. Tap Leave. Expected: Home returns and the relay notification/service stops within a few
   seconds. Confirm with the UI status or `dumpsys`.

## Results log

| Test | Date | Device / build | Result | Notes |
|------|------|----------------|--------|-------|
| 1 Silent 5 min | | | NOT RUN | |
| 2 Quiet and burst | | | NOT RUN | |
| 3 Silent restart | | | NOT RUN | |
| 4 Panic wipe | | | NOT RUN | |
| 5 Relay Mode and service | | | NOT RUN | |
| 5 screen-off LAN relay, 30 min | | | NOT RUN | |
