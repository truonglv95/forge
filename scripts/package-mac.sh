#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "Building Forge IDE (ReleaseFast)..."
zig build -Doptimize=ReleaseFast

APP_NAME="Forge IDE"
BIN="$ROOT/zig-out/bin/forge-ide"
STAGE="$ROOT/zig-out/stage/Forge IDE.app"
CONTENTS="$STAGE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

rm -rf "$STAGE"
mkdir -p "$MACOS" "$RESOURCES"

cp "$BIN" "$MACOS/forge-ide"
chmod +x "$MACOS/forge-ide"

cat > "$CONTENTS/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>forge-ide</string>
  <key>CFBundleIdentifier</key>
  <string>dev.forge.ide</string>
  <key>CFBundleName</key>
  <string>Forge IDE</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0-alpha</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

echo "Staged app bundle at:"
echo "  $STAGE"
echo
echo "Run with:"
echo "  open \"$STAGE\""
echo
echo "Note: signing/notarization are not performed by this script."
