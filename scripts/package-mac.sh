#!/usr/bin/env bash
# scripts/package-mac.sh — Build, bundle, and package Forge IDE for macOS.
#
# Usage:
#   ./scripts/package-mac.sh [--sign "Developer ID Application: ..."] [--dmg] [--version x.y.z]
#
# Without --sign the script produces an unsigned .app bundle suitable for
# local testing. With --sign it code-signs the bundle and (if xcrun notarytool
# credentials are available) notarizes and staples.
#
# Environment variables:
#   FORGE_SIGN_IDENTITY  — codesign identity (overrides --sign flag)
#   FORGE_NOTARIZE_PROFILE — notarytool credential profile (keychain item)
#   FORGE_VERSION        — version string (overrides --version flag)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ---------------------------------------------------------------------------
# Parse args
SIGN_IDENTITY="${FORGE_SIGN_IDENTITY:-}"
NOTARIZE_PROFILE="${FORGE_NOTARIZE_PROFILE:-}"
CREATE_DMG=false
VERSION="${FORGE_VERSION:-0.1.0-alpha}"
ARCH="$(uname -m)"   # arm64 | x86_64

for arg in "$@"; do
    case "$arg" in
        --sign=*)   SIGN_IDENTITY="${arg#--sign=}" ;;
        --sign)     shift; SIGN_IDENTITY="${1:-}" ;;
        --dmg)      CREATE_DMG=true ;;
        --version=*) VERSION="${arg#--version=}" ;;
        --version)  shift; VERSION="${1:-}" ;;
    esac
done

# ---------------------------------------------------------------------------
# Paths
BIN_DIR="$ROOT/zig-out/bin"
STAGE_DIR="$ROOT/zig-out/stage"
APP_NAME="Forge IDE"
APP_BUNDLE="$STAGE_DIR/${APP_NAME}.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
DMG_NAME="Forge-${VERSION}-${ARCH}.dmg"
DMG_PATH="$ROOT/zig-out/${DMG_NAME}"

# ---------------------------------------------------------------------------
echo "==> Building Forge IDE (ReleaseFast)..."
zig build -Doptimize=ReleaseFast 2>&1

# ---------------------------------------------------------------------------
echo "==> Staging .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_DIR/forge-ide" "$MACOS_DIR/forge-ide"
chmod +x "$MACOS_DIR/forge-ide"

# Copy forge CLI tool into the bundle (optional but useful)
if [ -f "$BIN_DIR/forge" ]; then
    cp "$BIN_DIR/forge" "$MACOS_DIR/forge"
    chmod +x "$MACOS_DIR/forge"
fi

# ---------------------------------------------------------------------------
# Info.plist
cat > "$CONTENTS/Info.plist" <<PLIST
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
  <key>CFBundleDisplayName</key>
  <string>Forge IDE</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>$(date +%Y%m%d%H%M%S)</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>SUFeedURL</key>
  <string>https://forge.dev/releases/appcast.xml</string>
  <key>SUPublicEDKey</key>
  <string>placeholder_ed_key</string>
</dict>
</plist>
PLIST

# ---------------------------------------------------------------------------
# Code signing
if [ -n "$SIGN_IDENTITY" ]; then
    echo "==> Signing with identity: $SIGN_IDENTITY"
    # Sign the binary first, then the bundle.
    codesign --force --options runtime --sign "$SIGN_IDENTITY" \
        --entitlements "$ROOT/scripts/forge-ide.entitlements" 2>/dev/null || \
    codesign --force --options runtime --sign "$SIGN_IDENTITY" \
        "$MACOS_DIR/forge-ide"
    if [ -f "$MACOS_DIR/forge" ]; then
        codesign --force --options runtime --sign "$SIGN_IDENTITY" "$MACOS_DIR/forge"
    fi
    codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
    echo "    => Signed OK"
    codesign --verify --deep --strict --verbose=1 "$APP_BUNDLE"
else
    echo "    [skip] No signing identity — bundle is unsigned (local use only)"
fi

# ---------------------------------------------------------------------------
# Create DMG
if $CREATE_DMG; then
    echo "==> Creating DMG: $DMG_NAME"
    rm -f "$DMG_PATH"

    # Create a sparse image, copy app, convert to read-only compressed DMG.
    TEMP_DMG="$ROOT/zig-out/forge-tmp.dmg"
    rm -f "$TEMP_DMG"

    hdiutil create \
        -srcfolder "$APP_BUNDLE" \
        -volname "${APP_NAME} ${VERSION}" \
        -fs HFS+ \
        -format UDRW \
        -size 256m \
        "$TEMP_DMG"

    # Convert to compressed read-only DMG.
    hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"
    rm -f "$TEMP_DMG"

    # Sign the DMG too (if identity available).
    if [ -n "$SIGN_IDENTITY" ]; then
        codesign --force --sign "$SIGN_IDENTITY" "$DMG_PATH"
        echo "    => DMG signed OK"
    fi

    echo "    => DMG: $DMG_PATH"

    # Print SHA256 for release notes / update feed.
    echo "==> SHA256:"
    shasum -a 256 "$DMG_PATH"
else
    echo "    [skip] DMG not requested (pass --dmg to create)"
fi

# ---------------------------------------------------------------------------
# Notarization (requires --sign + FORGE_NOTARIZE_PROFILE env var)
if [ -n "$SIGN_IDENTITY" ] && [ -n "$NOTARIZE_PROFILE" ] && $CREATE_DMG; then
    echo "==> Notarizing DMG (profile: $NOTARIZE_PROFILE)..."
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARIZE_PROFILE" \
        --wait
    xcrun stapler staple "$DMG_PATH"
    echo "    => Notarized and stapled OK"
elif $CREATE_DMG; then
    echo "    [skip] Notarization requires FORGE_SIGN_IDENTITY + FORGE_NOTARIZE_PROFILE"
fi

# ---------------------------------------------------------------------------
echo ""
echo "==> Done!"
echo "    App bundle : $APP_BUNDLE"
if $CREATE_DMG; then
    echo "    DMG        : $DMG_PATH"
fi
echo ""
echo "    Run locally: open \"$APP_BUNDLE\""
