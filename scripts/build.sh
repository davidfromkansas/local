#!/usr/bin/env bash
# One-command simulator build. Usage: scripts/build.sh [build|test]
#   DESTINATION="platform=iOS Simulator,name=..." (default: first available iPhone 17 Pro)
#   TEST_RUNNER_TAKI_ASR_TESTS=1 scripts/build.sh test   # also run the ASR accuracy test (downloads ~1 GB once)
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "XcodeGen missing: brew install xcodegen"; exit 1; }
xcodegen generate --quiet
ACTION="${1:-build}"
SIM_ID=$(xcrun simctl list devices available | awk -F'[()]' '/iPhone 17 Pro \(/ {print $2; exit}')
DEST="${DESTINATION:-platform=iOS Simulator,id=${SIM_ID}}"
xcodebuild \
  -project Taki.xcodeproj -scheme Taki -configuration Debug \
  -destination "$DEST" -derivedDataPath build/DerivedData \
  -skipPackagePluginValidation -skipMacroValidation \
  "$ACTION" | { command -v xcbeautify >/dev/null && xcbeautify || cat; }
