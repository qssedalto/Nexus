#!/usr/bin/env bash
set -euo pipefail

# This script ONLY builds a service prototype in an isolated derived-data
# directory. It never installs an app, registers a service, alters Finder
# preferences, or touches the existing signed Nexus.app.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/version.env"

if [[ "${NEXUS_PROTOTYPE_DERIVED_DATA:-}" != "" ]]; then
  OUT="$NEXUS_PROTOTYPE_DERIVED_DATA"
else
  OUT="$ROOT/.build/services-prototype-derived"
fi

plutil -lint "Config/Nexus-ServicesPrototype-Info.plist"
"$ROOT/Scripts/generate_project.sh"

# Ensure the extension is compiled with the suppression of its own Finder
# contextual menu: NSServices must be the sole path-copy entry in this build.
BUILD_SETTINGS="$(xcodebuild -project "$ROOT/Nexus.xcodeproj" \
  -target NexusFinderSync -configuration ServicesPrototype -showBuildSettings)"
if ! grep -E 'SWIFT_ACTIVE_COMPILATION_CONDITIONS.*NEXUS_SERVICE_PROTOTYPE' <<< "$BUILD_SETTINGS" >/dev/null; then
  echo "ERROR: Finder Sync menu suppression compile flag missing" >&2
  exit 1
fi

xcodebuild -project "$ROOT/Nexus.xcodeproj" -scheme Nexus \
  -configuration ServicesPrototype -derivedDataPath "$OUT" \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  ENABLE_DEBUG_DYLIB=NO MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build -quiet

INFO="$OUT/Build/Products/ServicesPrototype/Nexus Services Prototype.app/Contents/Info.plist"
if [[ ! -f "$INFO" ]]; then
  echo "ERROR: Service-only app was not produced: $INFO" >&2
  exit 1
fi

expected='copySelectedPaths'
actual="$(/usr/libexec/PlistBuddy -c 'Print :NSServices:0:NSMessage' "$INFO")"
if [[ "$actual" != "$expected" ]]; then
  echo "ERROR: Missing or incorrect NSMessage: $actual" >&2
  exit 1
fi

file_type="$(/usr/libexec/PlistBuddy -c 'Print :NSServices:0:NSSendFileTypes:0' "$INFO")"
if [[ "$file_type" != "public.item" ]]; then
  echo "ERROR: Prototype lacks universal file item UTI: $file_type" >&2
  exit 1
fi

if /usr/libexec/PlistBuddy -c 'Print :NSServices:1' "$INFO" >/dev/null 2>&1; then
  echo "ERROR: More than one overlapping Services entry" >&2
  exit 1
fi

echo "PASS: Isolated NSServices-only prototype, one service, Finder menu suppressed."
echo "Build output: $OUT/Build/Products/ServicesPrototype/Nexus Services Prototype.app"
echo "NOTE: Registration and actual Finder/iCloud menu behavior require manual test on macOS."
