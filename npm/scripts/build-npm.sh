#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ZIG_BIN="${ZIG_BIN:-zig}"
OPTIMIZE="${OPTIMIZE:-ReleaseSafe}"
WITH_GLX_FLAG=""
if [[ "${WITH_GLX:-true}" == "false" ]]; then
  WITH_GLX_FLAG="-Dwith-glx=false"
fi
cd "${ROOT}"
echo "==> Building forge with ${ZIG_BIN} (${OPTIMIZE})"
"${ZIG_BIN}" build -Doptimize="${OPTIMIZE}" ${WITH_GLX_FLAG}
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "${OS}" in
  linux)  OS_NORM="linux" ;;
  darwin) OS_NORM="darwin" ;;
  mingw*|msys*|cygwin*|windows*) OS_NORM="win32" ;;
  *) echo "error: unsupported OS: ${OS}" >&2; exit 1 ;;
esac
case "${ARCH}" in
  x86_64|amd64) ARCH_NORM="x64" ;;
  aarch64|arm64) ARCH_NORM="arm64" ;;
  *) echo "error: unsupported arch: ${ARCH}" >&2; exit 1 ;;
esac
PKG_DIR="${ROOT}/npm/forge-cli-${OS_NORM}-${ARCH_NORM}"
if [[ ! -d "${PKG_DIR}" ]]; then
  echo "error: platform package dir not found: ${PKG_DIR}" >&2; exit 1
fi
if [[ "${OS_NORM}" == "win32" ]]; then
  BIN_NAME="forge.exe"
else
  BIN_NAME="forge"
fi
SRC="${ROOT}/zig-out/bin/forge"
if [[ ! -f "${SRC}" ]]; then SRC="${ROOT}/zig-out/bin/forge.exe"; fi
if [[ ! -f "${SRC}" ]]; then
  echo "error: built binary not found at ${ROOT}/zig-out/bin/" >&2; exit 1
fi
DEST="${PKG_DIR}/${BIN_NAME}"
cp "${SRC}" "${DEST}"
chmod +x "${DEST}"
echo "==> Copied binary to npm/forge-cli-${OS_NORM}-${ARCH_NORM}/${BIN_NAME}"
ls -lh "${DEST}"
