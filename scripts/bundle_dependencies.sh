#!/bin/bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/dist/PhoneBridge.app"
CONTENTS_DIR="$APP_DIR/Contents"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
PLUGINS_DIR="$RESOURCES_DIR/gstreamer-1.0/plugins"
SCANNER_DIR="$RESOURCES_DIR/gstreamer-1.0"
LICENSES_DIR="$RESOURCES_DIR/Licenses"
SOURCES_DIR="$RESOURCES_DIR/ThirdPartySources"
UXPLAY_SOURCE_DIR="${UXPLAY_SOURCE_DIR:-$PROJECT_DIR/../../work/UxPlay}"
SCRCPY_RELEASE_DIR="${SCRCPY_RELEASE_DIR:-$PROJECT_DIR/../../work/scrcpy-official/scrcpy-macos-aarch64-v4.1}"
SIGN_IDENTITY="${PHONEBRIDGE_SIGN_IDENTITY:--}"

UXPLAY_BIN="/opt/homebrew/bin/uxplay"
GSTREAMER_ROOT="/opt/homebrew/opt/gstreamer"
GSTREAMER_PLUGIN_DIR="$GSTREAMER_ROOT/lib/gstreamer-1.0"
GSTREAMER_SCANNER="$GSTREAMER_ROOT/libexec/gstreamer-1.0/gst-plugin-scanner"
FFMPEG_ROOT="/opt/homebrew/opt/ffmpeg"

if [[ ! -d "$APP_DIR" ]]; then
    echo "请先运行 scripts/build_app.sh。" >&2
    exit 1
fi

for required in "$UXPLAY_BIN" "$GSTREAMER_SCANNER" "$SCRCPY_RELEASE_DIR/scrcpy" "$SCRCPY_RELEASE_DIR/adb" "$SCRCPY_RELEASE_DIR/scrcpy-server"; do
    if [[ ! -f "$required" ]]; then
        echo "缺少打包依赖：$required" >&2
        exit 1
    fi
done

rm -rf "$FRAMEWORKS_DIR" "$CONTENTS_DIR/PlugIns" "$SCANNER_DIR" "$LICENSES_DIR" "$SOURCES_DIR"
mkdir -p "$FRAMEWORKS_DIR" "$PLUGINS_DIR" "$SCANNER_DIR" "$LICENSES_DIR" "$SOURCES_DIR"

cp -L "$UXPLAY_BIN" "$RESOURCES_DIR/uxplay"
cp -L "$SCRCPY_RELEASE_DIR/scrcpy" "$RESOURCES_DIR/scrcpy"
cp -L "$SCRCPY_RELEASE_DIR/adb" "$RESOURCES_DIR/adb"
cp -L "$SCRCPY_RELEASE_DIR/scrcpy-server" "$RESOURCES_DIR/scrcpy-server"
cp -L "$GSTREAMER_SCANNER" "$SCANNER_DIR/gst-plugin-scanner"
chmod 755 "$RESOURCES_DIR/uxplay" "$RESOURCES_DIR/scrcpy" "$RESOURCES_DIR/adb" "$SCANNER_DIR/gst-plugin-scanner"

GSTREAMER_PLUGINS=(
    libgstcoreelements.dylib
    libgstapp.dylib
    libgsttypefindfunctions.dylib
    libgstplayback.dylib
    libgstautodetect.dylib
    libgstlibav.dylib
    libgstvideoconvertscale.dylib
    libgstvideofilter.dylib
    libgstvideoparsersbad.dylib
    libgstapplemedia.dylib
    libgstjpeg.dylib
    libgsttcp.dylib
)

for plugin in "${GSTREAMER_PLUGINS[@]}"; do
    if [[ ! -f "$GSTREAMER_PLUGIN_DIR/$plugin" ]]; then
        echo "缺少 GStreamer 插件：$plugin" >&2
        exit 1
    fi
    cp -L "$GSTREAMER_PLUGIN_DIR/$plugin" "$PLUGINS_DIR/$plugin"
done

QUEUE_FILE="$(mktemp -t phonebridge-dependencies.XXXXXX)"
trap 'rm -f "$QUEUE_FILE"' EXIT
printf '%s\n' \
    "$RESOURCES_DIR/uxplay" \
    "$RESOURCES_DIR/scrcpy" \
    "$RESOURCES_DIR/adb" \
    "$SCANNER_DIR/gst-plugin-scanner" > "$QUEUE_FILE"
find "$PLUGINS_DIR" -type f -name '*.dylib' -print >> "$QUEUE_FILE"

resolve_homebrew_dependency() {
    local dependency="$1"
    local basename_value
    basename_value="$(basename "$dependency")"

    if [[ "$dependency" == /opt/homebrew/* && -e "$dependency" ]]; then
        printf '%s\n' "$dependency"
        return 0
    fi

    find -L /opt/homebrew/Cellar -type f -name "$basename_value" -print 2>/dev/null \
        | sort -V \
        | head -n 1
}

while IFS= read -r current_file; do
    if ! file "$current_file" | grep -q 'Mach-O'; then
        continue
    fi

    while IFS= read -r dependency; do
        case "$dependency" in
            /opt/homebrew/*.dylib|@rpath/*.dylib)
                dependency_basename="$(basename "$dependency")"
                if [[ "$current_file" == *.dylib && "$dependency_basename" == "$(basename "$current_file")" ]]; then
                    continue
                fi
                target="$FRAMEWORKS_DIR/$dependency_basename"
                if [[ ! -f "$target" ]]; then
                    source_path="$(resolve_homebrew_dependency "$dependency")"
                    if [[ -z "$source_path" || ! -e "$source_path" ]]; then
                        echo "无法解析动态库：$dependency（来自 $current_file）" >&2
                        exit 1
                    fi
                    cp -L "$source_path" "$target"
                    chmod u+w "$target"
                    printf '%s\n' "$target" >> "$QUEUE_FILE"
                fi
                ;;
        esac
    done < <(otool -L "$current_file" | tail -n +2 | awk '{print $1}')
done < "$QUEUE_FILE"

loader_reference() {
    local file_path="$1"
    local library_name="$2"
    case "$file_path" in
        "$FRAMEWORKS_DIR"/*)
            printf '@loader_path/%s\n' "$library_name"
            ;;
        "$PLUGINS_DIR"/*)
            printf '@loader_path/../../../Frameworks/%s\n' "$library_name"
            ;;
        "$SCANNER_DIR"/*)
            printf '@loader_path/../../Frameworks/%s\n' "$library_name"
            ;;
        "$RESOURCES_DIR"/*)
            printf '@loader_path/../Frameworks/%s\n' "$library_name"
            ;;
        "$CONTENTS_DIR/MacOS"/*)
            printf '@loader_path/../Frameworks/%s\n' "$library_name"
            ;;
        *)
            echo "无法确定动态库相对路径：$file_path" >&2
            exit 1
            ;;
    esac
}

run_install_name_tool() {
    local error_file
    error_file="$(mktemp -t phonebridge-install-name.XXXXXX)"
    if ! install_name_tool "$@" 2>"$error_file"; then
        cat "$error_file" >&2
        rm -f "$error_file"
        return 1
    fi
    rm -f "$error_file"
}

run_codesign() {
    local error_file
    error_file="$(mktemp -t phonebridge-codesign.XXXXXX)"
    if ! codesign "$@" 2>"$error_file"; then
        cat "$error_file" >&2
        rm -f "$error_file"
        return 1
    fi
    rm -f "$error_file"
}

while IFS= read -r -d '' macho_file; do
    if ! file "$macho_file" | grep -q 'Mach-O'; then
        continue
    fi
    chmod u+w "$macho_file"

    while IFS= read -r dependency; do
        dependency_basename="$(basename "$dependency")"
        if [[ "$macho_file" == *.dylib && "$dependency_basename" == "$(basename "$macho_file")" ]]; then
            continue
        fi
        if [[ -f "$FRAMEWORKS_DIR/$dependency_basename" ]]; then
            replacement="$(loader_reference "$macho_file" "$dependency_basename")"
            run_install_name_tool -change "$dependency" "$replacement" "$macho_file"
        fi
    done < <(otool -L "$macho_file" | tail -n +2 | awk '{print $1}')

    if [[ "$macho_file" == *.dylib ]]; then
        run_install_name_tool -id "@rpath/$(basename "$macho_file")" "$macho_file"
    fi
done < <(find "$CONTENTS_DIR" -type f -print0)

cp "$UXPLAY_SOURCE_DIR/LICENSE" "$LICENSES_DIR/UxPlay-GPL-3.0.txt"
cp "$SCRCPY_RELEASE_DIR/LICENSE" "$LICENSES_DIR/scrcpy-Apache-2.0.txt"
cp "/opt/homebrew/Cellar/gstreamer/1.28.6_1/LICENSE" "$LICENSES_DIR/GStreamer-LGPL-2.1.txt"
cp "/opt/homebrew/Cellar/gettext/1.0/COPYING" "$LICENSES_DIR/gettext-GPL.txt"
cp "/opt/homebrew/Cellar/pcre2/10.47_1/COPYING" "$LICENSES_DIR/PCRE2.txt"
cp "/opt/homebrew/Cellar/orc/0.4.42/COPYING" "$LICENSES_DIR/ORC.txt"
cp "/opt/homebrew/Cellar/jpeg-turbo/3.2.0/LICENSE.md" "$LICENSES_DIR/libjpeg-turbo.txt"
cp "$FFMPEG_ROOT/LICENSE.md" "$LICENSES_DIR/FFmpeg-LICENSE.md"
cp "$FFMPEG_ROOT/COPYING.GPLv3" "$LICENSES_DIR/FFmpeg-GPL-3.0.txt"
cp "$PROJECT_DIR/Resources/THIRD_PARTY_NOTICES.txt" "$LICENSES_DIR/THIRD_PARTY_NOTICES.txt"

tar \
    --exclude='.git' \
    --exclude='build' \
    --exclude='CMakeFiles' \
    -czf "$SOURCES_DIR/UxPlay-source.tar.gz" \
    -C "$(dirname "$UXPLAY_SOURCE_DIR")" \
    "$(basename "$UXPLAY_SOURCE_DIR")"

while IFS= read -r -d '' signable_file; do
    if [[ "$signable_file" == "$CONTENTS_DIR/MacOS/"* ]]; then
        continue
    fi
    if file "$signable_file" | grep -q 'Mach-O'; then
        run_codesign --force --sign "$SIGN_IDENTITY" "$signable_file"
    fi
done < <(find "$CONTENTS_DIR" -type f -print0)

run_codesign \
    --force \
    --sign "$SIGN_IDENTITY" \
    --requirements '=designated => identifier "com.personal.phonebridge"' \
    "$APP_DIR"

unexpected_links=0
while IFS= read -r -d '' verified_file; do
    if ! file "$verified_file" | grep -q 'Mach-O'; then
        continue
    fi
    if otool -L "$verified_file" | tail -n +2 | awk '{print $1}' | grep -E '^(/opt/homebrew|/usr/local)' >/dev/null; then
        echo "仍包含外部依赖：$verified_file" >&2
        otool -L "$verified_file" >&2
        unexpected_links=1
    fi
done < <(find "$CONTENTS_DIR" -type f -print0)

if [[ "$unexpected_links" -ne 0 ]]; then
    exit 1
fi

codesign --verify --deep --strict "$APP_DIR"
echo "依赖已封装：$APP_DIR"
