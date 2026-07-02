#!/usr/bin/env bash
set -euo pipefail

readonly required_zig_version="0.16.0"
readonly fmt_paths=(build.zig apps packages)

usage() {
  cat <<'EOF'
Usage: scripts/check.sh [--fast | --full]

  --fast   Format and AST check only (default for pre-commit)
  --full   Format, build, and test (matches CI; default when run directly)

Environment:
  FORGE_CHECK=fast|full   Same as the flags above
EOF
}

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

mode="${FORGE_CHECK:-full}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fast)
      mode="fast"
      shift
      ;;
    --full)
      mode="full"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
done

echo "→ zig fmt --check --ast-check ${fmt_paths[*]}"
zig fmt --check --ast-check "${fmt_paths[@]}"

if [[ "${mode}" == "fast" ]]; then
  echo "✓ fast checks passed"
  exit 0
fi

echo "→ zig build"
zig build

echo "→ zig build test"
zig build test

echo "✓ all checks passed"
