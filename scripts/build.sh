#!/bin/bash
set -euo pipefail

# Optional target arch (e.g. `bash build.sh x86_64`); empty = native build.
ARCH="${1:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESOURCES_DIR="$SCRIPT_DIR/Resources"
BUILD_DIR="$SCRIPT_DIR/.build"
APP_BUNDLE="$BUILD_DIR/Glow.app"

echo "==> Building Glow (SwiftPM)..."

cd "$SCRIPT_DIR"

# Compile via SwiftPM (release).
BIN_PATH="$(swift build -c release ${ARCH:+--arch "$ARCH"} --show-bin-path)"
swift build -c release ${ARCH:+--arch "$ARCH"}

# Assemble .app bundle (SwiftPM also uses .build/, so only touch the bundle).
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH/Glow" "$APP_BUNDLE/Contents/MacOS/Glow"

# Copy Info.plist
cp "$RESOURCES_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
# Copy omp/pi hook template
cp "$RESOURCES_DIR/glow-hook-template.ts" "$APP_BUNDLE/Contents/Resources/"
# App icon
cp "$RESOURCES_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"

echo "==> Built: $APP_BUNDLE"
echo "==> Run:   open $APP_BUNDLE"
