#!/bin/bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_ICON="$PROJECT_DIR/Resources/AppIcon-1024.png"
ICONSET_DIR="$PROJECT_DIR/.build-icon/PhoneBridge.iconset"
OUTPUT_ICON="$PROJECT_DIR/Resources/PhoneBridge.icns"

if [[ ! -f "$SOURCE_ICON" ]]; then
    echo "缺少图标源文件：$SOURCE_ICON" >&2
    exit 1
fi

rm -rf "$PROJECT_DIR/.build-icon"
mkdir -p "$ICONSET_DIR"

sips -z 16 16 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
cp "$SOURCE_ICON" "$ICONSET_DIR/icon_512x512@2x.png"

/usr/bin/python3 "$PROJECT_DIR/scripts/build_icns.py" "$ICONSET_DIR" "$OUTPUT_ICON"
echo "$OUTPUT_ICON"
