#!/bin/bash
# Refreshes the vendored sherpa-onnx xcframework used for speaker embeddings.
#
# The result is checked in (~26 MB) so a normal clone builds without network
# access. Run this only to change the pinned version.
set -euo pipefail

SHERPA_VERSION="v1.13.8"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor/sherpa"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

NAME="sherpa-onnx-${SHERPA_VERSION}-macos-shared-onnxruntime-static.xcframework.zip"
URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/${NAME}"

echo "Downloading sherpa-onnx ${SHERPA_VERSION}…"
curl -fsSL -o "$WORK/sherpa.zip" "$URL"
unzip -q "$WORK/sherpa.zip" -d "$WORK"

rm -rf "$VENDOR"
mkdir -p "$VENDOR"
cp -R "$WORK/sherpa-onnx.xcframework" "$VENDOR/"

# The published binary is universal; we ship Apple Silicon only, and halving it
# keeps the checked-in size reasonable.
DYLIB="$VENDOR/sherpa-onnx.xcframework/macos-arm64_x86_64/libsherpa-onnx-c-api.dylib"
lipo -thin arm64 "$DYLIB" -output "$DYLIB.arm64"
mv "$DYLIB.arm64" "$DYLIB"
plutil -replace AvailableLibraries.0.SupportedArchitectures -json '["arm64"]' \
  "$VENDOR/sherpa-onnx.xcframework/Info.plist"

echo "Vendored sherpa-onnx ${SHERPA_VERSION} ($(du -h "$DYLIB" | cut -f1), arm64)."
