---
gsd_state_version: '1.0'
status: executing
progress:
  total_phases: 5
  completed_phases: 0
  total_plans: 10
  completed_plans: 4
  percent: 40
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-11-14)
See: docs/mission_plan.md (threat model, limits, design decisions)

**Core value:** Offline, end-to-end encrypted phone-to-phone messaging for a pre-provisioned unit, with sealed frames and operator-controlled emissions.
**Current focus:** Phase 1 close-out (plan 01-05), then Phase 2.

## Current Position

Phase: 1 of 5 (Protocol core)
Plan: 4 of 5 in current phase
Status: Plans 01-01 to 01-04 implemented and tested, UNCOMMITTED. Plan 01-05 not started.
Last activity: 2026-11-14 — Reviewed plan and roadmap against docs and code; roadmap cut from 6 phases to 5; requirements renumbered REQ-01 to REQ-28.

## Performance Metrics

- Total tests: 134 passing (`flutter test`), includes the 10-node simulator.
- Lints: clean (`flutter analyze`).
- Debug APK builds (`flutter build apk --debug`); NDK path set in `android/local.properties`.

## What is built but not wired

- `SealedEnvelope` and `RosterResolver` have no callers outside their tests.
- The reverse-path table is used only by `MeshRouter.originateTo`, which `MeshNode` does not call; all traffic still floods.
- Identity is regenerated on every launch (`lib/main.dart`).
- LAN beacon and link hello still send a static PeerID in cleartext.
- Delivery receipts are not shown in the UI.

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

- README rewritten 2026-11-14 into Implemented, Limits, and Planned; keep it in step as phases land.
- Manual two-instance Windows GUI check has not been confirmed.
- `Python/` in the repo root is untracked and must not be committed.
