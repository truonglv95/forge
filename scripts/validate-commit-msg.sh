#!/usr/bin/env bash
set -euo pipefail

readonly allowed_types=(
  feat fix docs style refactor test chore ci build perf revert
)

readonly allowed_scopes=(
  forge-cli forge-ide forge-agent
  core kernel workspace editor renderer lsp ai plugin util
  build ci docs scripts repo
)

usage() {
  cat <<'EOF'
Usage: scripts/validate-commit-msg.sh <commit-msg-file>

Validates the first line of a Git commit message against Forge's convention.
See docs/COMMIT_CONVENTION.md for examples.
EOF
}

contains() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    if [[ "${item}" == "${needle}" ]]; then
      return 0
    fi
  done
  return 1
}

skip_validation() {
  local header="$1"
  [[ "${header}" =~ ^Merge\  ]] && return 0
  [[ "${header}" =~ ^Revert\  ]] && return 0
  [[ "${header}" =~ ^fixup! ]] && return 0
  [[ "${header}" =~ ^squash! ]] && return 0
  return 1
}

validate_header() {
  local header="$1"

  if skip_validation "${header}"; then
    return 0
  fi

  if [[ "${#header}" -gt 72 ]]; then
    echo "error: commit header exceeds 72 characters (${#header})" >&2
    return 1
  fi

  if [[ ! "${header}" =~ ^([a-z]+)\(([a-z0-9-]+)\)(!)?:\ (.+)$ ]]; then
    echo "error: commit header must match: type(scope): subject" >&2
    return 1
  fi

  local type="${BASH_REMATCH[1]}"
  local scope="${BASH_REMATCH[2]}"
  local breaking="${BASH_REMATCH[3]}"
  local subject="${BASH_REMATCH[4]}"

  if ! contains "${type}" "${allowed_types[@]}"; then
    echo "error: unknown type '${type}'" >&2
    echo "allowed types: ${allowed_types[*]}" >&2
    return 1
  fi

  if ! contains "${scope}" "${allowed_scopes[@]}"; then
    echo "error: unknown scope '${scope}'" >&2
    echo "allowed scopes: ${allowed_scopes[*]}" >&2
    return 1
  fi

  if [[ "${breaking}" == "!" && "${type}" != "feat" && "${type}" != "fix" ]]; then
    echo "error: breaking change marker '!' is only allowed with feat or fix" >&2
    return 1
  fi

  if [[ "${subject}" == *"." ]]; then
    echo "error: subject must not end with a period" >&2
    return 1
  fi

  if [[ "${subject}" =~ ^[A-Z] ]]; then
    echo "error: subject should start with a lowercase letter (imperative mood)" >&2
    return 1
  fi

  return 0
}

print_helpful_examples() {
  cat >&2 <<'EOF'

Examples:
  feat(forge-cli): add inspect subcommand
  fix(workspace): reject duplicate paths in validate
  docs(docs): update M1 checklist
  ci(ci): run check.sh in GitHub Actions

See docs/COMMIT_CONVENTION.md for the full list of types and scopes.
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

  local header
  header="$(grep -Ev '^\s*(#|$)' "${msg_file}" | head -n 1 || true)"
  header="${header//$'\r'/}"

  if [[ -z "${header}" ]]; then
    echo "error: commit message is empty" >&2
    print_helpful_examples
    exit 1
  fi

  if ! validate_header "${header}"; then
    echo "header: ${header}" >&2
    print_helpful_examples
    exit 1
  fi
}

main "$@"
