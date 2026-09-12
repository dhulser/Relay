#!/bin/bash
# Rebuilds the vendored whisper.cpp static libraries in Vendor/whisper.
#
# The build output is checked in (it is only ~4 MB) so a normal clone can build
# the app without cmake. Run this only to change the pinned version or the
# build flags.
#
# Requires: cmake (brew install cmake)
set -euo pipefail

WHISPER_VERSION="v1.9.2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor/whisper"
WORK="$ROOT/.build/whisper.cpp"

command -v cmake >/dev/null || { echo "cmake not found — brew install cmake"; exit 1; }

if [ ! -d "$WORK" ]; then
  echo "Cloning whisper.cpp $WHISPER_VERSION…"
  mkdir -p "$(dirname "$WORK")"
  git clone --depth 1 --branch "$WHISPER_VERSION" https://github.com/ggml-org/whisper.cpp "$WORK"
fi

echo "Configuring (Metal + Accelerate, static)…"
cmake -S "$WORK" -B "$WORK/build-macos" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_EXAMPLES=OFF \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_SERVER=OFF \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_ACCELERATE=ON \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0

echo "Building…"
cmake --build "$WORK/build-macos" --config Release -j"$(sysctl -n hw.ncpu)"

echo "Vendoring into $VENDOR…"
mkdir -p "$VENDOR/lib" "$VENDOR/include"
cp "$WORK/build-macos/src/libwhisper.a" "$VENDOR/lib/"
cp "$WORK/build-macos/ggml/src/"libggml*.a "$VENDOR/lib/"
cp "$WORK/build-macos/ggml/src/ggml-metal/libggml-metal.a" "$VENDOR/lib/"
cp "$WORK/build-macos/ggml/src/ggml-blas/libggml-blas.a" "$VENDOR/lib/"
cp "$WORK/include/whisper.h" "$VENDOR/include/"
cp "$WORK/ggml/include/"*.h "$VENDOR/include/"

# GGML_METAL_EMBED_LIBRARY compiles the Metal shaders into the binary, so no
# default.metallib has to ship alongside the app.
echo "Done. Vendored $(ls "$VENDOR/lib" | wc -l | tr -d ' ') libraries from whisper.cpp $WHISPER_VERSION."
