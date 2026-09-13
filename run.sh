#!/bin/bash
# Build, relaunch, and stream logs for Relay.
set -e
cd "$(dirname "$0")"

APP="build/Build/Products/Debug/Relay.app"

xcodegen generate >/dev/null
xcodebuild -project Relay.xcodeproj -scheme Relay \
  -configuration Debug -derivedDataPath build build 2>&1 \
  | grep -E "error:|warning:.*\.swift|BUILD" || true

pkill -x Relay 2>/dev/null || true
sleep 0.5
open "$APP"
echo "Launched $APP — look for '🎙 Translate' in the menu bar."
echo "Streaming logs (Ctrl-C to stop):"
exec log stream --style compact --level info \
  --predicate 'subsystem == "co.kevel.Relay"'
