#!/bin/bash
set -euo pipefail

# ── Paths ──────────────────────────────────────────────────────────────────
# Optional target arch (`bash package.sh x86_64`); default arm64 keeps the
# historical Glow.pkg output name that the pre-push nightly hook uploads.
ARCH="${1:-arm64}"
case "$ARCH" in
    arm64)    PKG_FINAL_NAME="Glow.pkg" ;;
    x86_64)   PKG_FINAL_NAME="Glow-x86_64.pkg" ;;
    *) echo "unsupported arch: $ARCH (arm64 | x86_64)" >&2; exit 2 ;;
esac
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESOURCES_DIR="$SCRIPT_DIR/Resources"
# Single source of truth for the version: Resources/Info.plist.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$RESOURCES_DIR/Info.plist")"
BUILD_DIR="$SCRIPT_DIR/.build"
APP_BUNDLE="$BUILD_DIR/Glow.app"
PKG_ROOT="$BUILD_DIR/pkg-root"
PKG_COMPONENT="$BUILD_DIR/Glow-component.pkg"
PKG_FINAL="$BUILD_DIR/$PKG_FINAL_NAME"

echo "==> Step 1: Building app ($ARCH)..."
# Native default (arm64) builds without an arch flag.
if [ "$ARCH" = "x86_64" ]; then
    bash "$SCRIPT_DIR/scripts/build.sh" x86_64
else
    bash "$SCRIPT_DIR/scripts/build.sh"
fi

echo ""
echo "==> Step 2: Preparing package root..."
rm -rf "$PKG_ROOT"
mkdir -p "$PKG_ROOT/Applications"
cp -R "$APP_BUNDLE" "$PKG_ROOT/Applications/"

echo ""
echo "==> Step 3: Building component package..."
pkgbuild \
    --root "$PKG_ROOT" \
    --identifier "com.qqlzfmn.Glow" \
    --version "$VERSION" \
    --install-location "/" \
    "$PKG_COMPONENT"

echo ""
echo "==> Step 4: Building product archive..."
cat > "$BUILD_DIR/distribution.xml" << EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Glow</title>
    <options customize="never" require-scripts="false" hostArchitectures="$ARCH"/>
    <domains enable_localSystem="true"/>
    <choices-outline>
        <line choice="default"/>
    </choices-outline>
    <choice id="default">
        <pkg-ref id="com.qqlzfmn.Glow"/>
    </choice>
    <pkg-ref id="com.qqlzfmn.Glow"
             version="$VERSION">Glow-component.pkg</pkg-ref>
</installer-gui-script>
EOF

productbuild \
    --distribution "$BUILD_DIR/distribution.xml" \
    --package-path "$BUILD_DIR" \
    "$PKG_FINAL"

# Clean up intermediate files
rm -rf "$PKG_ROOT"
rm -f "$PKG_COMPONENT"
rm -f "$BUILD_DIR/distribution.xml"

echo ""
echo "==> Done!"
echo "    Package: $PKG_FINAL"
echo "    Size:    $(du -h "$PKG_FINAL" | cut -f1)"
