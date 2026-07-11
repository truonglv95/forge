#!/usr/bin/env bash
set -e

echo "Building Forge IDE for ReleaseFast..."
zig build -Doptimize=ReleaseFast

APP_DIR="zig-out/bin/Forge.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "Creating App Bundle structure at $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

echo "Copying executable..."
cp zig-out/bin/forge-ide "$MACOS_DIR/Forge"

echo "Creating Info.plist..."
cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Forge</string>
    <key>CFBundleIdentifier</key>
    <string>com.forge.ide</string>
    <key>CFBundleName</key>
    <string>Forge</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>10.15</string>
</dict>
</plist>
EOF

echo "Building DMG..."
rm -f Forge.dmg
hdiutil create -volname "Forge" -srcfolder "$APP_DIR" -ov -format UDZO Forge.dmg

echo "Done! Forge.dmg is ready."
