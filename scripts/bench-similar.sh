#!/usr/bin/env bash
# Similar Photos on a large library: writes a reproducible set of photos (scripts/similar-photos-fixture.swift:
# unrelated scenes plus groups of resized, recompressed, cropped, brightened copies and burst frames, as JPEG, HEIC
# and PNG), runs `cleanmate similar` on it several times and prints the median time, the peak memory and how many of
# the generated groups were found exactly. The digest of the groups found is the same for two builds that group alike.
# Every run analyzes every photo: the tool reads the app's feature print cache, which never has these files.
# The photos are written in build/ (the tool only searches the home folder) and deleted at the end.
#
# Usage: scripts/bench-similar.sh [-n RUNS] [-p PHOTOS] [-s LONG_SIDE] [-c path/to/cleanmate]…
#   -n RUNS       runs per tool to take the median of (default 3)
#   -p PHOTOS     photos to write (default 2000; about 1 MB each at the default size)
#   -s LONG_SIDE  pixels of the long side of an original photo (default 2400)
#   -c PATH       a tool to time (default: Release build into build/DerivedData, signed ad hoc); twice or more to
#                 compare builds on the same photos, their runs taken in turn
set -euo pipefail
export LC_ALL=C # byte order for sort and comm, as the fixture sorts

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNS=3
PHOTOS=2000
SIDE=2400
TOOLS=()
while getopts "n:p:s:c:h" opt; do
  case "$opt" in
    n) RUNS="$OPTARG" ;;
    p) PHOTOS="$OPTARG" ;;
    s) SIDE="$OPTARG" ;;
    c) TOOLS+=("$OPTARG") ;;
    *) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
done
for value in "$RUNS" "$PHOTOS" "$SIDE"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || { echo "-n, -p and -s need a positive number" >&2; exit 2; }
done

mkdir -p "$ROOT/build"
TMP="$(mktemp -d "$ROOT/build/similar-bench.XXXXXX")"
trap 'rm -r "$TMP"' EXIT

if [[ ${#TOOLS[@]} -eq 0 ]]; then
  echo "Building Release…" >&2
  xcodebuild -project "$ROOT/CleanMate/CleanMate.xcodeproj" -scheme CleanMate -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$ROOT/build/DerivedData" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build >"$TMP/build.log" 2>&1 \
    || { tail -20 "$TMP/build.log" >&2; echo "build failed" >&2; exit 1; }
  TOOLS=("$ROOT/build/DerivedData/Build/Products/Release/CleanMate.app/Contents/Helpers/cleanmate")
fi
for tool in "${TOOLS[@]}"; do [[ -x "$tool" ]] || { echo "not an executable: $tool" >&2; exit 2; }; done

echo "Writing $PHOTOS photos…" >&2
xcrun swiftc -O "$ROOT/scripts/similar-photos-fixture.swift" -o "$TMP/fixture" 2>"$TMP/fixture.log" \
  || { cat "$TMP/fixture.log" >&2; exit 1; }
"$TMP/fixture" "$TMP/photos" "$PHOTOS" "$SIDE" >&2
echo "photos: $(du -sh "$TMP/photos" | cut -f1) on disk, load average $(sysctl -n vm.loadavg | tr -d '{}' | xargs)"

for run in $(seq 1 "$RUNS"); do
  for t in "${!TOOLS[@]}"; do
    echo "Run ${run}/${RUNS}, tool $((t + 1))…" >&2
    /usr/bin/time -l "${TOOLS[$t]}" similar "$TMP/photos" --json --limit 1000000 \
      >"$TMP/run-$t-$run.json" 2>"$TMP/time-$t-$run.txt"
  done
done

REAL="$(cd "$TMP/photos" && pwd -P)"
for t in "${!TOOLS[@]}"; do
  echo
  echo "tool $((t + 1)): ${TOOLS[$t]}"
  for run in $(seq 1 "$RUNS"); do
    seconds="$(awk '/ real /{print $1}' "$TMP/time-$t-$run.txt")"
    peak="$(awk '/peak memory footprint/{printf "%.0f", $1 / 1e6}' "$TMP/time-$t-$run.txt")"
    cpu="$(awk '/ real /{print $3 + $5}' "$TMP/time-$t-$run.txt")"
    echo "$seconds $peak $cpu"
  done | sort -n | awk -v runs="$RUNS" '
    { time[NR] = $1; peak[NR] = $2; cpu[NR] = $3; all = all sprintf(" %.1f", $1) }
    END {
      mid = int((runs + 1) / 2)
      max = 0; for (i = 1; i <= runs; i++) if (peak[i] > max) max = peak[i]
      printf "  time    %.1f s median (runs:%s s), CPU %.1f s\n  memory  %d MB peak footprint (largest run)\n", time[mid], all, cpu[mid], max
    }'
  json="$TMP/run-$t-1.json"
  # Each group as its sorted paths relative to the photos folder, one per line, sorted: equal for equal grouping.
  jq -r --arg root "$REAL/" '.groups[] | [.photos[].path | ltrimstr($root)] | sort | join("\t")' "$json" | sort >"$TMP/found-$t.txt"
  exact="$(comm -12 "$TMP/found-$t.txt" "$TMP/photos/groups.txt" | wc -l | xargs)"
  jq -r '"  photos  \(.photos) compared, \(.analyzed) analyzed; \(.count) groups found"' "$json"
  echo "  groups  $exact of $(wc -l <"$TMP/photos/groups.txt" | xargs) generated groups found exactly, digest $(shasum "$TMP/found-$t.txt" | cut -c1-12)"
  for ((run = 2; run <= RUNS; run++)); do
    cmp -s <(jq -r '.groups[] | [.photos[].path] | sort | join("\t")' "$json" | sort) \
      <(jq -r '.groups[] | [.photos[].path] | sort | join("\t")' "$TMP/run-$t-$run.json" | sort) \
      || echo "  note    run $run grouped differently from run 1"
  done
done
