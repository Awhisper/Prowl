# 067.012 — Explicit scroll controls and replica report feedback

Status: Implemented and locally verified (2026-10-01).

## Context

Device acceptance found that Mac scroll buttons briefly showed earlier output,
then returned to the active screen. Users also preferred explicit controls over
edge-triggered remote gestures and wanted the mobile controls above the reader.

## Root cause and approach

Replaying a styled snapshot enables Host DEC focus/color/size report modes in the
local terminal. Real Ghostty integration reproduced unsolicited input after each
frame. The relay forwarded these reports to Host, where the text binding moves
the viewport to the bottom. The display relay omits canonical mode enables
1004, 2031 and 2048, while preserving user input and keyboard/paste/mouse modes.
Ghostty itself and its bundled framework remain unchanged.

All clients remove remote scroll gesture recognition. Native local panning,
reading and selection remain. Only top-row buttons request remote scrolling.

A negotiated `scroll-state-v1` control precedes each matching frame for clients
that subscribe with `includeScrollState`. Optional `atTop` / `atBottom` values
commit with that frame; true disables the corresponding button. Native scrollback
geometry proves boundaries where possible. Application-owned TUI history remains
unknown; unchanged content is not evidence of a boundary. Metadata-only changes
refresh button state without changing existing binary formats or old clients.

History remains unchanged. No Agent identity checks, Ghostty fork changes,
remote restarts, physical installs or PR publication are part of this revision.

## Verification

- The report regression failed before the fix with repeated unsolicited focus,
  color and size reports. It passes afterward while genuine bracketed paste is
  still forwarded unchanged.
- 59 Mac tests passed across protocol, Host, frame state and real Ghostty/TLS
  integration; eight relay tests passed. A real Host scroll wrapper with focus
  reporting enabled remains scrolled across subsequent polling. Native top/middle/
  bottom state, unknown TUI ranges and metadata-only updates are covered.
- iPhone: 58 Swift Testing cases, three XCTest cases and six UI tests passed.
  iPad: eight UI tests passed, including existing reading-position regressions.
  The unsigned iPhoneOS arm64 Debug build passed.
- Android: 39 JVM tests passed, one existing optional TLS fixture test skipped;
  all 13 emulator UI tests passed. Debug APK and Android lint passed.
- Actual Mac windows at normal/narrow widths and mobile screenshots verified the
  top controls and disabled direction. Gesture tests verify local-only reading.
- Mac Debug build, repository formatting, 210 script tests, performance-script
  checks, workflow naming and string-catalog validation pass. Full `make check`
  is blocked by five pre-existing
  `RepositoryIconImage.swift` aspect-ratio lint violations. The relay's unchanged
  `run` method also retains its baseline complexity warning under explicit lint.
- Ghostty framework SHA-256 and submodule state remain unchanged. Physical-device
  and remote real-Agent acceptance of this revision remain pending.

## Page-sized scroll follow-up (2026-10-02)

Device acceptance requested a useful page step and stable Mac viewport sizing.
Host now computes `max(1, paneRows - 3)` for each request, so resizing the Host
pane changes the next step and three rows provide context. Proven native
scrollback uses Ghostty's existing `scroll_page_lines` binding. Otherwise Host
sends the equivalent precision wheel pixel distance, retaining application-owned
scroll handling without Agent-specific keys or Ghostty changes. The Host's
precision multiplier and the running application's wheel policy can change the
actual TUI distance.

Mac places the two buttons at opposite ends of the same row. Its center reserves
a constant height for a horizontal spinner and label, error text, or scrollback
status, so loading does not change the terminal's fit-to-window height.

Verification: all 16 real Ghostty integration tests pass, including exact native
page distance, stable viewport height throughout loading, alternate-screen wheel
input, text clients, and retained-history preservation. Debug build succeeds
with no warnings; changed-file SwiftLint and formatting pass. Full `make check`
still stops on the five pre-existing RepositoryIconImage aspect-ratio violations.
The current iOS Debug was installed successfully on the connected iPhone 16.
