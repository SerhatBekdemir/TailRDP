---
name: run-tailrdp
description: Build, run, test, and screenshot TailRDP — the native macOS SwiftUI RDP client. Use when asked to run, launch, start, build, test, verify, or screenshot the TailRDP app, or to confirm a change works in the real running app (not just tests). macOS only.
---

# Run TailRDP

TailRDP is a **native macOS SwiftUI** app (SwiftPM executable, no Xcode project). There is
no Playwright/Electron REPL — the programmatic surfaces are three CLI flags plus a
window-scoped screenshot of the live GUI. Everything is wrapped by the driver:

    .claude/skills/run-tailrdp/driver.sh

Paths below are relative to the repo root (`<unit>` = the TailRDP repo). **macOS only**
(Apple Silicon, macOS 15+); nothing here runs on Linux.

## Prerequisites

- **Full Xcode** (not just Command Line Tools) — `swift test` needs XCTest.
  Verified with Xcode 26.6, Swift 6.3.3.
  ```sh
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer   # if needed
  ```
- **FreeRDP** (`sdl-freerdp`) and **Tailscale.app** — only needed for the live GUI
  connect flow and `qa`, NOT for build/verify/test/screenshot.
  ```sh
  brew install freerdp        # provides sdl-freerdp (verified 3.27.1)
  ```

## Run (agent path) — use the driver

The driver `cd`s to the repo root itself, so it works from anywhere:

```sh
.claude/skills/run-tailrdp/driver.sh verify        # logic smoke — no UI, no network, no perms
.claude/skills/run-tailrdp/driver.sh test          # 43 XCTest cases (needs full Xcode)
.claude/skills/run-tailrdp/driver.sh build         # swift build (debug)
.claude/skills/run-tailrdp/driver.sh all           # build + verify + test
.claude/skills/run-tailrdp/driver.sh screenshot    # launch GUI, capture window, quit
.claude/skills/run-tailrdp/driver.sh app           # release .app bundle + verify gate
```

**For most code changes, `verify` + `test` is the whole loop** — both run in <2s and
need no display, no permissions, no external services. `verify` runs
`SessionEndClassifier.runBuiltInChecks()` (pause/logout/crash classification, banner
mapping, recovery matrix, remote-script SHA256 pins); exit 0 = pass.

### Screenshot the live GUI

```sh
.claude/skills/run-tailrdp/driver.sh screenshot [out.png]
```

Launches `dist/TailRDP.app` (building it first if missing), finds the window via
CoreGraphics, captures it with `screencapture -l`, and quits. Output defaults to
`$TMPDIR/tailrdp-screenshot.png`. **Then `Read` the PNG to confirm it rendered** —
you should see the "Tailnet Machines" sidebar and the host detail pane. If the app has
saved profiles, it opens straight to the main UI; with no saved state it shows the
first-run wizard instead (both are valid screenshots).

### Direct invocation (no driver)

Every driver command is a thin wrapper — call the underlying command when you want:

```sh
swift run TailRDP --verify-session            # == driver.sh verify
swift test                                    # == driver.sh test
swift build                                   # == driver.sh build
```

### Live tailnet integration (intrusive — has side effects)

```sh
.claude/skills/run-tailrdp/driver.sh qa aegis-resolute
# == swift run TailRDP --qa-integration <hostMatch>
```

Runs against a **real** saved profile: refreshes Tailscale, SSHes to the host, opens an
actual FreeRDP session, then disconnects and runs a pause/resume cycle. It opens real RDP
windows and touches live machines — only run it deliberately, against a host that is
online, and expect the pause-cycle step to need Accessibility permission (see Gotchas).

## Run (human path)

```sh
swift run TailRDP        # launches the GUI, BLOCKS the terminal until you Ctrl-C
open dist/TailRDP.app    # detached; shell returns immediately (what the driver uses)
```

`swift run TailRDP` (bare) is the human path — it holds the terminal open. Use `open` on
the bundle for anything scripted.

## Gotchas

- **Full-screen `screencapture` is blocked; window-scoped works.** `screencapture -x`
  fails with `could not create image from display` (TCC Screen Recording consent for the
  controlling terminal). But `screencapture -l <windowid>` of a specific window
  **succeeds** without that prompt — which is exactly what the driver does. Don't "fix"
  it by trying to grant Screen Recording; the window path already works.
- **Get the window id from CoreGraphics, not AppleScript.** The driver enumerates
  `CGWindowListCopyWindowInfo` (metadata only — no permission) to get the CGWindowID.
  AppleScript can't hand you a CGWindowID, and it needs Accessibility anyway.
- **No programmatic UI clicking.** `osascript`/System Events → `not allowed assistive
  access (-1728)` unless the terminal is granted Accessibility (interactive-only prompt).
  So you cannot click tabs/buttons or send keystrokes from a headless session. Screenshot
  the launch state; that's the interaction you get without a granted TCC prompt.
- **`--qa-integration` pause-cycle depends on Accessibility.** Its `closeFreeRDPWindow`
  uses System Events `AXPress` to close the FreeRDP window. Without Accessibility granted,
  the pause test fails even though the classification logic is fine — the failure is the
  permission, not the code.
- **First-run wizard vs main UI.** The wizard only appears when there's no saved state in
  `~/Library/Application Support/TailRDP/`. On a machine that has used the app, launch
  goes straight to the main window. **Do not delete that directory to force the wizard** —
  it's the user's real profiles and saved connect settings.
- **Unsigned / ad-hoc build.** `build.sh` ad-hoc signs (`codesign --sign -`). `open
  dist/TailRDP.app` from the terminal launches fine; a Finder double-click needs
  right-click → Open once (Gatekeeper). The driver always uses `open`, so this never bites.
- **`swift run TailRDP` blocks.** It's a GUI app — bare `swift run` never returns. For
  screenshots the driver uses `open` on the bundle so the shell continues.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `could not create image from display` | You tried a full-screen grab. Use window-scoped `screencapture -l <id>` (the driver does this). |
| `osascript is not allowed assistive access (-1728)` | Accessibility not granted to the terminal. UI-clicking and `qa` pause-cycle are unavailable headless; grant in System Settings → Privacy & Security → Accessibility (interactive only). |
| `swift test` → `no such module 'XCTest'` | `xcode-select` points at Command Line Tools. `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`. |
| `screenshot` → "window never appeared" | App crashed on launch. Run `swift run TailRDP` in the foreground to see stderr, or check Console.app filtered to `subsystem:app.tailrdp`. |
| `qa` → "no profile matching …" | The match string isn't in saved profiles. Launch the GUI once to see profile names, or pass a substring of an existing display name. |
