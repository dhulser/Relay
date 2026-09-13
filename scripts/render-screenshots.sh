#!/bin/bash
# Regenerates site/assets/*.png from the real SwiftUI views.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MARKER="$ROOT/Tests/.render-screenshots"

touch "$MARKER"
trap 'rm -f "$MARKER"' EXIT

xcodebuild test -project "$ROOT/Relay.xcodeproj" -scheme Relay \
  -configuration Debug -derivedDataPath "$ROOT/build" \
  -only-testing:RelayTests/ScreenshotRenderer 2>&1 \
  | grep -E "error:|ScreenshotRenderer.*(passed|failed)|TEST" || true

ls -lh "$ROOT/site/assets"
