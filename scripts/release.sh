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

# notarytool exits 0 even when the verdict is Invalid, so read the status and,
# on rejection, print the reasons rather than leaving the caller to go digging.
notarize() {
  local artifact="$1" output id
  output="$(xcrun notarytool submit "$artifact" --keychain-profile "$PROFILE" --wait 2>&1)"
  printf '%s\n' "$output"

  case "$output" in
    *"status: Accepted"*) return 0 ;;
  esac

  id="$(printf '%s\n' "$output" | awk '/  id: /{print $2; exit}')"
  if [ -n "$id" ]; then
    printf "\n\033[31mNotarization rejected. Reasons:\033[0m\n"
    xcrun notarytool log "$id" --keychain-profile "$PROFILE" 2>&1 \
      | grep -E '"(message|path)"' || true
  fi
  fail "Notarization rejected for $(basename "$artifact")."
}

# ---------------------------------------------------------------- preflight
step "Checking prerequisites"
# Capture then test, rather than piping into `grep -q`: under `pipefail` the
# early exit of `grep -q` closes the pipe, the writer dies of SIGPIPE, and the
# pipeline reports failure *because* the pattern matched.
IDENTITIES="$(security find-identity -v -p codesigning 2>&1 || true)"
case "$IDENTITIES" in
  *"Developer ID Application"*) echo "  ✓ Developer ID certificate" ;;
  *) fail "No 'Developer ID Application' certificate. Add one in Xcode > Settings > Accounts > Manage Certificates." ;;
esac

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
SIGNATURE="$(codesign -dv --verbose=2 "$APP" 2>&1 || true)"
case "$SIGNATURE" in
  *"flags=0x10000(runtime)"*) echo "  ✓ hardened runtime" ;;
  *) fail "Hardened runtime is not enabled — notarization will reject this." ;;
esac
case "$SIGNATURE" in
  *"Developer ID Application"*) echo "  ✓ signed with Developer ID" ;;
  *) fail "Release is not signed with Developer ID — notarization will reject this." ;;
esac

# "Signed Time" is a local clock reading; notarization wants "Timestamp", which
# only comes from Apple's timestamp server.
case "$SIGNATURE" in
  *"Timestamp="*) echo "  ✓ secure timestamp" ;;
  *) fail "No secure timestamp. Release needs OTHER_CODE_SIGN_FLAGS = --timestamp." ;;
esac

ENTITLEMENTS="$(codesign -d --entitlements - "$APP" 2>/dev/null | tr -d '\0' || true)"
case "$ENTITLEMENTS" in
  *get-task-allow*) fail "The build carries com.apple.security.get-task-allow, which notarization rejects. Set CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO for Release." ;;
  *) echo "  ✓ no debug entitlements" ;;
esac

# ---------------------------------------------------------------- notarize app
# The app is notarized and stapled *before* going into the disk image, so it
# validates offline even after someone drags it out of the DMG.
step "Notarizing the app"
mkdir -p "$DIST"
ZIP="$DIST/LiveTranslator.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
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

# The image needs its own signature, not just a notarization ticket —
# Gatekeeper checks the disk image as a code object when it is opened.
#
# macOS may show a keychain prompt here the first time, since this uses the
# signing key directly rather than through Xcode. Choose "Always Allow" and it
# will not ask again. Run this script from a Terminal you can see, not from an
# automated session, or the prompt has nowhere to appear and signing fails with
# errSecInternalComponent.
if ! codesign --sign "Developer ID Application" --timestamp "$DMG" 2>&1; then
  fail "Could not sign the disk image.

  If that reported 'errSecInternalComponent', macOS could not ask permission to
  use your signing key. Run this script directly in Terminal and choose
  'Always Allow' at the keychain prompt."
fi

# The image is notarized too, so the download itself is trusted, not just the
# app inside it.
step "Notarizing the disk image"
notarize "$DMG"
xcrun stapler staple "$DMG"

# ---------------------------------------------------------------- verify
step "Verifying as Gatekeeper will see it"

# A disk image is assessed with the "open" policy. The "install" policy is for
# installer packages and always reports "no usable signature" for a DMG, which
# looks alarming and means nothing.
DMG_CHECK="$(spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 || true)"
printf '%s\n' "$DMG_CHECK" | sed 's/^/  /'
case "$DMG_CHECK" in
  *accepted*) ;;
  *) fail "Gatekeeper would reject the disk image." ;;
esac

APP_CHECK="$(spctl -a -vv "$APP" 2>&1 || true)"
printf '%s\n' "$APP_CHECK" | sed 's/^/  /'
case "$APP_CHECK" in
  *"Notarized Developer ID"*) ;;
  *) fail "Gatekeeper would reject the app." ;;
esac

printf "\n\033[32m✓ %s (%s)\033[0m\n" "$DMG" "$(du -h "$DMG" | cut -f1)"
printf "  Signed, notarized, and stapled. Opens on any Apple Silicon Mac.\n"
