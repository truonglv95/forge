#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/strip-cursor-coauthor.sh <commit-msg-file>

Removes Cursor agent Co-authored-by trailers from a commit message file.
EOF
}

main() {
  if [[ $# -ne 1 ]]; then
    usage >&2
    exit 2
  fi

  local msg_file="$1"
  if [[ ! -f "${msg_file}" ]]; then
    echo "error: commit message file not found: ${msg_file}" >&2
    exit 1
  fi

  local tmp
  tmp="$(mktemp)"
  grep -Ev '^Co-authored-by: Cursor <cursoragent@cursor\.com>$' "${msg_file}" >"${tmp}" || true
  mv "${tmp}" "${msg_file}"
}

main "$@"
