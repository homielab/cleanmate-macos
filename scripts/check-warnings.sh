#!/usr/bin/env bash
# Compiler warning check: clean-builds Debug (app + test target, build-for-testing) and
# Release into build/warnings, then lists unique Swift/Clang warnings located in the project's own
# sources. Tool noise without a source path (appintentsmetadataprocessor, linker, SDK) is ignored.
# Some warnings (e.g. Swift 6 actor isolation) only show up in Release, which tests never build.
# Usage: scripts/check-warnings.sh   → exit 0 when no warnings, 1 when there are, 2 on build failure.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/CleanMate/"
DD="$ROOT/build/warnings"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

build() { # $1 = configuration, $2 = action
  echo "Building $1 ($2)..."
  xcodebuild -project "$ROOT/CleanMate/CleanMate.xcodeproj" -scheme CleanMate -configuration "$1" \
    -destination 'platform=macOS' -derivedDataPath "$DD" clean "$2" >"$TMP/$1.log" 2>&1 \
    || { tail -20 "$TMP/$1.log"; echo "FAIL: $1 build"; exit 2; }
}
build Debug build-for-testing
build Release build

# Only "<path in the project>:<line>:<col>: warning: ..." lines; the same warning repeats per arch/config.
{
  grep -h -F "$SRC" "$TMP"/*.log | grep -E '^[^ ]+:[0-9]+(:[0-9]+)?: warning: ' | sed "s|^$ROOT/||" || true
  # A warning inside a macro expansion (#expect, #require) starts "macro expansion #expect:…: warning: …"; its place
  # in the project is on the "expanded code originates here" note that follows.
  awk -v src="$SRC" -v root="$ROOT/" '
    /^macro expansion .*: warning: / { msg = $0; sub(/^.*: warning: /, "", msg); next }
    /expanded code originates here/ {
      if (msg != "" && index($0, src)) {
        loc = substr($0, index($0, src) + length(root)); sub(/: note: .*/, "", loc)
        print loc ": warning: " msg " (in a macro expansion)"
      }
      msg = ""
    }' "$TMP"/*.log
} | sort -u >"$TMP/warnings.txt"

N=$(wc -l <"$TMP/warnings.txt" | tr -d ' ')
if [[ $N -gt 0 ]]; then
  cat "$TMP/warnings.txt"
  echo "FAIL: $N warning(s)"
  exit 1
fi
echo "PASS: 0 warnings (Debug + tests, Release)"
