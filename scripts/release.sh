#!/usr/bin/env bash
# scripts/release.sh — Orchestrate a Forge release.
#
# Usage:
#   ./scripts/release.sh --version 0.2.0 [--dmg] [--push-tag]
#
# Steps:
#   1. Validate clean git state
#   2. Bump version in forge.toml + Info.plist
#   3. Build + package (calls package-mac.sh)
#   4. Compute and print SHA256
#   5. Print appcast.xml snippet for manual update
#   6. Optionally create and push a git tag

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ---------------------------------------------------------------------------
VERSION=""
CREATE_DMG=false
PUSH_TAG=false

for arg in "$@"; do
    case "$arg" in
        --version=*) VERSION="${arg#--version=}" ;;
        --version)   shift; VERSION="${1:-}" ;;
        --dmg)       CREATE_DMG=true ;;
        --push-tag)  PUSH_TAG=true ;;
    esac
done

if [ -z "$VERSION" ]; then
    echo "Error: --version is required" >&2
    echo "Usage: $0 --version x.y.z [--dmg] [--push-tag]" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
echo "==> Forge Release v${VERSION}"

# Require clean working tree.
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Error: working tree has uncommitted changes" >&2
    git status --short >&2
    exit 1
fi

# ---------------------------------------------------------------------------
echo "==> Bumping version in forge.toml..."
if grep -q "^version" forge.toml 2>/dev/null; then
    sed -i '' "s/^version = \".*\"/version = \"${VERSION}\"/" forge.toml
else
    # Append version line if not present.
    echo "" >> forge.toml
    echo "version = \"${VERSION}\"" >> forge.toml
fi

# ---------------------------------------------------------------------------
echo "==> Building and packaging..."
PACKAGE_ARGS="--version=${VERSION}"
if $CREATE_DMG; then
    PACKAGE_ARGS="$PACKAGE_ARGS --dmg"
fi

export FORGE_VERSION="$VERSION"
bash "$ROOT/scripts/package-mac.sh" $PACKAGE_ARGS

# ---------------------------------------------------------------------------
DMG_PATH="$ROOT/zig-out/Forge-${VERSION}-$(uname -m).dmg"
if $CREATE_DMG && [ -f "$DMG_PATH" ]; then
    SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
    DMG_SIZE=$(stat -f%z "$DMG_PATH")
    ARCH="$(uname -m)"

    echo ""
    echo "==> SHA256: ${SHA256}"
    echo ""
    echo "==> appcast.xml snippet (update scripts/appcast.xml with these values):"
    cat <<XML
  <item>
    <title>Forge IDE ${VERSION}</title>
    <sparkle:version>${VERSION}</sparkle:version>
    <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
    <pubDate>$(date -R)</pubDate>
    <enclosure
      url="https://github.com/YOUR_ORG/forge/releases/download/v${VERSION}/Forge-${VERSION}-${ARCH}.dmg"
      sparkle:edSignature="REPLACE_WITH_ED25519_SIG"
      length="${DMG_SIZE}"
      type="application/octet-stream"/>
    <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
    <description>See release notes at https://forge.dev/changelog</description>
  </item>
XML
fi

# ---------------------------------------------------------------------------
if $PUSH_TAG; then
    echo ""
    echo "==> Committing version bump and tagging v${VERSION}..."
    git add forge.toml
    git commit -m "chore(release): bump version to ${VERSION}"
    git tag -a "v${VERSION}" -m "Forge IDE v${VERSION}"
    git push origin HEAD "v${VERSION}"
    echo "    => Tag v${VERSION} pushed"
else
    echo ""
    echo "    [skip] Pass --push-tag to commit and push the release tag"
fi

echo ""
echo "==> Release v${VERSION} complete."
