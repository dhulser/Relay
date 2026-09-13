#!/bin/bash
# Writes the Homebrew cask for a built disk image to dist/relay.rb.
#
# The cask lives in the tap repository dhulser/homebrew-relay at Casks/relay.rb;
# copy the generated file there and push after each release.
#
#   brew install --cask dhulser/relay/relay
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DMG="${1:-$ROOT/dist/Relay.dmg}"
APP="$ROOT/build/Build/Products/Release/Relay.app"

[ -f "$DMG" ] || { echo "No disk image at $DMG — run scripts/release.sh first." >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")"
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"

cat > "$ROOT/dist/relay.rb" <<CASK
cask "relay" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/dhulser/Relay/releases/download/v#{version}/Relay.dmg"
  name "Relay: Live Translator"
  desc "Live translated subtitles for calls and anything else playing on your Mac"
  homepage "https://github.com/dhulser/Relay"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: ">= :sequoia"

  app "Relay.app"

  zap trash: [
    "~/Library/Application Support/co.kevel.Relay",
    "~/Library/Preferences/co.kevel.Relay.plist",
  ]
end
CASK

echo "dist/relay.rb — Relay $VERSION, sha256 $SHA"
