---
gsd_state_version: '1.0'
status: executing
progress:
  total_phases: 5
  completed_phases: 1
  total_plans: 14
  completed_plans: 13
  percent: 93
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-11-14)
See: docs/mission_plan.md (threat model, limits, design decisions)

**Core value:** Offline, end-to-end encrypted phone-to-phone messaging for a pre-provisioned unit, with sealed frames and operator-controlled emissions.
**Current focus:** Phase 2 software is complete; its real-device acceptance test is still NOT RUN. Phase 3's two-phone BLE spike is the next hardware gate.

## Current Position

Phase: 2 of 5 (Sealed LAN chat on real devices)
Plan: 5 of 5 (device procedure written; execution NOT RUN)
Status: Phase 1 is complete. Phase 2 implementation and automated validation pass; device acceptance remains open. Phases 3–5 have partial software implementation, described in ROADMAP.md.
Last activity: 2026-11-15 — Messages, Unit and Controls use focused tabs; the composer and connection status are simplified; Relay Mode is Android-only and BLE availability is explicit. Fresh validation: 353 tests pass, analyzer and format checks are clean, APK rebuilt, and Windows clean build plus debug launch pass. No Android device is attached; device acceptance remains NOT RUN.

## Performance Metrics

- Tests: 353 passing (`flutter test`).
- Lints: clean (`flutter analyze`).
- Format check: clean (`dart format --output=none --set-exit-if-changed lib test`).
- Android APK builds require `ANDROID_NDK_HOME` set to the installed NDK for that build process; keep the machine-specific path out of the repo.
- Fresh Windows debug build and app launch pass. Available targets: Windows, Chrome and Edge; no Android target is connected.

## Remaining software gaps and device gates

- `BleLink` and `BlePlatformRadio` have fake-backed tests and compile into the APK, but bootstrap does not attach them to `MeshNode`; BLE posture gating and peer management are absent.
- Noise K, custody envelope codecs and `EnvelopeStore` are tested primitives; no app contact flow owns or exchanges them.
- Established encrypted MeshNode sends use the learned reverse path; initial handshakes and receipts intentionally flood.
- Foreground Relay service and operator UI are implemented, but screen-off and radio behavior still need phone validation.
- Windows clean build and debug launch verified with MSVC 14.52 and ATL. Manual Windows provisioning/network acceptance remains unrun.

## Accumulated Context

### Decisions

- Flood suppression is per link, not a full cancel, because transports are point-to-point.
- Static PeerIDs stay inside sealed frames; rotating IDs are used only on unsealed discovery surfaces (beacon, hello, BLE advertisement). Sessions stay keyed by static PeerID.
- Receipts ride the Noise session; no separate MAC.
- Relays are full unit members in v1 (they must hold the seal key).
- Voice calls and live push-to-talk are dropped; voice notes are parked.
- Hardening is not a phase: fuzzing joins Phase 1, capture checklists end each transport phase.

### Open decisions

See "Open decisions" in ROADMAP.md: relay key tier, epoch key chain, TTL, relay-side unicast.

### Known gaps outside the roadmap files

- README links the manual runbooks; BLE and DTN remain documented as prototypes not connected to chat.
- Manual two-instance Windows GUI check has not been confirmed.
- `Python/` in the repo root is untracked and must not be committed.
