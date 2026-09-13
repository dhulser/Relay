#!/bin/bash
# Build, notarize, staple, and package Live Translator for distribution.
#
# Produces dist/LiveTranslator.dmg — a signed, notarized disk image that opens
# on any Apple Silicon Mac without Gatekeeper warnings.
#
# One-time setup:
#   1. A "Developer ID Application" certificate in your keychain
#      (Xcode > Settings > Accounts > Manage Certificates > + )
#   2. A notarytool credential, using an app-specific password from
#      appleid.apple.com:
#
#      xcrun notarytool store-credentials "notary" \
#        --apple-id "you@example.com" --team-id 4PJ4624484 --password "xxxx-xxxx-xxxx-xxxx"
set -euo pipefail

PROFILE="${NOTARY_PROFILE:-notary}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$ROOT/build/Build/Products/Release/LiveTranslator.app"
DMG="$DIST/LiveTranslator.dmg"

step() { printf "\n\033[1m▸ %s\033[0m\n" "$1"; }
fail() { printf "\n\033[31m✗ %s\033[0m\n" "$1" >&2; exit 1; }

# ---------------------------------------------------------------- preflight
step "Checking prerequisites"
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || fail "No 'Developer ID Application' certificate. Add one in Xcode > Settings > Accounts > Manage Certificates."
echo "  ✓ Developer ID certificate"

xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || fail "No notarytool credential named '$PROFILE'. See the setup notes at the top of this script."
echo "  ✓ notarytool credential '$PROFILE'"

# ---------------------------------------------------------------- build
step "Building Release"
cd "$ROOT"
xcodegen generate >/dev/null
xcodebuild -project LiveTranslator.xcodeproj -scheme LiveTranslator \
  -configuration Release -derivedDataPath build build 2>&1 | grep -E "error:|BUILD" || true
[ -d "$APP" ] || fail "Build produced no app bundle."

step "Verifying signature"
codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | tail -1
codesign -dv --verbose=2 "$APP" 2>&1 | grep -q "flags=0x10000(runtime)" \
  || fail "Hardened runtime is not enabled — notarization will reject this."
echo "  ✓ hardened runtime"

# ---------------------------------------------------------------- notarize app
# The app is notarized and stapled *before* going into the disk image, so it
# validates offline even after someone drags it out of the DMG.
step "Notarizing the app"
mkdir -p "$DIST"
ZIP="$DIST/LiveTranslator.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"

# ---------------------------------------------------------------- package
step "Building the disk image"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # drag-to-install target

rm -f "$DMG"
hdiutil create -volname "Live Translator" -srcfolder "$STAGE" \
  -ov -format UDZO "$DMG" >/dev/null

# The image is notarized too, so the download itself is trusted, not just the
# app inside it.
step "Notarizing the disk image"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

# ---------------------------------------------------------------- verify
step "Verifying as Gatekeeper will see it"
spctl -a -vvv -t install "$DMG" 2>&1 | sed 's/^/  /'
spctl -a -vvv "$APP" 2>&1 | sed 's/^/  /'

printf "\n\033[32m✓ %s (%s)\033[0m\n" "$DMG" "$(du -h "$DMG" | cut -f1)"
