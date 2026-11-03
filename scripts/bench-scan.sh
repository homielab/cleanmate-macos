#!/usr/bin/env bash
# Smart Scan timing per item: runs `cleanmate scan --json` several times (read-only: nothing is cleaned)
# and prints each item's median `durationMs`, slowest first, with the size and entries it found.
# A size that changed between runs is marked with `*` (a cache or log written meanwhile).
# Items are scanned at the same time, so their times overlap; the total is the wall time of the scan.
#
# Usage: scripts/bench-scan.sh [-n RUNS] [-c path/to/cleanmate] [-- scan options…]
#   -n RUNS   runs to take the median of (default 3)
#   -c PATH   the tool to time (default: Release build into build/DerivedData, signed ad hoc)
#   -j DIR    also keep each run's JSON in DIR (to compare two builds)
#   scan options go to `cleanmate scan`, e.g. `-- --group dev` or `-- --only xcode-derived-data`.
# Full Disk Access is the terminal's: without it, protected folders are skipped (as in `cleanmate scan`).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNS=3
CLI=""
KEEP=""
while getopts "n:c:j:h" opt; do
  case "$opt" in
    n) RUNS="$OPTARG" ;;
    c) CLI="$OPTARG" ;;
    j) KEEP="$OPTARG" ;;
    *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "-n needs a positive number" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -r "$TMP"' EXIT

if [[ -z "$CLI" ]]; then
  echo "Building Release…" >&2
  xcodebuild -project "$ROOT/CleanMate/CleanMate.xcodeproj" -scheme CleanMate -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$ROOT/build/DerivedData" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build >"$TMP/build.log" 2>&1 \
    || { tail -20 "$TMP/build.log" >&2; echo "build failed" >&2; exit 1; }
  CLI="$ROOT/build/DerivedData/Build/Products/Release/CleanMate.app/Contents/Helpers/cleanmate"
fi
[[ -x "$CLI" ]] || { echo "not an executable: $CLI" >&2; exit 2; }

for run in $(seq 1 "$RUNS"); do
  echo "Run ${run}/${RUNS}…" >&2
  "$CLI" scan --json "$@" >"$TMP/run-$run.json"
done
[[ -z "$KEEP" ]] || { mkdir -p "$KEEP"; cp "$TMP"/run-*.json "$KEEP"/; }

echo "load average: $(sysctl -n vm.loadavg | tr -d '{}' | xargs), $RUNS runs, median"
jq -rs '
  def median: sort | if length % 2 == 1 then .[length / 2 | floor] else (.[length / 2 - 1] + .[length / 2]) / 2 | floor end;
  def secs: (. / 10 | round / 100 | tostring) + " s";
  def mb: (. / 100000 | round / 10 | tostring) + " MB";
  (map(.items[]) | group_by(.id) | map({
     id: .[0].id,
     ms: (map(.durationMs // 0) | median),
     size: .[-1].size,
     entries: (.[-1].entries | length) + (.[-1].moreEntries // 0),
     changed: (map(.size) | unique | length > 1)
   }) | sort_by(-.ms)) as $items
  | ["item", "time", "size", "entries"],
    ($items[] | [.id, (.ms | secs), (.size | mb) + (if .changed then " *" else "" end), (.entries | tostring)]),
    ["total", (map(.durationMs // 0) | median | secs), ($items | map(.size) | add // 0 | mb),
     ($items | map(.entries) | add // 0 | tostring)]
  | @tsv' "$TMP"/run-*.json | column -t -s $'\t'
