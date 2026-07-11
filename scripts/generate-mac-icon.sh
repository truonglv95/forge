#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_ICNS="${1:-$ROOT/zig-out/ForgeIcon.icns}"
WORK_DIR="${2:-$ROOT/zig-out/icon-build}"
BASE_PNG="$WORK_DIR/ForgeIcon-1024.png"
ICONSET="$WORK_DIR/ForgeIcon.iconset"

mkdir -p "$WORK_DIR"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

swift "$ROOT/scripts/generate-mac-icon.swift" "$BASE_PNG" >/dev/null

make_icon() {
    local px="$1"
    local name="$2"
    sips -s format png -z "$px" "$px" "$BASE_PNG" --out "$ICONSET/$name" >/dev/null
}

make_icon 16   icon_16x16.png
make_icon 32   icon_16x16@2x.png
make_icon 32   icon_32x32.png
make_icon 64   icon_32x32@2x.png
make_icon 128  icon_128x128.png
make_icon 256  icon_128x128@2x.png
make_icon 256  icon_256x256.png
make_icon 512  icon_256x256@2x.png
make_icon 512  icon_512x512.png
make_icon 1024 icon_512x512@2x.png

mkdir -p "$(dirname "$OUT_ICNS")"
iconutil -c icns "$ICONSET" -o "$OUT_ICNS"
echo "$OUT_ICNS"
