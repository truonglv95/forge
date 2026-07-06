#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FORGE="${FORGE:-$ROOT/zig-out/bin/forge}"
WS="${EVAL_WORKSPACE:-$ROOT/fixtures/eval-workspace}"

if [[ ! -x "$FORGE" ]]; then
  echo "Building forge CLI..."
  (cd "$ROOT" && zig build)
fi

rm -rf "$WS"
mkdir -p "$WS"
cp "$ROOT/fixtures/sample.txt" "$WS/"

assert_absent() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if printf '%s' "$haystack" | grep -q "$needle"; then
    echo "FAIL: $label — found '$needle'"
    exit 1
  fi
}

assert_present() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if ! printf '%s' "$haystack" | grep -q "$needle"; then
    echo "FAIL: $label — missing '$needle'"
    printf '%s\n' "$haystack"
    exit 1
  fi
}

echo "== eval: routing explore intent skips git diff =="
EXPLORE_OUT=$("$FORGE" context "find all session helpers" --workspace "$WS" --mode agent)
assert_present "$EXPLORE_OUT" "Routing: task=explore_codebase" "explore routing task"
assert_present "$EXPLORE_OUT" "routing" "routing manifest block"
assert_absent "$EXPLORE_OUT" "git:working-tree" "explore should omit git diff"
assert_absent "$EXPLORE_OUT" "replace_file_content" "explore should omit edit tools in summary"

echo "== eval: routing ask mode omits edit tools =="
ASK_OUT=$("$FORGE" context "what does sample.txt contain" --workspace "$WS" --mode ask)
assert_present "$ASK_OUT" "Routing: task=answer_question profile=read_only" "ask routing profile"
assert_present "$ASK_OUT" "read_file" "ask keeps read tools"
assert_absent "$ASK_OUT" "replace_file_content" "ask omits edit tools"
assert_absent "$ASK_OUT" "run_command" "ask omits run_command"

echo "== eval: routing agent edit intent keeps edit tools =="
EDIT_OUT=$("$FORGE" context "refactor session helpers" --workspace "$WS" --mode agent)
assert_present "$EDIT_OUT" "Routing: task=edit_code" "edit routing task"
assert_present "$EDIT_OUT" "replace_file_content" "edit keeps replace tool"
assert_present "$EDIT_OUT" "run_command" "edit keeps run_command"

echo "== eval: routing debug intent prioritizes diagnostics policy =="
DEBUG_OUT=$("$FORGE" context "fix validation failed error" --workspace "$WS" --mode agent)
assert_present "$DEBUG_OUT" "Routing: task=debug_failure" "debug routing task"

echo "PASS: routing eval"
