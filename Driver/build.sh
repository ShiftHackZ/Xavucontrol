#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
DRIVER_BUNDLE="$BUILD_DIR/XavucontrolVirtualCable.driver"
CONTENTS_DIR="$DRIVER_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

rm -rf "$DRIVER_BUNDLE"
mkdir -p "$MACOS_DIR"
cp "$SCRIPT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"

clang++ \
  -std=c++20 \
  -Wall \
  -Wextra \
  -fvisibility=hidden \
  -bundle \
  -framework CoreAudio \
  -framework CoreFoundation \
  "$SCRIPT_DIR/XavucontrolVirtualCable.cpp" \
  -o "$MACOS_DIR/XavucontrolVirtualCable"

echo "$DRIVER_BUNDLE"
