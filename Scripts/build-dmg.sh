#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-0.1.0}"
BUILD_NUMBER="${2:-1}"
APP_NAME="MenubarBadges"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DMG_NAME="$APP_NAME-$VERSION.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
STAGING_DIR="$DIST_DIR/dmg-staging"

"$ROOT_DIR/Scripts/build-app.sh" "$VERSION" "$BUILD_NUMBER"

echo "==> Packaging $DMG_NAME..."
rm -rf "$STAGING_DIR" "$DMG_PATH"
mkdir -p "$STAGING_DIR"

cp -R "$APP_BUNDLE" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
    -volname "Menubar Badges $VERSION" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

rm -rf "$STAGING_DIR"

echo "==> DMG ready at: $DMG_PATH"
ls -lh "$DMG_PATH"
