#!/usr/bin/env bash
# Archive, sign, and upload Taki to TestFlight with an App Store Connect API key.
# Required env:
#   ASC_KEY_ID      App Store Connect API key ID (Team key, App Manager role or higher)
#   ASC_ISSUER_ID   Issuer ID (App Store Connect › Users and Access › Integrations)
#   ASC_KEY_P8      path to AuthKey_XXXX.p8, or the key contents themselves
# Optional env:
#   TEAM_ID         Apple Developer Team ID (default: DEVELOPMENT_TEAM in Config/Base.xcconfig)
#   BUILD_NUMBER    CFBundleVersion (default: timestamp)
# The App Store Connect app record for the bundle ID must exist first.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${ASC_KEY_ID:?set ASC_KEY_ID}" "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}" "${ASC_KEY_P8:?set ASC_KEY_P8}"
TEAM_ID="${TEAM_ID:-$(awk -F' = ' '/^DEVELOPMENT_TEAM/ {print $2}' Config/Base.xcconfig)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"

KEY_DIR="$HOME/.appstoreconnect/private_keys"
KEY_PATH="$KEY_DIR/AuthKey_${ASC_KEY_ID}.p8"
mkdir -p "$KEY_DIR" && chmod 700 "$KEY_DIR"
if [ -f "$ASC_KEY_P8" ]; then
  [ "$ASC_KEY_P8" -ef "$KEY_PATH" ] || cp "$ASC_KEY_P8" "$KEY_PATH"
else
  printf '%s\n' "$ASC_KEY_P8" > "$KEY_PATH"
fi
chmod 600 "$KEY_PATH"

AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath "$KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID")

command -v xcodegen >/dev/null && xcodegen generate --quiet
mkdir -p build
rm -rf build/Taki.xcarchive build/export

xcodebuild -project Taki.xcodeproj -scheme Taki -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/Taki.xcarchive \
  -skipPackagePluginValidation -skipMacroValidation \
  DEVELOPMENT_TEAM="$TEAM_ID" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  "${AUTH[@]}" archive

cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

# destination=upload sends the build straight to App Store Connect.
xcodebuild -exportArchive -archivePath build/Taki.xcarchive \
  -exportOptionsPlist build/ExportOptions.plist -exportPath build/export "${AUTH[@]}"

echo "Uploaded build $BUILD_NUMBER. It appears in TestFlight after Apple finishes processing (~5–15 min)."
