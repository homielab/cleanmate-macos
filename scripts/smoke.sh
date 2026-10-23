#!/usr/bin/env bash
# Launch smoke test: the real app must open exactly one main window, and opening it again must
# not start a second process. Runs three launch configurations on one build:
# default, Vietnamese UI (-AppleLanguages (vi)) and menu bar icon on (-showMenuBarExtra YES;
# the status item itself is not checked: with the screen locked no app's status item appears in
# CGWindowList at any layer, so it cannot be measured). No GUI interaction, no scan, no clean.
# Works with the screen locked: CGWindowList owner/layer/bounds need no Screen Recording permission.
# Usage: scripts/smoke.sh [path/to/CleanMate.app]   (default: Debug build into build/smoke)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOMAIN="com.homielab.CleanMate"
TIMEOUT="${SMOKE_TIMEOUT:-20}"
TMP="$(mktemp -d)"
APP="${1:-}"

if [[ -z "$APP" ]]; then
  echo "Building Debug..."
  xcodebuild -project "$ROOT/CleanMate/CleanMate.xcodeproj" -scheme CleanMate -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$ROOT/build/smoke" build >"$TMP/build.log" 2>&1 \
    || { tail -20 "$TMP/build.log"; echo "FAIL: build"; exit 1; }
  APP="$ROOT/build/smoke/Build/Products/Debug/CleanMate.app"
fi
APP="$(cd "$APP" && pwd)"
EXE="$APP/Contents/MacOS/$(defaults read "$APP/Contents/Info" CFBundleExecutable)"

# Counts on-screen, layer-0 (normal) windows of one PID; menu bar items and the status item are other layers.
cat >"$TMP/count.swift" <<'SWIFT'
import CoreGraphics
let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
print(list.filter { $0[kCGWindowOwnerPID as String] as? Int32 == pid && $0[kCGWindowLayer as String] as? Int == 0 }.count)
SWIFT
xcrun swiftc -O -o "$TMP/count" "$TMP/count.swift"

# The app writes real defaults (e.g. window frame); restore them afterwards.
HAD_DEFAULTS=0
defaults export "$DOMAIN" "$TMP/defaults.plist" 2>/dev/null && HAD_DEFAULTS=1

PID=""
# Only ever stop the process this script launched, never another CleanMate the user has open.
stop_app() {
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID"
    for _ in $(seq 50); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
    kill -9 "$PID" 2>/dev/null || true
  fi
  PID=""
}
cleanup() {
  stop_app
  if [[ $HAD_DEFAULTS == 1 ]]; then defaults import "$DOMAIN" "$TMP/defaults.plist"; else defaults delete "$DOMAIN" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT

pids() { ps -axo pid=,comm= | awk -v exe="$EXE" 'substr($0, index($0, $2)) == exe { print $1 }' | sort; }
# Polls until the window count of $PID reaches $1 or the timeout passes; prints the last count.
wait_windows() {
  local n=0 end=$((SECONDS + TIMEOUT))
  while (( SECONDS < end )); do
    n="$("$TMP/count" "$PID")"
    (( n >= $1 )) && break
    sleep 0.5
  done
  echo "$n"
}

FAIL=0
fail() { echo "FAIL: $*"; FAIL=1; }

# One launch configuration: $1 = label, rest = extra launch arguments.
# Launch arguments only shadow defaults for this run: no Full Disk Access sheet, no restored windows.
run_config() {
  local label="$1"; shift
  local args=(--args -fullDiskAccessPrompted YES -ApplePersistenceIgnoreState YES "$@")
  local before n extra
  echo "== $label"
  before="$(pids)"
  open -n "$APP" "${args[@]}"
  for _ in $(seq $((TIMEOUT * 10))); do
    PID="$(comm -13 <(echo "$before") <(pids) | head -1)"
    [[ -n "$PID" ]] && break
    sleep 0.1
  done
  [[ -n "$PID" ]] || { fail "app did not start"; return; }

  n="$(wait_windows 1)"
  sleep 1; n="$("$TMP/count" "$PID")"  # settle: a second window would show up late
  if [[ "$n" == 1 ]]; then echo "ok: launch shows 1 window"; else fail "launch shows $n windows (want 1)"; fi

  open "$APP" "${args[@]}"  # reopen the running app (no -n)
  sleep 2
  n="$("$TMP/count" "$PID")"
  extra="$(comm -13 <(echo "$before") <(pids) | grep -vx "$PID" || true)"
  if [[ "$n" == 1 ]]; then echo "ok: reopen keeps 1 window"; else fail "reopen shows $n windows (want 1)"; fi
  if [[ -z "$extra" ]]; then echo "ok: reopen starts no new process"; else fail "reopen started process $extra"; fi
  stop_app
}

run_config "default"
run_config "Vietnamese" -AppleLanguages "(vi)"
run_config "menu bar icon on" -showMenuBarExtra YES

if (( FAIL )); then echo "FAIL"; exit 1; fi
echo "PASS"
