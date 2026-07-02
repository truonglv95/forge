#!/usr/bin/env bash
set -euo pipefail

readonly required_zig_version="0.16.0"

if ! command -v zig >/dev/null 2>&1; then
  echo "error: Zig ${required_zig_version} is required but was not found" >&2
  exit 1
fi

actual_zig_version="$(zig version)"
if [[ "${actual_zig_version}" != "${required_zig_version}" ]]; then
  echo "error: expected Zig ${required_zig_version}, found ${actual_zig_version}" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

readonly directories=(
  apps/forge-cli/src
  apps/forge-ide/src
  apps/forge-agent/src
  packages/core/src
  packages/kernel/src
  packages/workspace/src
  packages/editor/src
  packages/renderer/src
  packages/lsp/src
  packages/ai/src
  packages/plugin/src
  packages/util/src
  docs/architecture
  docs/roadmap
  docs/rfc
  examples
  tools
  third_party
)

mkdir -p "${directories[@]}"

echo "Using Zig ${actual_zig_version}"
echo "Running Forge checks..."
./scripts/check.sh --full

echo "Forge foundation is ready."
echo "Tip: enable git hooks with: git config core.hooksPath .githooks"
