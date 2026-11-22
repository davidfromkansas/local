#!/usr/bin/env bash
# Builds a signed, notarized Taki for Mac .dmg plus a Sparkle appcast, and uploads both to a draft
# GitHub Release (tag mac-v<version>). Usage:
#   scripts/release-mac.sh [version]          # signed + notarized + draft release (default version: TAKI_MAC_VERSION)
#   scripts/release-mac.sh --adhoc [version]  # local test: ad-hoc signature, no notarization, no upload
#   scripts/release-mac.sh --no-upload [...]  # everything except the GitHub upload
# Signed builds need (see docs/MAC.md › Releasing):
#   - a "Developer ID Application" certificate in the keychain, or DEVELOPER_ID_P12 (path to .p12)
#     + DEVELOPER_ID_P12_PASSWORD, imported into a temporary keychain for this run
#   - ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8 (App Store Connect API key, path or contents) for notarytool
#   - the Sparkle private key: SPARKLE_KEY_FILE (default ~/.config/taki/sparkle_private_key), or the
#     login keychain (generate_keys --account taki)
#   - gh logged in (or GH_TOKEN) with write access to the repo
set -euo pipefail
cd "$(dirname "$0")/.."

ADHOC=0 UPLOAD=1 VERSION=""
for arg in "$@"; do
  case "$arg" in
    --adhoc) ADHOC=1 UPLOAD=0 ;;
    --no-upload) UPLOAD=0 ;;
    -h|--help) sed -n 2,14p "$0"; exit 0 ;;
    *) VERSION="$arg" ;;
  esac
done
setting() { awk -F' = ' -v k="$1" '$1 == k {print $2}' Config/Base.xcconfig; }
VERSION="${VERSION:-$(setting TAKI_MAC_VERSION)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
TEAM_ID="${TEAM_ID:-$(setting DEVELOPMENT_TEAM)}"
PUBLIC_KEY="$(setting TAKI_SPARKLE_PUBLIC_KEY)"
REPO="${REPO:-davidfromkansas/local}"
TAG="mac-v$VERSION"
OUT="build/mac-release"
DMG="$OUT/Taki-$VERSION.dmg"
APP="$OUT/Taki.app"
DERIVED="build/MacRelease"
SPARKLE_BIN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"
step() { printf '\n==> %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

# --- Credentials -------------------------------------------------------------------------------
CLEANUP=()
trap 'for c in "${CLEANUP[@]:-}"; do eval "$c"; done' EXIT
if [ "$ADHOC" = 1 ]; then
  IDENTITY="-"
else
  if [ -n "${DEVELOPER_ID_P12:-}" ]; then
    KC="$PWD/build/release-signing.keychain-db" KC_PASS="$(uuidgen)"
    mkdir -p build && rm -f "$KC"
    security create-keychain -p "$KC_PASS" "$KC"
    CLEANUP+=("security delete-keychain '$KC' 2>/dev/null")
    security set-keychain-settings -lut 3600 "$KC"
    security unlock-keychain -p "$KC_PASS" "$KC"
    security import "$DEVELOPER_ID_P12" -k "$KC" -P "${DEVELOPER_ID_P12_PASSWORD:-}" -T /usr/bin/codesign
    security set-key-partition-list -S apple-tool:,apple: -s -k "$KC_PASS" "$KC" >/dev/null
    security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
  fi
  IDENTITY="${DEVELOPER_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
  [ -n "$IDENTITY" ] || die "no 'Developer ID Application' certificate found (see docs/MAC.md › Releasing)"
  : "${ASC_KEY_ID:?set ASC_KEY_ID}" "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}" "${ASC_KEY_P8:?set ASC_KEY_P8}"
  KEY_DIR="$HOME/.appstoreconnect/private_keys" KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
  mkdir -p "$KEY_DIR" && chmod 700 "$KEY_DIR"
  if [ -f "$ASC_KEY_P8" ]; then [ "$ASC_KEY_P8" -ef "$KEY_PATH" ] || cp "$ASC_KEY_P8" "$KEY_PATH"; else printf '%s\n' "$ASC_KEY_P8" > "$KEY_PATH"; fi
  chmod 600 "$KEY_PATH"
  NOTARY=(--key "$KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
  [ "$UPLOAD" = 0 ] || gh auth status >/dev/null 2>&1 || [ -n "${GH_TOKEN:-}" ] || die "log in with 'gh auth login' first"
fi
echo "Taki for Mac $VERSION ($BUILD_NUMBER), signing as: $IDENTITY"

# --- Build ------------------------------------------------------------------------------------
step "Building (Release, Apple silicon; a cold build takes 20+ minutes)"
command -v xcodegen >/dev/null && xcodegen generate --quiet
rm -rf "$OUT" && mkdir -p "$OUT"
# Built with an ad-hoc signature; the real signature is applied below, inside-out.
xcodebuild -project Taki.xcodeproj -scheme TakiMac -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" -archivePath "$OUT/Taki.xcarchive" -skipPackagePluginValidation -skipMacroValidation \
  ARCHS=arm64 MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO archive \
  | { command -v xcbeautify >/dev/null && xcbeautify --quiet || grep -E "error:|ARCHIVE" || true; }
[ "${PIPESTATUS[0]}" = 0 ] || die "build failed"
ditto "$OUT/Taki.xcarchive/Products/Applications/Taki.app" "$APP"
[ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")" = "$PUBLIC_KEY" ] || die "SUPublicEDKey missing from Info.plist"

# --- Sign -------------------------------------------------------------------------------------
step "Signing"
sign() {
  local flags=(--force --sign "$IDENTITY")
  # Hardened runtime rejects ad-hoc-signed frameworks (no Team ID), so local test builds go without it.
  [ "$IDENTITY" = "-" ] || flags+=(--options runtime --timestamp)
  codesign "${flags[@]}" "$@"
}
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
# Sparkle's helpers first (https://sparkle-project.org/documentation/sandboxing/#code-signing).
for item in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
  [ -e "$SPARKLE/Versions/B/$item" ] || continue
  if [ "$item" = XPCServices/Downloader.xpc ]; then
    sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/$item"
  else
    sign "$SPARKLE/Versions/B/$item"
  fi
done
# Then every other framework, dylib and nested executable, deepest first, then the app itself.
find "$APP/Contents" -depth \( -name '*.framework' -o -name '*.dylib' -o -name '*.xpc' -o -name '*.bundle' -o -name '*.app' \) -print0 \
  | while IFS= read -r -d '' item; do
      case "$item" in "$SPARKLE"/*) continue ;; esac
      if [ -d "$item" ] && [ -z "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$item/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$item/Resources/Info.plist" 2>/dev/null)" ]; then
        continue # resource-only bundle: sealed by the app's signature
      fi
      sign "$item"
    done
sign --entitlements Config/TakiMac.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q audio-input || die "microphone entitlement missing"

notarize() {
  [ "$IDENTITY" = "-" ] && return 0
  step "Notarizing $(basename "$1") (usually 2-10 minutes)"
  local submit="$1"
  if [ -d "$1" ]; then submit="$OUT/notarize.zip"; ditto -c -k --keepParent "$1" "$submit"; fi
  xcrun notarytool submit "$submit" "${NOTARY[@]}" --wait --timeout 1h --output-format json > "$OUT/notary.json" || true
  local id status
  id=$(plutil -extract id raw "$OUT/notary.json" 2>/dev/null || true)
  status=$(plutil -extract status raw "$OUT/notary.json" 2>/dev/null || true)
  if [ "$status" != "Accepted" ]; then
    cat "$OUT/notary.json" >&2
    [ -n "$id" ] && xcrun notarytool log "$id" "${NOTARY[@]}" >&2
    die "notarization failed"
  fi
  xcrun stapler staple "$1"
  rm -f "$OUT/notarize.zip"
}
notarize "$APP"

# --- Disk image -------------------------------------------------------------------------------
step "Making $DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Taki.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Taki" -srcfolder "$STAGE" -fs APFS -format ULFO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
if [ "$IDENTITY" != "-" ]; then
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
  notarize "$DMG"
  step "Checking Gatekeeper"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
  spctl --assess --type execute --verbose=2 "$APP"
fi

# --- Sparkle appcast --------------------------------------------------------------------------
step "Writing appcast.xml"
SIGN_ARGS=(--account taki)
SPARKLE_KEY_FILE="${SPARKLE_KEY_FILE:-$HOME/.config/taki/sparkle_private_key}"
if [ -f "$SPARKLE_KEY_FILE" ]; then
  SIGN_ARGS=(--ed-key-file "$SPARKLE_KEY_FILE")
  # The private key file holds the 32-byte Ed25519 seed; derive its public key to compare.
  derived=$( { printf '302e020100300506032b657004220420' | xxd -r -p; base64 -d < "$SPARKLE_KEY_FILE"; } \
    | openssl pkey -inform DER -pubout -outform DER | tail -c 32 | base64)
else
  derived=$("$SPARKLE_BIN/generate_keys" --account taki -p 2>/dev/null || true)
fi
if [ "$derived" != "$PUBLIC_KEY" ]; then
  [ "$ADHOC" = 1 ] || die "the Sparkle private key doesn't match TAKI_SPARKLE_PUBLIC_KEY; updates would be rejected"
  echo "No matching Sparkle key here; appcast not signed (fine for --adhoc)."
  ENCLOSURE_SIG="length=\"$(stat -f%z "$DMG")\""
else
  ENCLOSURE_SIG=$("$SPARKLE_BIN/sign_update" "${SIGN_ARGS[@]}" "$DMG")
fi
MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Taki for Mac</title>
    <item>
      <title>Taki $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <link>https://github.com/$REPO/releases/tag/$TAG</link>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/$(basename "$DMG")" type="application/octet-stream" $ENCLOSURE_SIG />
    </item>
  </channel>
</rss>
XML
xmllint --noout "$OUT/appcast.xml"

# --- Upload -----------------------------------------------------------------------------------
if [ "$UPLOAD" = 1 ]; then
  step "Uploading to a draft GitHub Release ($TAG)"
  NOTES="Taki for Mac $VERSION. Apple silicon Macs with macOS $MIN_OS or later. Open the .dmg and drag Taki to Applications."
  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release upload "$TAG" "$DMG" "$OUT/appcast.xml" --repo "$REPO" --clobber
  else
    gh release create "$TAG" "$DMG" "$OUT/appcast.xml" --repo "$REPO" --draft \
      --title "Taki for Mac $VERSION" --notes "$NOTES" --target "$(git rev-parse HEAD)"
  fi
  echo "Draft release: https://github.com/$REPO/releases (click Publish to ship it; installed copies update from it)"
fi
step "Done: $DMG"
