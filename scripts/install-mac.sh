#!/usr/bin/env bash
# Builds the Taki Mac app and installs it in /Applications. Usage: scripts/install-mac.sh
# Needs Xcode 26 (open it once and sign in with your Apple ID under Settings › Accounts).
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodebuild >/dev/null || { echo "Install Xcode from the App Store first."; exit 1; }
if ! command -v xcodegen >/dev/null; then
  command -v brew >/dev/null || { echo "Install Homebrew (https://brew.sh), then run this again."; exit 1; }
  brew install xcodegen
fi
xcodegen generate --quiet

build() {
  xcodebuild -project Taki.xcodeproj -scheme TakiMac -configuration Release -destination 'platform=macOS' \
    -derivedDataPath build/MacRelease -skipPackagePluginValidation -skipMacroValidation "$@" build \
    | { command -v xcbeautify >/dev/null && xcbeautify --quiet || grep -E "error:|BUILD" || true; }
  return "${PIPESTATUS[0]}"
}

echo "Building Taki for Mac (the first build takes a few minutes)…"
# Signed with your Apple ID's team so macOS remembers the Microphone/Accessibility permissions
# across updates. Falls back to a local-only signature if Xcode isn't signed in.
if ! build -allowProvisioningUpdates; then
  echo "Signing with your team failed; building with a local signature instead."
  build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
fi

APP=build/MacRelease/Build/Products/Release/Taki.app
osascript -e 'quit app "Taki"' 2>/dev/null || true
sleep 1
rm -rf /Applications/Taki.app
cp -R "$APP" /Applications/
echo "Installed /Applications/Taki.app — opening it."
open /Applications/Taki.app
