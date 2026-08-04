#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DRY_RUN="${1:-}"
if [[ -z "${NPM_TOKEN:-}" ]]; then
  echo "error: NPM_TOKEN env var is required" >&2; exit 1
fi
mkdir -p "${HOME}/.npm"
cat > "${HOME}/.npmrc" <<EOF
//registry.npmjs.org/:_authToken=${NPM_TOKEN}
always-auth=true
EOF
chmod 0600 "${HOME}/.npmrc"
PUBLISH_FLAGS="--access public"
if [[ "${DRY_RUN}" == "--dry-run" ]]; then
  PUBLISH_FLAGS="${PUBLISH_FLAGS} --dry-run"
fi
PLATFORM_PKGS=(
  forge-cli-linux-x64
  forge-cli-linux-arm64
  forge-cli-darwin-x64
  forge-cli-darwin-arm64
  forge-cli-win32-x64
)
for pkg in "${PLATFORM_PKGS[@]}"; do
  pkg_dir="${ROOT}/npm/${pkg}"
  if [[ ! -d "${pkg_dir}" ]]; then
    echo "error: missing platform package dir: ${pkg_dir}" >&2; exit 1
  fi
  if [[ ! -f "${pkg_dir}/forge" && ! -f "${pkg_dir}/forge.exe" ]]; then
    echo "error: ${pkg} is missing its binary" >&2; exit 1
  fi
done
for pkg in "${PLATFORM_PKGS[@]}"; do
  echo "==> Publishing @forge-ai/${pkg}"
  (cd "${ROOT}/npm/${pkg}" && npm publish ${PUBLISH_FLAGS})
done
echo "==> Publishing @forge-ai/cli"
(cd "${ROOT}/npm/forge-cli" && npm publish ${PUBLISH_FLAGS})
echo "==> All packages published."
