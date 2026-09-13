#!/bin/bash
# Packages an app into a drag-to-install disk image with a designed Finder
# window: Retina background, arrow to Applications, icons placed, and the
# app's icon on the mounted volume.
#
#   scripts/make-dmg.sh <path/to/Relay.app> <path/to/output.dmg>
#
# Finder itself lays out the window (it is the only thing that can write the
# .DS_Store it later reads), so this drives it with AppleScript. The first run
# asks to allow Terminal to control Finder; say yes once.
set -euo pipefail

APP="${1:?usage: make-dmg.sh <app> <dmg>}"
DMG="${2:?usage: make-dmg.sh <app> <dmg>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VOLNAME="Relay"
APPNAME="$(basename "$APP")"

# Must match the layout in make-dmg-background.swift.
WIN_W=660; WIN_H=400
APP_X=165; APP_Y=185
FOLDER_X=495; FOLDER_Y=185
ICON_SIZE=128

[ -d "$APP" ] || { echo "No app at $APP" >&2; exit 1; }

STAGE="$(mktemp -d)"
RW="$(mktemp -d)/rw.dmg"
cleanup() {
  if [ -n "${MOUNT:-}" ] && [ -d "$MOUNT" ]; then hdiutil detach "$MOUNT" -quiet -force || true; fi
  rm -rf "$STAGE" "$(dirname "$RW")"
}
trap cleanup EXIT

# ---------------------------------------------------------------- contents
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$STAGE/.background"
swift "$ROOT/scripts/make-dmg-background.swift" "$STAGE/.background" >/dev/null
# One TIFF holding both scales is how Finder picks the sharp one on Retina.
tiffutil -cathidpicheck "$STAGE/.background/background.png" "$STAGE/.background/background@2x.png" \
  -out "$STAGE/.background/background.tiff" 2>/dev/null
rm -f "$STAGE/.background/background.png" "$STAGE/.background/background@2x.png"

# The volume shows the app's own icon on the desktop and in the sidebar.
cp "$APP/Contents/Resources/Relay.icns" "$STAGE/.VolumeIcon.icns"

# ---------------------------------------------------------------- writable image
SIZE_KB=$(( $(du -sk "$STAGE" | cut -f1) + 20000 ))
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ \
  -format UDRW -size "${SIZE_KB}k" -ov "$RW" >/dev/null

MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk -F'\t' '/Volumes/{print $NF; exit}')"
[ -d "$MOUNT" ] || { echo "Could not mount the working image" >&2; exit 1; }

# Flag the volume as having a custom icon (the 'C' Finder attribute).
[ -f "$MOUNT/.VolumeIcon.icns" ] || { echo "Volume icon missing after create; contents:" >&2; ls -la "$MOUNT" >&2; exit 1; }
SetFile -a C "$MOUNT"

# ---------------------------------------------------------------- layout
osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set pathbar visible of container window to false
    set bounds of container window to {400, 160, $((400 + WIN_W)), $((160 + WIN_H))}
    set viewOptions to icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to $ICON_SIZE
    set text size of viewOptions to 13
    set label position of viewOptions to bottom
    set shows item info of viewOptions to false
    set shows icon preview of viewOptions to true
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "$APPNAME" of container window to {$APP_X, $APP_Y}
    set position of item "Applications" of container window to {$FOLDER_X, $FOLDER_Y}
    close
    open
    delay 1
    close
  end tell
end tell
APPLESCRIPT
# No "update" here on purpose: Finder's update rewrites the volume's icon
# record and deletes .VolumeIcon.icns along with the custom-icon flag.

# Belt and braces: make sure the icon and its flag survived the Finder pass.
[ -f "$MOUNT/.VolumeIcon.icns" ] || cp "$APP/Contents/Resources/Relay.icns" "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT"

# Give Finder a moment to write .DS_Store, then let go of the volume.
sync
sleep 2
hdiutil detach "$MOUNT" -quiet
MOUNT=""

# ---------------------------------------------------------------- compress
rm -f "$DMG"
mkdir -p "$(dirname "$DMG")"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
echo "$DMG ($(du -h "$DMG" | cut -f1))"
