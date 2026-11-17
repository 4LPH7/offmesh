---
phase: 08-ui
plans: [08-01, 08-02]
type: execute
depends_on: ["07-03"]
requirements: [REQ-38, REQ-39, REQ-40]
files_modified: [lib/ui/home_page.dart, lib/ui/messages_page.dart, lib/ui/provisioning_page.dart, test/ui/home_page_test.dart, test/ui/operator_home_test.dart, test/ui/provisioning_page_test.dart]
autonomous: true
---

<design>
- **08-01 Talk screen.** Home has no tabs. App bar: the conversation name as a button
  (key `conversation-picker`) that opens a sheet listing channels and contacts plus
  "Join a channel" (key `join-channel-button`), and one menu (key `menu-button`).
  Body, top to bottom: status line with a colour dot (key `status-line`), the thread,
  a large round hold-to-talk button (key `talk-button`, 160 dp, channels only), the
  text field and send button. Status, in priority order: Silent (red), talking (red),
  someone talking (tertiary), no links (amber), N linked and internet (green); Quiet is
  appended.
- **Menu (two taps).** Menu items `menu-unit` (members, codes, connect by address) and
  `menu-controls` (posture, internet, relay, Relay Mode, wipe) push the existing
  UnitPage and ControlsPage in their own screens, rebuilt on controller changes.
- **08-02 First run in three steps.** Step 1: your name (key `name-next-button`).
  Step 2: create a unit, or show your identity code and paste a unit code to join.
  Step 3: done; the app switches to the talk screen once the phone is in a unit.
- **Accessibility.** Every control has a tooltip or semantic label; the talk button is a
  `Semantics(button, label)` that says what holding it does; targets stay at least
  48 dp; no fixed text heights, so system font scaling works.
</design>

<verification>
flutter test (updated UI tests drive the picker and menu, the stepped first run, the
status line, and a 2x text scale overflow check at phone width), analyze, format, APK,
Windows. Device check NOT RUN.
</verification>
