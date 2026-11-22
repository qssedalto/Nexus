#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Requires the user's real Apple Developer provisioning profile and an
# App ID authorized for com.qssedalto.nexus.cloudkit.dev. Never use a
# guessed CloudKit identifier or overwrite an installed Nexus app.
APP_NAME="Nexus CloudKit" \
APP_ICON_NAME="AppIcon" \
BUNDLE_ID="com.qssedalto.nexus.cloudkit.dev" \
NEXUS_REQUIRE_CLOUDKIT=1 \
"$ROOT/Scripts/build_and_run.sh" --dev "$@"
