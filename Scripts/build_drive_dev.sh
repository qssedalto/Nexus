#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Separate bundle ID and app name: this build never replaces Nexus.app or
# a separately provisioned CloudKit test application.
APP_NAME="Nexus Drive" \
APP_ICON_NAME="AppIcon" \
BUNDLE_ID="com.qssedalto.nexus.drive.dev" \
NEXUS_REQUIRE_FOLDER_ONLY=1 \
"$ROOT/Scripts/build_and_run.sh" --dev "$@"
