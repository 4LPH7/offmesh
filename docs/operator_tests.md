# Operator controls: manual device tests

Status: NOT RUN. No device has been tested. This build has no Bluetooth test partner and no
capture rig. Code is verified only by unit, widget and fake-transport tests and the debug APK
build (`flutter test`, `flutter build apk --debug`). The steps below are the procedure to
run later; record each result with date, device model, app build and the PC capture file.

Covers REQ-23 (posture), REQ-24 (panic wipe), REQ-25 (Relay Mode). Phase 4 device test is in
`.planning/ROADMAP.md`.

## Equipment

- Phone A and phone B, both provisioned into the same unit, on the same hotspot.
- A Windows PC on the hotspot, running Wireshark capturing UDP port 47999 and TCP traffic on
  the hotspot interface.
- A BLE scanner app on phone A (for example nRF Connect). Note: no code in `lib/` calls
  `startAdvertising`, `startScan` or `connect` on a BLE radio, so the app emits no BLE in any
  posture today. The BLE check in Test 1 therefore cannot fail yet and proves nothing about
  the posture. It becomes meaningful only after BLE is wired to the posture (see
  `.planning/phases/04-operator/04-01-PLAN.md`). Do not record it as a pass.

## Test 1: Silent on phone B for 5 minutes (roadmap device test)

1. On B, open Home, tap Silent in the radio posture selector.
2. Confirm B shows "Listening on port -".
3. Start the Wireshark capture on the PC at the same time as the switch. Run it 5 minutes.
4. Expected: no UDP datagrams from B's address to 255.255.255.255:47999 or to any port; no TCP
   SYN from or to B; no frames from B on the capture.
5. On A, watch the BLE scanner for B's advertisements. Expected: none. As built, this holds
   trivially because the app never advertises over BLE; it is not evidence of the posture
   until BLE is wired. Record the result with that caveat.
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

## Test 5: Relay Mode

1. On B, in Normal, tap Relay Mode. Expected: a black screen with Forwarded, Suppressed and
   Links counters, and the posture is Normal.
2. Send messages from A through B to the PC. Expected: Forwarded counts rise.
3. Tap Leave. Expected: back on Home.
4. Known gap: the foreground service is not built. Lock the screen on B for 5 minutes and
   check whether B still relays. Expect it may stop. Record the result as a finding.

## Results log

| Test | Date | Device / build | Result | Notes |
|------|------|----------------|--------|-------|
| 1 Silent 5 min | | | NOT RUN | |
| 2 Quiet and burst | | | NOT RUN | |
| 3 Silent restart | | | NOT RUN | |
| 4 Panic wipe | | | NOT RUN | |
| 5 Relay Mode | | | NOT RUN | |
