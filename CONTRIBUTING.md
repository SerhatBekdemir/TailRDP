# Contributing to TailRDP

Development workflow for building, testing, and changing TailRDP locally.

---

## Prerequisites

| Tool | Notes |
|------|-------|
| macOS 15+ | Matches deployment target |
| **Full Xcode** | Required for `swift test` (Command Line Tools alone lack XCTest) |
| Swift 6 toolchain | Via Xcode |
| Tailscale + FreeRDP | Optional for manual testing; not needed for build/verify |

---

## Getting started

```sh
git clone <repo> TailRDP && cd TailRDP
swift build
swift run TailRDP --verify-session
```

Run the app:

```sh
swift run TailRDP
# or
./build.sh && open TailRDP.app
```

Install to Applications:

```sh
INSTALL=1 ./build.sh
```

---

## Project structure

Swift Package Manager executable — no Xcode project file. Sources under `Sources/TailRDP/`, tests under `Tests/TailRDPTests/`.

See [HANDOVER.md](HANDOVER.md) for architecture and module map.

---

## Build variants

| Command | Output |
|---------|--------|
| `swift build` | Debug binary in `.build/` |
| `swift build -c release` | Release binary |
| `./build.sh` | Release arm64 `TailRDP.app` + `dist/TailRDP.app` + verify gate |
| `INSTALL=1 ./build.sh` | Above + copy to `/Applications` |

`build.sh` always runs `--verify-session` before packaging. Build artifacts (`.build/`, `*.app/`, `dist/`) are gitignored.

---

## Testing

### Unit tests

```sh
swift test
```

Coverage includes:

- `SessionEndClassifier` — pause/logout/crash
- `ProfileStore.merge` — discovery merge, offline marking
- `RemoteDisplayRecovery.chooseRecovery` — preset matrix
- `RemoteScriptLoader` — SHA256 pin consistency
- `RDPLauncher.buildArguments` — Linux skips auto-reconnect, stdin flag
- `ProfileExport` — export/import round-trip

### Session smoke test (no XCTest)

```sh
swift run TailRDP --verify-session
```

Runs built-in checks in `SessionEndClassifier.runBuiltInChecks()`. Used in `build.sh` and CI. Exit code 0 = pass.

### Manual testing checklist

- [ ] Wizard: Tailscale + FreeRDP detection
- [ ] Connect / Disconnect Windows or Linux host
- [ ] Close RDP window → blue paused banner → Resume
- [ ] Linux: SSH inspect + reset (Advanced)
- [ ] File transfer with key-based SSH
- [ ] Export/import profiles; re-enter password
- [ ] Offline host with saved address

---

## CI

`.github/workflows/ci.yml` runs on push/PR to `main`/`master`:

1. `swift build`
2. `swift test`
3. `swift run TailRDP --verify-session`

Runs on `macos-15` with Xcode selected. Local development does not require pushing to GitHub.

---

## Conventions

### Code style

- Match existing patterns: `@MainActor` services, `Task.detached` for blocking I/O
- Pure logic in `Logic/` — no I/O, easy to test
- Minimal scope in PRs; avoid drive-by refactors
- Comments only for non-obvious behavior

### Identifiers

- Bundle ID / credential service name: `app.tailrdp`
- Profile id: lowercased hostname or manual display name

### Adding a remote script

1. Add or edit file under `Sources/TailRDP/RemoteScripts/`
2. `shasum -a 256 Sources/TailRDP/RemoteScripts/<file>`
3. Update `expectedHashes` in `RemoteScriptLoader.swift`
4. Run `swift run TailRDP --verify-session`
5. Document behavior in [HANDOVER.md](HANDOVER.md) and [SECURITY.md](SECURITY.md) if trust-relevant

### Changing session classification

1. Update `SessionEndClassifier.classify`
2. Add/update tests in `TailRDPTests.swift`
3. Add case to `runBuiltInChecks()` if regression-critical
4. Update [USER_GUIDE.md](USER_GUIDE.md) banner table if user-visible

---

## Logging while developing

Console.app → filter `subsystem:app.tailrdp`.

Categories: `tailscale`, `rdp`, `ssh`, `session`. See [HANDOVER.md](HANDOVER.md#logging).

---

## Documentation

When changing user-visible behavior, update:

- [USER_GUIDE.md](USER_GUIDE.md) — users
- [HANDOVER.md](HANDOVER.md) — developers
- [SECURITY.md](SECURITY.md) — trust boundaries
- [CHANGELOG.md](CHANGELOG.md) — notable changes
- [README.md](README.md) — if quick-start or feature list affected

---

## License

Contributions are accepted under the project [Apache License 2.0](LICENSE). By contributing, you agree your changes may be licensed under those terms.
