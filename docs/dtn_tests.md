# Phase 5 device test: store-and-forward

Status: **NOT RUN**. Nothing here has been verified on hardware. The DTN code
(lib/core/dtn/, lib/core/crypto/noise_k.dart) is tested with unit tests only. It is not yet wired
into the mesh, the sealed link or the app, and the frame-size open decision in
.planning/phases/05-dtn/05-01-PLAN.md is unresolved. This procedure cannot pass until both are done.

## Requirement under test

ROADMAP Phase 5, device test: phone A sends to the PC while the PC is off the network. Phone B meets
A over BLE, then joins the PC's LAN. The PC receives the message once.

## Equipment

- Phone A (sender), Android, debug build from this branch.
- Phone B (carrier), Android, same build.
- Windows PC (recipient) on the LAN, with the unit roster provisioned on all three devices.
- A packet capture tool on the LAN (for the cleartext check below).

## Procedure

1. Start the app on A, B and the PC. Confirm each sees the others from the roster.
2. Take the PC off the LAN.
3. On A, send one text to the PC.
4. Bring B within Bluetooth range of A. Let the ID exchange finish.
5. Move B onto the PC's LAN.
6. Wait up to 5 minutes for the PC to show the message.
7. Keep B on the LAN for another 5 minutes. Confirm the PC still shows the message only once.
8. Capture the LAN traffic during steps 5 to 7. Confirm no readable message text, sender name or
   recipient name appears in the capture.

## Pass criteria

- The PC shows the message once, with its text intact (step 6 and step 7).
- Nothing in the LAN capture is readable (step 8).

## Record on the run

Date, commit hash, device models, and the result of each step. If a step fails, note whether B held
the envelope (ID exchange), and whether the PC refused it on decode or on K open.

## Result

NOT RUN.

## Known residual risk: copy budget

The copies byte sits outside the K prologue, so a carrier can rewrite it. The wire cap
(`custodyMaxWireCopies`, 3) is the largest budget an honest spray can hand over. It bounds how far
one hop can inflate a budget, but it does not authenticate the byte. A carrier holding one copy can
still raise it to 3 and re-inject, so a malicious carrier can keep spreading at the cap. Eviction
also prefers the lowest copy count, so an inflated envelope can outlive an honest one with the same
expiry. Mitigation needs an authenticated per-hop value, which is not built yet.
