#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-0.1.0}"
BUILD_NUMBER="${2:-1}"
APP_NAME="MenubarBadges"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

echo "==> Building $APP_NAME v$VERSION (build $BUILD_NUMBER)..."

cd "$ROOT_DIR"

# Build universal binary if both architectures succeed; otherwise build host arch.
if swift build -c release --arch arm64 --arch x86_64 2>/dev/null; then
    BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$APP_NAME"
    echo "==> Built universal (arm64 + x86_64) binary: $BIN_PATH"
else
    swift build -c release
    BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"
    echo "==> Built native binary: $BIN_PATH"
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Generate AppIcon.icns
ICONSET_DIR="$DIST_DIR/AppIcon.iconset"
rm -rf "$ICONSET_DIR"
swift "$ROOT_DIR/Scripts/generate-icon.swift" "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET_DIR"

# Populate Info.plist
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD_NUMBER/g" \
    "$ROOT_DIR/Resources/Info.plist.template" > "$APP_BUNDLE/Contents/Info.plist"

# Ad-hoc sign the bundle so macOS Accessibility permissions track cleanly
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> App bundle created at: $APP_BUNDLE"
file "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
