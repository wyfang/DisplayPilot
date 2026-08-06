#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
OUTPUT="${DISPLAYPILOT_OUTPUT_DIR:-$ROOT/dist}"
APP="$OUTPUT/Display Pilot.app"

mkdir -p "$APP/Contents/MacOS"
mkdir -p "$ROOT/.module-cache"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
xcrun swiftc \
  -O \
  -module-cache-path "$ROOT/.module-cache" \
  -framework AppKit \
  -framework CoreGraphics \
  "$ROOT/DisplayPilot.swift" \
  -o "$APP/Contents/MacOS/DisplayPilot"
codesign --force --sign - "$APP"

echo "$APP"
