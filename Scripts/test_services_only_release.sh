#!/usr/bin/env bash
set -euo pipefail
# Build only. NEVER register a service, install an app, or overwrite a working
# signed release in the user's Applications directory.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/version.env"
OUT="${NEXUS_SERVICES_ONLY_DERIVED_DATA:-$ROOT/.build/services-only-derived}"
"$ROOT/Scripts/generate_project.sh"

EXT_SETTINGS="$(xcodebuild -project Slashgrab.xcodeproj -target SlashgrabFinderSync -configuration ServicesOnly -showBuildSettings)"
if ! grep -E 'SWIFT_ACTIVE_COMPILATION_CONDITIONS.*NEXUS_SERVICE_PROTOTYPE' <<<"$EXT_SETTINGS" >/dev/null; then
  echo 'ERROR: the ServicesOnly Finder extension would duplicate the native path-copy command' >&2
  exit 1
fi
xcodebuild -project Slashgrab.xcodeproj -scheme Slashgrab -configuration ServicesOnly \
  -derivedDataPath "$OUT" -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO \
  MARKETING_VERSION="$MARKETING_VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  build -quiet

INFO="$OUT/Build/Products/ServicesOnly/Nexus.app/Contents/Info.plist"
test -f "$INFO"
function plist_read() { /usr/libexec/PlistBuddy -c "Print :$1" "$INFO"; }
test "$(plist_read CFBundleIdentifier)" = 'com.prof18.slashgrab'
test "$(plist_read SlashgrabAppGroupIdentifier)" = '$(DEVELOPMENT_TEAM).com.prof18.slashgrab.shared'
test "$(plist_read NSServices:0:NSMessage)" = 'copySelectedPaths'
test "$(plist_read NSServices:0:NSSendFileTypes:0)" = 'public.item'
if plist_read NSServices:1 >/dev/null 2>&1; then
  echo "ERROR: multiple native copy-path registrations" >&2
  exit 1
fi
echo 'PASS: ServicesOnly has original production identity and exactly one native copy-path action.'
echo 'NOTE: This is a build-only candidate; verify Finder/iCloud before any deployment.'
