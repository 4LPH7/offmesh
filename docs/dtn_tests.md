# Phase 5 device test: store-and-forward

Status: **NOT RUN.** Nothing here has been verified on hardware. The app now carries
messages (`CustodyCourier`): a direct message with no receipt after 15 seconds is sealed to
the recipient and pushed to linked members, who hand it on when they meet the recipient.
There is no custody status view; success is the message appearing once on the PC.
Carrying runs in Normal posture only, and carried envelopes are lost if a carrier restarts.

## Requirement under test

ROADMAP Phase 5, device test: phone A sends to the PC while the PC is off the network. Phone B meets
A over BLE, then joins the PC's LAN. The PC receives the message once.

## Prerequisites and equipment

Do not start the hardware test until all of these are true:

- A build exposes an explicit store-and-forward send action for a roster contact that is not directly reachable.
- A build exchanges held and delivered IDs on contact, stores non-recipient envelopes, opens recipient envelopes once, and clears the store on panic wipe.
- A debug view or log must show the envelope ID, held/delivered state, and peer that exchanged it, and provide a way to clear only the test custody store. The current app has none of these controls.
- The BLE phone spike is GO and BLE app wiring is complete; the Phase 2 LAN acceptance test passes.

Equipment after those code gates pass:

- Phone A (sender), Android; phone B (carrier), Android; Windows PC (recipient).
- The same unit roster provisioned on all three devices.
- The unit code, each device's PeerID/name, device models, OS versions, APK version and commit hash recorded.
- A packet capture tool on the PC's LAN interface (Wireshark recommended).

## Procedure

1. Record date/time, commit hash, app build, device model/OS/API, unit roster names and
   PeerIDs. Confirm clocks agree within 10 minutes.
2. Provision A, B and the PC into the same unit. Confirm fingerprints by eye using the Phase 2
   procedure. Set all devices to Normal and confirm LAN and BLE links are available.
3. Clear only the test custody stores using the app's debug control. Record that each store is
   empty; do not panic-wipe identities between runs.
4. On the PC, disconnect Wi-Fi or leave the hotspot so its PeerID is unreachable. Verify the
   PC is absent from A's active links.
5. On A, select the PC contact, choose **Store and forward**, and send the unique marker
   `dtn-<date>-A-PC-01`. Record the new envelope ID, expiry and initial copy budget. Confirm
   A reports it held or queued for custody and does not claim recipient delivery.
6. Bring B within BLE range of A. Wait for the authenticated contact exchange. Record the
   exchanged held-ID lists and confirm B receives the envelope with a valid reduced copy
   budget. Confirm its decrypted message text is still unavailable on B.
7. On B, leave the contact exchange view open long enough to record the held envelope ID, then
   take B out of A's range.
8. Rejoin the PC to the LAN with B. Confirm the PC appears as a current neighbour and complete
   the custody exchange. Record the received envelope ID and that the PC opens it as addressed
   to itself.
9. Confirm the PC displays the exact marker once. Confirm A changes the message to Delivered
   only after a recipient delivery acknowledgement; B must never display the message text.
10. Keep B and the PC in contact for 5 more minutes. Trigger another exchange. The PC must
    still show one copy, and B must not resend an ID the PC advertised.
11. Start Wireshark before step 8 and capture through step 10. Filter for the marker text,
    sender name and recipient name; expect no cleartext matches. Save the capture with the
    run record.
12. Repeat with a second unique marker. Confirm expiry, copy-split behavior and delivery-once
    behavior do not depend on stale IDs from the first run.

## Pass criteria

- A stores the message without claiming it is delivered; B carries only the opaque envelope.
- The PC opens the matching envelope and displays the exact text once.
- A receives a recipient delivery acknowledgement; a second exchange does not redeliver.
- The LAN capture contains no message text, sender name or recipient name in cleartext.
- The run used a BLE implementation that passed the Phase 3 spike; no unit-test-only result counts as a device pass.

## Record on the run

Date/time, commit hash, APK version, device models/OS/API, unit PeerIDs, marker, envelope ID,
initial and transferred copy budgets, each exchange timestamp, recipient delivery count, capture
file name, and pass/fail for every step. If a step fails, record whether B held the envelope, the
ID lists exchanged, and whether the PC rejected envelope decode or Noise K open. Never put unit
secrets or private keys in the log.

| Check | Expected | Observed | Pass/Fail |
|---|---|---|---|
| A creates envelope while PC offline | One custody ID; no delivered mark | | |
| B receives over BLE | Same ID, copy budget reduced; plaintext unavailable | | |
| PC receives on LAN | Exact text once; recipient acknowledgment | | |
| Repeat contact | No second delivery | | |
| LAN capture | No marker, sender name or recipient name in cleartext | | |

## Result

NOT RUN — blocked on Phase 5 app integration and Phase 3 BLE wiring. Do not mark the device gate passed from the current APK.

## Known residual risk: copy budget

The copies byte sits outside the K prologue, so a carrier can rewrite it. The wire cap
(`custodyMaxWireCopies`, 3) is the largest budget an honest spray can hand over. It bounds how far
one hop can inflate a budget, but it does not authenticate the byte. A carrier holding one copy can
still raise it to 3 and re-inject, so a malicious carrier can keep spreading at the cap. Eviction
also prefers the lowest copy count, so an inflated envelope can outlive an honest one with the same
expiry. Mitigation needs an authenticated per-hop value, which is not built yet.
