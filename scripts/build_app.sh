#!/bin/bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/dist/PhoneBridge.app"
BIN_DIR="$APP_DIR/Contents/MacOS"
RESOURCE_DIR="$APP_DIR/Contents/Resources"
LOCAL_BUILD_DIR="$PROJECT_DIR/.build-local"
LOCAL_CACHE_DIR="$PROJECT_DIR/.swiftpm-cache"
SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"

cd "$PROJECT_DIR"

"$PROJECT_DIR/scripts/generate_icon.sh"

if [[ -d "/Applications/Xcode.app" ]]; then
  CLANG_MODULE_CACHE_PATH="$LOCAL_BUILD_DIR/clang-cache" \
  SWIFTPM_MODULECACHE_OVERRIDE="$LOCAL_BUILD_DIR/swift-cache" \
  swift build \
    --disable-sandbox \
    --scratch-path "$LOCAL_BUILD_DIR" \
    --cache-path "$LOCAL_CACHE_DIR" \
    -c release
elif [[ -d "$SDK_PATH" ]]; then
  CLANG_MODULE_CACHE_PATH="$LOCAL_BUILD_DIR/clang-cache" \
  SWIFTPM_MODULECACHE_OVERRIDE="$LOCAL_BUILD_DIR/swift-cache" \
  swift build \
    --disable-sandbox \
    --sdk "$SDK_PATH" \
    --scratch-path "$LOCAL_BUILD_DIR" \
    --cache-path "$LOCAL_CACHE_DIR" \
    -c release
else
  echo "需要安装完整 Xcode，或安装包含 macOS 15.4 SDK 的 Command Line Tools。" >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$BIN_DIR" "$RESOURCE_DIR"

if [[ -f "$LOCAL_BUILD_DIR/arm64-apple-macosx/release/PhoneBridge" ]]; then
  cp "$LOCAL_BUILD_DIR/arm64-apple-macosx/release/PhoneBridge" "$BIN_DIR/PhoneBridge"
else
  cp ".build/release/PhoneBridge" "$BIN_DIR/PhoneBridge"
fi
cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "Resources/PhoneBridge.icns" "$RESOURCE_DIR/PhoneBridge.icns"

codesign \
  --force \
  --deep \
  --sign - \
  --requirements '=designated => identifier "com.personal.phonebridge"' \
  "$APP_DIR"

echo "$APP_DIR"
