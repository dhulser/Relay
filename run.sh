#!/bin/bash
# Build, relaunch, and stream logs for Live Translator.
set -e
cd "$(dirname "$0")"

APP="build/Build/Products/Debug/LiveTranslator.app"

xcodegen generate >/dev/null
xcodebuild -project LiveTranslator.xcodeproj -scheme LiveTranslator \
  -configuration Debug -derivedDataPath build build 2>&1 \
  | grep -E "error:|warning:.*\.swift|BUILD" || true

pkill -x LiveTranslator 2>/dev/null || true
sleep 0.5
open "$APP"
echo "Launched $APP — look for '🎙 Translate' in the menu bar."
echo "Streaming logs (Ctrl-C to stop):"
exec log stream --style compact --level info \
  --predicate 'subsystem == "co.kevel.LiveTranslator"'
