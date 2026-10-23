#!/usr/bin/env bash
# Build a signed, notarized CleanMate .dmg for GitHub Releases, and its Sparkle update feed.
# Steps: release notes from CHANGELOG.md -> archive -> check the EdDSA key -> export (Developer ID) -> notarize app
# -> staple -> dmg -> notarize dmg -> staple -> sha256 -> EdDSA signature -> appcast.xml.
# No secrets here: notarytool and Sparkle's sign_update read their keys from the login keychain (see --help).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/CleanMate/CleanMate.xcodeproj"
SCHEME="CleanMate"
APP_NAME="CleanMate"
OUT="$ROOT/build/release"
PROFILE="${NOTARY_PROFILE:-cleanmate-notary}"
SKIP_NOTARIZE=0
DERIVED="$ROOT/build/DerivedData"
# Sparkle's command line tools come with its Swift package, resolved into DERIVED by the archive step.
SPARKLE_BIN="${SPARKLE_BIN:-$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin}"
REPO_URL="https://github.com/homielab/cleanmate"

usage() {
  cat <<EOF
Usage: scripts/release.sh [--skip-notarize] [--profile NAME] [--help]

Builds build/release/CleanMate-<version>.dmg (+ .sha256) from the current checkout,
build/release/CleanMate-<version>-notes.md with the "## [<version>]" section of CHANGELOG.md, and
build/release/appcast.xml: the Sparkle update feed with one item for this version, its download
signed with the EdDSA key, and the same release notes.
The version is MARKETING_VERSION in the Xcode project. Before running: bump it, rename
"## [Unreleased]" in CHANGELOG.md to "## [<version>] - YYYY-MM-DD", and commit. Without that
section the script stops before building anything.

  --skip-notarize  Local dry run: archive, export with Developer ID, make the dmg,
                   but do not contact Apple (the dmg will not pass Gatekeeper on other Macs).
                   Without the EdDSA key, appcast.xml is written unsigned: never publish it.
  --profile NAME   notarytool keychain profile (default: \$NOTARY_PROFILE or cleanmate-notary).
  --help           Show this help.

One-time setup:
  - "Developer ID Application" certificate for team 79LQ4MHVMG in the login keychain.
  - xcrun notarytool store-credentials cleanmate-notary \\
        --apple-id <apple id> --team-id 79LQ4MHVMG --password <app-specific password>
  - Sparkle's EdDSA private key in the login keychain, matching SUPublicEDKey in CleanMate/Info.plist.
    Check: build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -p
    On another Mac, import a backup with generate_keys -f <file>. SPARKLE_BIN overrides the tools folder.

This script does not tag, push or upload. Publish afterwards, e.g.:
  git tag v<version> && git push origin main v<version>
  gh release create v<version> build/release/CleanMate-<version>.dmg build/release/CleanMate-<version>.dmg.sha256 \\
      build/release/appcast.xml --title "CleanMate <version>" --notes-file build/release/CleanMate-<version>-notes.md
The app reads its feed from $REPO_URL/releases/latest/download/appcast.xml,
so the new release must be the latest one (gh's default) and carry appcast.xml.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    --profile) PROFILE="${2:?--profile needs a name}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

SETTINGS="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null)"
setting() { awk -F' = ' -v key=" $1 = " 'index($0, key) { print $2; exit }' <<<"$SETTINGS"; }
VERSION="$(setting MARKETING_VERSION)"
BUILD="$(setting CURRENT_PROJECT_VERSION)"
MIN_SYSTEM="$(setting MACOSX_DEPLOYMENT_TARGET)"
[[ -n "$VERSION" && -n "$BUILD" && -n "$MIN_SYSTEM" ]] || {
  echo "Cannot read MARKETING_VERSION, CURRENT_PROJECT_VERSION or MACOSX_DEPLOYMENT_TARGET" >&2; exit 1
}
echo "==> CleanMate $VERSION (build $BUILD)"

# Body of the "## [<version>]" section of CHANGELOG.md (heading, link definitions and
# surrounding blank lines dropped), up to the next "## " heading.
release_notes() { # $1 = version, $2 = changelog
  awk -v heading="## [$1]" '
    index($0, heading) == 1 { found = 1; next }
    found && /^## / { exit }
    found && !/^\[[^]]+\]: / { lines[++n] = $0 }
    END {
      first = 1; while (first <= n && lines[first] ~ /^[[:space:]]*$/) first++
      last = n; while (last >= first && lines[last] ~ /^[[:space:]]*$/) last--
      for (i = first; i <= last; i++) print lines[i]
    }' "$2"
}
NOTES="$(release_notes "$VERSION" "$ROOT/CHANGELOG.md")"
[[ -n "$NOTES" ]] || {
  echo "CHANGELOG.md has no \"## [$VERSION]\" section (or it is empty)." >&2
  echo "Rename \"## [Unreleased]\" to \"## [$VERSION] - $(date +%Y-%m-%d)\" and commit, then run again." >&2
  exit 1
}

ARCHIVE="$OUT/$APP_NAME.xcarchive"
EXPORT="$OUT/export"
APP="$EXPORT/$APP_NAME.app"
DMG="$OUT/$APP_NAME-$VERSION.dmg"
rm -rf "$OUT"
mkdir -p "$OUT"
NOTES_FILE="$OUT/$APP_NAME-$VERSION-notes.md"
printf '%s\n' "$NOTES" > "$NOTES_FILE"
echo "==> Release notes: $NOTES_FILE"

notarize() { # $1 = file to submit (zip or dmg)
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait
}

echo "==> Archive"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" -archivePath "$ARCHIVE" archive -quiet

# Before notarizing: Sparkle refuses an update signed with another key than the installed app's SUPublicEDKey.
echo "==> Sparkle key"
[[ -x "$SPARKLE_BIN/sign_update" && -x "$SPARKLE_BIN/generate_keys" ]] || { echo "Sparkle tools not found in $SPARKLE_BIN" >&2; exit 1; }
APP_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$ARCHIVE/Products/Applications/$APP_NAME.app/Contents/Info.plist")"
SIGN_KEY="$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null || true)"
if [[ "$SIGN_KEY" != "$APP_KEY" ]]; then
  if [[ -z "$SIGN_KEY" ]]; then echo "No Sparkle EdDSA key in the login keychain." >&2
  else echo "The keychain's Sparkle key ($SIGN_KEY) is not the app's SUPublicEDKey ($APP_KEY)." >&2; fi
  [[ $SKIP_NOTARIZE -eq 1 ]] || exit 1
  echo "warning: --skip-notarize: appcast.xml gets no EdDSA signature." >&2
  SIGN_KEY=""
fi

echo "==> Export (Developer ID)"
# Manual style: non-sandboxed app with no capabilities needs no provisioning profile, so no Apple account is needed here.
cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>teamID</key><string>79LQ4MHVMG</string>
</dict></plist>
EOF
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -quiet

echo "==> Verify signature"
codesign --verify --deep --strict "$APP"
# Capture first: `cmd | grep -q` can SIGPIPE cmd, which pipefail turns into a failure.
SIGN_INFO="$(codesign -dv --verbose=2 "$APP" 2>&1)"
[[ "$SIGN_INFO" == *"flags="*"runtime"* ]] || { echo "Hardened runtime missing" >&2; exit 1; }
[[ "$SIGN_INFO" == *"Authority=Developer ID Application"* ]] || { echo "Not signed with Developer ID" >&2; exit 1; }
if [[ "$(codesign -d --entitlements - "$APP" 2>/dev/null)" == *get-task-allow* ]]; then
  echo "get-task-allow present: notarization would reject this build" >&2; exit 1
fi

if [[ $SKIP_NOTARIZE -eq 0 ]]; then
  echo "==> Notarize app"
  ditto -c -k --keepParent "$APP" "$OUT/$APP_NAME.zip"
  notarize "$OUT/$APP_NAME.zip"
  xcrun stapler staple "$APP"
  rm "$OUT/$APP_NAME.zip"
fi

echo "==> DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" -quiet
rm -rf "$STAGE"
codesign --sign "Developer ID Application" --timestamp "$DMG"

if [[ $SKIP_NOTARIZE -eq 0 ]]; then
  echo "==> Notarize dmg"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  spctl -a -t open --context context:primary-signature -v "$DMG"
fi

(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

echo "==> Appcast"
# Signed last: stapling changes the dmg. sign_update prints: sparkle:edSignature="..." length="..."
if [[ -n "$SIGN_KEY" ]]; then
  ENCLOSURE_ATTRS="$("$SPARKLE_BIN/sign_update" "$DMG")"
  [[ "$ENCLOSURE_ATTRS" == *'sparkle:edSignature="'* ]] || { echo "sign_update failed: $ENCLOSURE_ATTRS" >&2; exit 1; }
else
  ENCLOSURE_ATTRS="length=\"$(stat -f %z "$DMG")\""
fi
APPCAST="$OUT/appcast.xml"
CDATA_NOTES="${NOTES//]]>/]]]]><![CDATA[>}"  # "]]>" would end the CDATA section
cat > "$APPCAST" <<APPCAST_XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$APP_NAME</title>
    <link>$REPO_URL</link>
    <language>en</language>
    <item>
      <title>$APP_NAME $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_SYSTEM</sparkle:minimumSystemVersion>
      <description sparkle:format="markdown"><![CDATA[
$CDATA_NOTES
]]></description>
      <enclosure url="$REPO_URL/releases/download/v$VERSION/$(basename "$DMG")" type="application/octet-stream" $ENCLOSURE_ATTRS/>
    </item>
  </channel>
</rss>
APPCAST_XML
xmllint --noout "$APPCAST"

echo "==> Done: $DMG"
cat "$DMG.sha256"
echo "Release notes: $NOTES_FILE"
echo "Appcast: $APPCAST"
[[ -n "$SIGN_KEY" ]] || echo "(appcast.xml has no EdDSA signature: do not publish it)"
[[ $SKIP_NOTARIZE -eq 1 ]] && echo "(not notarized: --skip-notarize)"
exit 0
