#!/bin/bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/dist/PhoneBridge.app"
STAGING_DIR="$PROJECT_DIR/dist/dmg-root"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist")"
DMG_PATH="$PROJECT_DIR/dist/PhoneBridge-$VERSION-AppleSilicon.dmg"

"$PROJECT_DIR/scripts/build_app.sh"
"$PROJECT_DIR/scripts/bundle_dependencies.sh"

rm -rf "$STAGING_DIR" "$DMG_PATH"
mkdir -p "$STAGING_DIR"
/usr/bin/ditto "$APP_DIR" "$STAGING_DIR/PhoneBridge.app"
ln -s /Applications "$STAGING_DIR/Applications"
cp "$PROJECT_DIR/Resources/DMG_README.txt" "$STAGING_DIR/安装说明.txt"

hdiutil create \
    -volname "PhoneBridge $VERSION" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

hdiutil verify "$DMG_PATH"
shasum -a 256 "$DMG_PATH"
echo "$DMG_PATH"
