#!/usr/bin/env bash
# TailRDP driver — build, verify, test, and screenshot the running macOS app.
# Native SwiftUI app: there is no Playwright/Electron REPL. The programmatic
# surfaces are CLI verify modes (--verify-session / --qa-integration) plus a
# window-scoped screencapture of the live GUI. macOS only.
#
# Usage: driver.sh <command> [args]
#   build              swift build (debug)
#   verify             swift run TailRDP --verify-session   (logic smoke, no UI/net/perms)
#   test               swift test                           (43 XCTest cases; needs full Xcode)
#   app                ./build.sh                           (release .app + verify gate)
#   screenshot [out]   launch dist/TailRDP.app, capture its window, quit
#                      out defaults to $TMPDIR/tailrdp-screenshot.png
#   qa <hostMatch>     swift run TailRDP --qa-integration <hostMatch>  (LIVE; intrusive)
#   all                build + verify + test
set -euo pipefail
cd "$(dirname "$0")/../../.."   # -> repo root (<unit>)
ROOT="$PWD"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERR\033[0m %s\n' "$*" >&2; exit 1; }

cmd_build()  { log "swift build"; swift build; }
cmd_verify() { log "swift run TailRDP --verify-session"; swift run TailRDP --verify-session; }
cmd_test()   { log "swift test"; swift test; }
cmd_app()    { log "./build.sh (release bundle + verify gate)"; ./build.sh; }

# Enumerate the TailRDP on-screen window via CoreGraphics (metadata only — no
# Screen Recording permission). Prints "<windowid> <x> <y> <w> <h>" or nothing.
_find_window() {
  swift - <<'SWIFT' 2>/dev/null
import CoreGraphics
import Foundation
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let arr = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { exit(1) }
for w in arr where (w[kCGWindowOwnerName as String] as? String ?? "").contains("TailRDP") {
  let num = w[kCGWindowNumber as String] as? Int ?? -1
  let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
  print("\(num) \(Int(b["X"] ?? 0)) \(Int(b["Y"] ?? 0)) \(Int(b["Width"] ?? 0)) \(Int(b["Height"] ?? 0))")
  exit(0)
}
exit(1)
SWIFT
}

cmd_screenshot() {
  local out="${1:-${TMPDIR:-/tmp}/tailrdp-screenshot.png}"
  [ -d "$ROOT/dist/TailRDP.app" ] || { log "no bundle — building"; ./build.sh >/dev/null; }

  log "launching dist/TailRDP.app"
  open "$ROOT/dist/TailRDP.app"

  local info="" id x y w h
  for _ in $(seq 1 30); do
    info="$(_find_window || true)"
    [ -n "$info" ] && break
    sleep 0.5
  done
  [ -n "$info" ] || die "TailRDP window never appeared (crash on launch? run 'driver.sh verify' or 'swift run TailRDP' in foreground for stderr)"
  read -r id x y w h <<<"$info"
  log "window id=$id bounds=${x},${y} ${w}x${h}"

  # Window-scoped capture works even when full-display capture is TCC-blocked.
  screencapture -o -x -l "$id" "$out" || die "screencapture failed"
  [ -s "$out" ] || die "screenshot empty: $out"
  log "screenshot: $out ($(file -b "$out"))"

  osascript -e 'quit app "TailRDP"' >/dev/null 2>&1 || true
  sleep 1
  pgrep -x TailRDP >/dev/null && pkill -x TailRDP || true
  log "quit"
}

cmd_qa() {
  [ $# -ge 1 ] || die "usage: driver.sh qa <hostMatch>"
  log "swift run TailRDP --qa-integration $1  (LIVE — opens real RDP/SSH sessions)"
  swift run TailRDP --qa-integration "$1"
}

cmd_all() { cmd_build; cmd_verify; cmd_test; }

case "${1:-}" in
  build)      cmd_build ;;
  verify)     cmd_verify ;;
  test)       cmd_test ;;
  app)        cmd_app ;;
  screenshot) shift; cmd_screenshot "$@" ;;
  qa)         shift; cmd_qa "$@" ;;
  all)        cmd_all ;;
  *) die "usage: driver.sh {build|verify|test|app|screenshot [out]|qa <host>|all}" ;;
esac
