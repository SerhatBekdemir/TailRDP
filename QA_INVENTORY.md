# TailRDP QA Inventory

Sanitized production-scale fixture: `Tests/TailRDPTests/Fixtures/sanitized-production-profiles.json` (40 hosts derived from 3 real linux profiles; android excluded).

Session-end production records: `Tests/TailRDPTests/Fixtures/session-end-production-records.json` (12 curated classify cases; mirrored in `SessionEndClassifier.productionRecords`).

Allowed host OS: `linux`, `windows`, `macOS`, `other` — phones/TV OS values are not RDP candidates.

Run automated checks: `swift test && swift run TailRDP --verify-session`

Sandboxed production-scale GUI run (does not touch real profiles — macOS ignores `$HOME`, use the env override):

```sh
cp Tests/TailRDPTests/Fixtures/sanitized-production-profiles.json /tmp/tailrdp-qa/profiles.json
TAILRDP_DATA_DIR=/tmp/tailrdp-qa dist/TailRDP.app/Contents/MacOS/TailRDP -hasCompletedFirstRun YES -showOffline YES
```

---

## 1. First-run wizard (`FirstRunWizardView`)

| Control | Acceptance criteria | Edge cases |
|---------|---------------------|------------|
| Welcome step | Lists Tailscale + FreeRDP requirements; SSH optional note | — |
| Tailscale step | Shows detected path or install hint; Refresh disabled when not found | Skip when not found; back/forward preserves skip |
| FreeRDP step | Override path field; detected path shown | Skip when not found; invalid override cleared on Settings open |
| Username step | **Continue/Finish disabled** until non-empty trimmed username | Whitespace-only blocked |
| Tailnet step | Peer count after refresh; Finish merges peers | Zero peers allowed; error label on refresh failure |
| Finish | Sets `hasCompletedFirstRun`; dismisses sheet | Re-open via Settings → "Open setup assistant…" |

---

## 2. Main shell (`ContentView`)

| Control | Acceptance criteria | Edge cases |
|---------|---------------------|------------|
| Split view | Sidebar + detail; min 940×620 | — |
| Empty detail | "Select a machine" when no selection | — |
| Dependency banner | Red when Tailscale/FreeRDP missing; Settings action; dismissible | Reappears if deps still missing after dismiss only until deps found |
| Wizard sheet | Auto on first launch | — |
| ⌘R / menu Refresh | Calls `tailscale.refresh()` | — |
| Session end | Async `handleSessionEnd`; generation guard | Rapid reconnect ignores stale async result |

---

## 3. Sidebar (`PeerSidebar`)

| Control | Acceptance criteria | Edge cases |
|---------|---------------------|------------|
| Machine list | All visible profiles; selection highlights row | Offline hidden unless Settings toggle |
| Row icons | Green play = active; blue pause = paused; red = error sticky | — |
| + Add Host | Sheet: name, address, OS picker; validates; selects new host | Duplicate name (case-insensitive id); empty fields |
| Delete (context) | Confirm alert; removes profile + password | Clears selection if deleted host selected |
| Refresh | Disabled while refreshing | — |
| Bottom status | Error / scanning / "N offline hidden" | — |
| Offline filter | `showOffline` toggle in Settings | **Selection moves to visible host** when hiding offline or host goes offline |

---

## 4. Host detail (`HostDetailView`)

| Control | Acceptance criteria | Edge cases |
|---------|---------------------|------------|
| Header | Name, address:port, user; offline wifi-slash when offline + address | Connect enabled when offline but address set |
| Connect / Resume / Disconnect | Prominent; disabled when no address or busy | Credentials sheet when no password |
| Tabs | Connection \| Files | Profile changes auto-save |
| Sticky banners | Paused: non-dismissable, Disconnect ends remote (Linux SSH) | Auth failure → credentials sheet |
| Flash banners | Success auto-dismiss ~5s | — |
| Credentials sheet | Save / Save & Connect; both fields required | Save failure shows inline error |
| Session picker | Linux multi-session resume | Cancel clears connecting state |

---

## 5. Connection settings (`ConnectionSettingsView`)

| Control | Acceptance criteria | Edge cases |
|---------|---------------------|------------|
| Display name / address / port | Editable; port 1–65535 | — |
| Sign-in | Status + "Change sign-in…" | — |
| Connect settings | Last-good / safe-fallback summary; promote button | Disabled when matches last-good |
| Display mode | Fixed / Resizable / Fullscreen; mutual exclusion | Fullscreen clears multimon; legacy conflicting flags normalized on load |
| Resolution | Presets + **custom label** when non-preset | 1366×768 etc. show actual size |
| Codec / network | AVC420 default; help text | Legacy `autoDiagnoseOnFailure` → `smartReconnect` |
| Safe fallback | `usesSafeFallback` (≥2 failures) wins over last-good in header text, settings summary, and launch argv | Header shows orange "Using safe fallback" even when last-good exists |
| Server cert | `/cert:tofu` — pinned on first connect; changed cert → SDL prompt | Cert change mid-automation blocks headless runs (expected) |
| Behavior toggles | Clipboard, audio, ⌘→Ctrl, auto-reconnect, smart reconnect | Linux skips auto-reconnect in argv |
| Advanced (Linux) | Check remote / full reset via SSH | Disabled when no address |
| Launch command | Redacted password in preview | Uses connect settings (last-good when set) |

---

## 6. Files tab (`FileTransferView`)

| Control | Acceptance criteria | Edge cases |
|---------|---------------------|------------|
| Local pane | Home / Up / Reload; double-click dirs | — |
| Remote pane | Same; drag-drop upload | SSH key required; remote $HOME detection |
| Push / Pull | Transfer selected files | Error in status bar |
| lastRemoteDir | Persisted per profile | — |

---

## 7. Settings (`TailscaleSettingsView`)

| Control | Acceptance criteria | Edge cases |
|---------|---------------------|------------|
| Setup assistant | Re-opens wizard | — |
| CLI overrides | Tailscale + FreeRDP paths; invalid paths cleared on appear | — |
| Show offline | Toggles sidebar filter | Reconciles selection |
| Export / Import | JSON bundle; no passwords; merge preserves session state | Unsupported version error; needsPassword list |

---

## 8. About (`AboutView`)

| Control | Acceptance criteria |
|---------|---------------------|
| Version, bundle ID, dep status | Read-only; link to USER_GUIDE |

---

## 9. Data layer

| Component | Acceptance criteria | Edge cases |
|-----------|---------------------|------------|
| `ProfileStore` | Atomic save; merge discovery; flash banners in-memory | Auth sticky cleared on load; paused banner restored |
| `CredentialStore` | `credentials.json` mode 0600; profile id key | Keychain one-time migrate; empty password removes entry |
| Export/import | v1 JSON; passwords excluded | Merge keeps online + session state |

---

## Bug log (this pass)

| ID | Severity | Area | Repro | Status |
|----|----------|------|-------|--------|
| QA-001 | Medium | Sidebar | Hide offline while selected host is offline → detail shows host not in list | **Fixed** — `reconcileSelection` |
| QA-002 | Low | Connection | Import profile with non-preset resolution → picker showed wrong label | **Fixed** — custom resolution tag |
| QA-003 | Low | Docs | HANDOVER/USER_GUIDE still said Keychain for passwords | **Fixed** |
| QA-004 | — | Tests | No production-scale fixture | **Fixed** — 40-host fixture + load tests |
| QA-005 | — | CLI | No live integration runner | **Fixed** — `--qa-integration` |
| QA-006 | Info | Pause | Linux SSH inactive after window close → loggedOut not paused | **Expected** — tri-state SSH verify |
| QA-007 | — | QA tooling | Sandboxed GUI run impossible: macOS resolves home via passwd, `$HOME` override ignored → QA launch read real profiles | **Fixed** — `TAILRDP_DATA_DIR` env override (`AppDataDir`), Keychain migration skipped under override; tests |
| QA-008 | Medium | ProcessRunner | stdin >64KB to a child that exits without reading → SIGPIPE kills the app (latent — no production stdin caller today) | **Fixed** — SIG_IGN + throwing `write(contentsOf:)`; regression test crashed with signal 13 pre-fix |
| QA-009 | — | Tests | Pipe-deadlock fix (91eb661) had no regression test | **Fixed** — concurrent 200KB stdout+stderr drain test |
| QA-010 | Medium | Add Host | Duplicate display name accepted when existing profile has hostname-based id (discovered hosts) → two identical sidebar rows | **Fixed** — case-insensitive displayName check in `addManualHost`; verified in live UI (inline error) |

---

## Live run 2026-06-28 (XPS)

All `--qa-integration xps` checks passed including RDP connect/disconnect and pause window-close (coordinator correctly returned loggedOut when remote session inactive).

## Sandboxed production-scale run 2026-07-20

40-host fixture via `TAILRDP_DATA_DIR`; GUI rendered full sidebar, offline header (wifi-slash + Connect enabled), live Tailscale merge added 3 real peers and correctly marked fixture hosts offline. Real profile store untouched. `swift test` 49/49, `--verify-session` exit 0.

## Live run 2026-07-20 (XPS)

`--qa-integration xps` full pass: classifier checks, Tailscale refresh/merge, SSH $HOME + SFTP listing (47 entries), remote inspect (tri-state inactive), export/import, RDP connect (last-good settings, `/cert:tofu` pinned silently), 6s session, disconnect → loggedOut, pause window-close cycle (remote inactive → loggedOut, expected per QA-006). Exit 0.

## Interactive UI pass 2026-07-20 (Accessibility granted)

Coordinate-driven System Events clicks on sandboxed instance: tab switch Connection↔Files (radio group), Files tab live dual-pane (local home + remote SSH `$HOME` listing), auto-selection of first online host, Add Host sheet (fields, OS picker, Cancel/Add), duplicate-name rejection (QA-010 fix verified — inline error), Settings window (detected CLI paths, tailnet status, offline toggle). Screenshots in `~/Development/genesis/browsepng/tailrdp-qa-*-2026-07-20.png`. Note: `entire contents` AX enumeration hangs on SwiftUI — use coordinate clicks.

---

## Blocked / manual-only

| Item | Reason |
|------|--------|
| Gatekeeper first launch | Manual Finder → Open on unsigned builds |
| SwiftUI visual regression | No XCTest UI target; use sandboxed `TAILRDP_DATA_DIR` run + coordinate-click UI pass (needs Accessibility) |

### Live integration (automated)

```sh
swift run TailRDP --qa-integration xps   # match profile id/display name substring
```

Covers: Tailscale refresh, SSH/SFTP, remote inspect, export/import, RDP connect/disconnect, pause window-close cycle.

---

## Clean pass criteria

- [x] `swift test` — all unit tests pass
- [x] `swift run TailRDP --verify-session` — exit 0
- [x] `swift run TailRDP --qa-integration xps` — live pass on XPS (2026-06-28, 2026-07-20)
- [x] `./build.sh` — release + verify gate
- [x] Production fixture loads without decode errors
- [x] Documented bugs fixed with regression tests
- [x] `dist/TailRDP.app` launches with main window (AppleScript smoke)
