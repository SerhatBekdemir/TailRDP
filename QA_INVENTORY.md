# TailRDP QA Inventory

Status: local sanitized pass complete; live external integration blocked pending explicit approval, updated 2026-07-31.

This is a native macOS SwiftUI desktop app. It has no sign-in screen, account-role model, or URL router:

| Surface | Inventory result |
|---|---|
| User roles | None. Every local macOS user of the app receives the same UI; remote RDP/SSH usernames are per-host data, not app roles. |
| URL routes | None. Navigation is stateful SwiftUI split-view/tab navigation. |
| App scenes | Main `WindowGroup`, `Settings`, and About `Window`. |
| Modal surfaces | First-run wizard, Add Host sheet, Credentials sheet, Remote Session Picker sheet, delete confirmation alert, native import/export panels. |
| External boundaries | Tailscale CLI, FreeRDP process, SSH/SCP, local profile/credential files, legacy Keychain migration. |

## Sanitized production-like data

- Fixture: `Tests/TailRDPTests/Fixtures/sanitized-production-profiles.json`.
- Scale: 40 host profiles; Linux, Windows, macOS, and Other; mixed online/offline states; fullscreen, resizable, custom-resolution, codec, network, and behavior combinations.
- Addresses and usernames are fixture values only; no passwords are included.
- Session corpus: `Tests/TailRDPTests/Fixtures/session-end-production-records.json` (12 sanitized classification cases).
- QA data directory: `TAILRDP_DATA_DIR=/tmp/tailrdp-qa`.
- Local-only UI runs may set `TAILRDP_DISABLE_REMOTE_IO=1`; Files and Linux recovery then return deterministic local errors without opening SSH/SCP.
- For a fixture run, use a separate app identity if another TailRDP instance is already running. The app only honors `-hasCompletedFirstRun` and `-showOffline` when `TAILRDP_DATA_DIR` is set.

Example local run:

```sh
mkdir -p /tmp/tailrdp-qa
cp Tests/TailRDPTests/Fixtures/sanitized-production-profiles.json /tmp/tailrdp-qa/profiles.json
TAILRDP_DATA_DIR=/tmp/tailrdp-qa TAILRDP_DISABLE_REMOTE_IO=1 \
  dist/TailRDP-1.0.3.app/Contents/MacOS/TailRDP-1.0.3 \
  -hasCompletedFirstRun YES -showOffline YES
```

Do not use the live `--qa-integration` path without explicit approval. It reads credentials and connects to a real tailnet host.

## User-facing feature inventory

Each row has a finite acceptance set and finite risk-based edge set. “N/A” means the surface does not exist in this desktop app.

| Area / state | Controls, inputs, modal, or workflow | Acceptance criteria | Finite risk-based edge cases |
|---|---|---|---|
| First run: Welcome | Requirements copy; Continue | Explains Tailscale, FreeRDP, and optional SSH; Continue advances | Missing dependency; SSH unavailable |
| First run: Tailscale | Detection status; Refresh tailnet; Skip; Back | Shows detected path or install hint; Refresh disabled while busy; Skip works when absent; Back preserves progress | CLI missing; CLI exits non-zero; zero peers; refresh twice |
| First run: FreeRDP | Detection status; override path field; Skip; Back | Shows detected/override path; optional override is retained; Skip works when absent | Invalid override; override removed while Settings reopens; CLI missing |
| First run: username | Default username input; Continue/Finish | Trimmed non-empty value required; value applies to new discovered/manual hosts | Empty; whitespace-only; leading/trailing whitespace |
| First run: tailnet/finish | Peer count; Refresh now; Finish | Shows peer count/error; Finish merges discovered peers, marks setup complete, dismisses wizard | Zero peers; refresh failure; finish with dependency skipped |
| Main shell | Sidebar/detail split; min window; empty detail | Sidebar and detail render; empty detail says Select a machine; min size is usable | No profiles; all profiles offline; window at minimum size |
| Main dependency state | Top error banner; Settings action; dismiss | Missing FreeRDP/Tailscale is actionable; configured executable overrides count; resolved dependencies reset prior dismissal | One dependency missing; both missing; invalid override; dependency fixed then missing again |
| Main commands | ⌘R / Refresh Tailnet; About menu; toolbar visibility | Refresh invokes Tailscale; About opens dedicated window; standard toolbar state remains usable | Refresh while busy; CLI failure; duplicate app instance |
| Sidebar list | Host rows; selection; online/offline indicator; active/paused/error icons | All visible profiles render at fixture scale; selection highlights detail; status icon matches session state | 40+ rows; long names; empty address; offline host; state changes while selected |
| Sidebar add host | + button; Add Host sheet; display name; address; OS picker; Add/Cancel | Required fields validated; OS stored; valid host is selected; Cancel makes no change | Empty/whitespace fields; case-insensitive duplicate display name; hostname-based discovered id collision; TEST-NET address |
| Sidebar delete host | Row context menu; confirmation alert; Delete/Cancel | Confirmation names target; Delete removes profile and saved password; selected deletion clears selection; Cancel preserves | Delete selected; delete offline; cancel; stale target after refresh |
| Sidebar filter/status | Settings toggle Show offline; scanning/error/hidden counts | Toggle filters rows and reconciles hidden selection to a visible host; status explains scanning, errors, or count hidden | Selected host becomes offline; no visible hosts; refresh failure; toggle during refresh |
| Host header | OS icon; name/address/port/user; offline indicator; Connect/Resume/Disconnect | Header reflects profile; offline with saved address remains connectable; active session exposes Disconnect; paused/error exposes correct action | Empty address; port boundary; offline; safe fallback active; stale session completion |
| Credentials sheet | Username input; password input; Save; Save & Connect; Cancel | Confirm disabled until username trimmed non-empty and password non-empty; save is local; Save & Connect continues | Whitespace username; empty password; save failure; auth-failure re-entry; cancel clears pending connect |
| Session picker | Linux session list; per-session Resume; Cancel | Multiple remote session IDs are selectable; selected session is kept and others are ended; Cancel clears connecting state | Zero/one/multiple IDs; duplicate IDs; inspect failure; cancel during pending inspect |
| Host tabs | Connection / Files segmented control | Tab switches without losing profile edits; connection/file state is scoped to selected host | Rapid tab switching; switching host with pending remote load; host deleted while detail open |
| Connection profile | Display name; address; port stepper | Edits auto-save; port constrained to 1–65535 | Empty/whitespace address; min/max port; rapid edits; invalid imported profile |
| Connect settings | Sign-in status; Change sign-in; last-good/safe-fallback summary; promote current | Summary matches actual launch settings; promote records current settings and clears failure state; safe fallback wins after repeated failures | No password; last-good exists with fallback active; promotion while active; stale last-good |
| Display settings | Display mode picker; resolution picker/custom label; multimon toggle; bpp picker | Fixed/resizable/fullscreen are mutually normalized; custom sizes display actual value; fullscreen clears multimon | 1366×768 custom; legacy conflicting flags; fullscreen with custom size; resizable hides resolution/multimon |
| Performance/behavior | Codec/network pickers; clipboard/audio/⌘→Ctrl/auto-reconnect/smart-reconnect toggles | Settings persist and map to preview/launch args; Linux omits auto-reconnect; help text explains behavior | Each codec/network option; toggles off; Linux vs non-Linux; repeated failure fallback |
| Linux advanced | Disclosure; Check remote host; Full remote session reset; SSH username | Controls only appear for Linux; disabled without address/busy; results are readable; remote reset is explicit | SSH absent; remote error; busy/repeated click; non-Linux host |
| Launch command | Editable full FreeRDP command; Reset to generated; validation message | Custom command persists per host and is used on Connect; generated settings remain the reset path; `/p:` is redacted and the saved credential is injected only at launch; malformed commands are blocked | No password; password saved; reset; quoted argument; unmatched quote; missing `/v:` target; safe fallback; unusual address |
| Files: local pane | Home/Up/Reload; local list; double-click directory; selection | Lists non-hidden local entries; navigation works; directory double-click enters; reload refreshes | Empty directory; inaccessible directory; root/home; long names; stale selection |
| Files: remote pane | Home/Up/Reload; remote list; double-click directory; Retry | Resolves remote `$HOME`; navigation remains absolute; failures show Retry and no stale entries | SSH unavailable; empty listing; `/home` vs `/Users`; path with spaces; load cancellation |
| Files: transfer | Push arrow; Pull arrow; drag/drop upload; busy/status bar | Selected items transfer; controls disable while busy; success/error is visible; drop accepts local file URLs | Empty selection; multi-select; transfer failure; duplicate destination; concurrent drop/click |
| Settings | Open setup assistant; Tailscale/FreeRDP override fields; Effective paths | Invalid overrides clear on appear; effective path matches executable override; wizard reopens | Missing binary; executable non-tool; path cleared; Settings opened repeatedly |
| Settings: tailnet | This machine/IP; online count; Show offline; Refresh now | Values reflect latest safe discovery result; refresh disables while busy | CLI failure; zero peers; malformed JSON; refresh generation race |
| Settings: profiles | Export; Import; native save/open panels; status text | Export is v1 JSON without passwords; import merges by id and preserves local session state; unsupported/invalid OS records are rejected/skipped; needs-password list is accurate | Duplicate id; unsupported version; malformed JSON; non-RDP OS; missing password; cancelled panel |
| About | Version, bundle id, dependency status, guide note | Read-only status is accurate; About opens from menu | Missing dependency; ad-hoc bundle; long paths |
| Persistence | profiles.json atomic save; credentials.json mode 0600; flash/sticky banners | Edits survive reload; passwords are excluded from export; flash success auto-dismisses; pause/error state survives reload | Disk write failure; rapid edits; empty password removes; stale auth banner; app backgrounding |
| Session lifecycle | Connect; launch; pause/crash/logout classification; reconnect; disconnect | Logged out clears sticky state; pause/error produces correct sticky banner; stale async result cannot overwrite newer state; successful session records last-good settings | Rapid reconnect; process signal; auth failure; window close; SSH state unknown; repeated failures |

## Risk-based workflow passes

| Workflow | Required checkpoints |
|---|---|
| First launch | Wizard opens; dependencies can be skipped; whitespace username blocked; finish persists setup; wizard cannot be dismissed prematurely |
| Discover and filter | Fixture loads; 40 rows render; online/offline filter changes list; selected hidden host reconciles; CLI failure is visible |
| Add/edit/delete | Required validation; duplicate display-name collision; valid host selection; profile edit persistence; delete confirmation and credential removal |
| Configure connection | All display/performance/behavior states; custom resolution; safe fallback and last-good precedence; editable/redacted launch command |
| Credentials | Save disabled/enabled boundaries; Save; Save & Connect; auth-failure recovery; cancel cleanup |
| Files | Local-only pane navigation; remote failure/Retry boundary; absolute Home fallback; push/pull/drop empty and busy states |
| Import/export | Password exclusion; round trip; merge session state; duplicate/unsupported/non-RDP handling; native panel cancel |
| Session state | Paused, crashed, logged out, active, stale async generation; sticky/flash banner rules |

## Evidence from this pass

- `swift test`: baseline 49/49 passed before changes.
- `swift run TailRDP --verify-session`: baseline session corpus and script-pin checks passed.
- `./build.sh`: release app bundle built; built-in session verification passed.
- Sanitized fixture loaded and rendered 40 fixture rows through the macOS accessibility tree.
- Interactive local checks: Add Host empty-field error; case-insensitive duplicate-name error; valid sanitized host creation; Settings dependency override display; launch preview redaction; Files tab local pane and deterministic remote-I/O error boundary.
- First-run local checks: Welcome, dependency steps, whitespace username blocked, valid username advance, tailnet error state, Finish closes the wizard and reveals the main shell without reopening.
- Interactive isolation finding: an already-running `app.tailrdp` instance caused a same-bundle QA launch to expose non-fixture hosts. The remaining pass uses a separate `app.tailrdp.qa` identity plus `/usr/bin/false` overrides for Tailscale/FreeRDP.

## Bug log

| ID | Severity | Area | Reproduction evidence | Fix / status |
|---|---|---|---|---|
| QA-001–QA-010 | Historical | Sidebar, settings, docs, ProcessRunner, QA tooling | Existing inventory records and regression tests | Fixed or expected as documented in repository history |
| QA-011 | Medium | Dependency banner | Set a valid Tailscale override while auto-detected Tailscale is absent; `ContentView` checked `override: nil`, so the banner still reported missing. Dismiss once, resolve, then lose the dependency; persistent dismissal hid the banner. | Fixed: shared dependency calculation honors both overrides; dismissal resets when resolved. Regression test covers executable overrides. |
| QA-012 | Medium | Files / Remote Home | With remote path `/home/qa-user/projects`, Home fallback used `split(...).prefix(3).joined(...)`, producing `home/qa-user/projects` without a leading slash and without returning the user home. | Fixed: absolute `/home/qa-user` or `/Users/qa-user` fallback. Regression tests cover both families and fallback. |
| QA-013 | Medium | Import | A v1 bundle containing an `android` profile was accepted into the live store until a later reload. | Fixed: import skips non-RDP-capable OS records and reports them as skipped. Regression test added. |
| QA-014 | Info | QA harness | Launching the same bundle id as an existing TailRDP instance attached QA observation to a non-sanitized running instance. | Contained: QA runbook now requires a separate app identity; fixture flags are scoped to `TAILRDP_DATA_DIR`. No production instance was modified. |
| QA-015 | Medium | QA external boundary | Selecting Files automatically started SSH against a fixture-looking address before the remote pane could show an error. | Fixed for local QA: `TAILRDP_DISABLE_REMOTE_IO=1` makes SSH/SCP/recovery return a deterministic local error. Live remote validation remains approval-gated. |
| QA-016 | Medium | First-run wizard | Finish wrote `hasCompletedFirstRun=1`, but the parent dismissal callback could see the stale `false` value and immediately reopen the wizard. | Fixed: removed the redundant race-prone reopen observer; `interactiveDismissDisabled` remains the pre-finish guard. Finish is rerun in isolated QA. |

## Blocked / manual-only

| Item | Reason |
|---|---|
| Live Tailscale/SSH/SFTP/RDP integration | Not run in this pass. It would read credentials and connect to a real host; approval is required before sensitive or production-like external access. |
| Gatekeeper first launch | Requires manual Finder → Open for unsigned/ad-hoc builds. |
| Full visual regression | No XCTest UI target; accessibility-driven local UI pass plus screenshots is the available verification path. |

## Clean pass criteria

- [x] `swift test` passes after fixes.
- [x] `swift run TailRDP --verify-session` exits 0 after fixes (also included in `./build.sh`).
- [x] Release app builds with `./build.sh`.
- [x] Fixture loads with exactly 40 valid local profiles and no credential leakage.
- [x] All inventory rows have either pass evidence or an explicit blocked/manual-only disposition.
- [x] No unresolved medium/high local findings remain; live external integration remains approval-gated.
