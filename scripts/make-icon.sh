#!/bin/bash
# Regenerates Relay.icns from scripts/make-icon.swift.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

swift "$ROOT/scripts/make-icon.swift" "$WORK" >/dev/null
SET="$WORK/Relay.iconset"; mkdir -p "$SET"

# macOS wants each size at 1x and 2x.
for size in 16 32 128 256 512; do
  sips -z $size $size        "$WORK/icon-1024.png" --out "$SET/icon_${size}x${size}.png"      >/dev/null
  sips -z $((size*2)) $((size*2)) "$WORK/icon-1024.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done

mkdir -p "$ROOT/Relay/Resources"
iconutil -c icns "$SET" -o "$ROOT/Relay/Resources/Relay.icns"
echo "Relay/Resources/Relay.icns ($(du -h "$ROOT/Relay/Resources/Relay.icns" | cut -f1))"
