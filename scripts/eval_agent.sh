#!/usr/bin/env bash
# Phase 2 agent fixture tasks (5 scenarios)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FORGE="${FORGE:-$ROOT/zig-out/bin/forge}"
WS="${AGENT_EVAL_WORKSPACE:-$ROOT/fixtures/agent-eval-workspace}"

if [[ ! -x "$FORGE" ]]; then
  (cd "$ROOT" && zig build)
fi

rm -rf "$WS"
mkdir -p "$WS"
cp "$ROOT/fixtures/sample.txt" "$WS/"
PROVIDER=(--provider fake)

echo "== agent fixture 1: search + propose (max-steps 2) =="
OUT=$("$FORGE" agent run "search sample" --workspace "$WS" "${PROVIDER[@]}" --max-steps 2 --json --quiet)
if ! printf '%s' "$OUT" | grep -q '"steps":2'; then
  echo "FAIL: expected 2 steps"
  echo "$OUT"
  exit 1
fi

echo "== agent fixture 2: list_tree step (max-steps 3) =="
OUT2=$("$FORGE" agent run "search sample" --workspace "$WS" "${PROVIDER[@]}" --max-steps 3 --json --quiet)
SESSION=$(printf '%s' "$OUT2" | sed -n 's/.*"session_id":"\([^"]*\)".*/\1/p')
if [[ -z "$SESSION" ]]; then
  echo "FAIL: no session_id"
  exit 1
fi
if ! grep -q 'list_tree' "$WS/.forge/sessions/${SESSION}.json"; then
  echo "FAIL: session missing list_tree tool call"
  exit 1
fi

echo "== agent fixture 3: read_only answers without proposal =="
READ_ONLY=$("$FORGE" agent run "search sample" --workspace "$WS" "${PROVIDER[@]}" --capability read_only --max-steps 8 --json --quiet)
if ! printf '%s' "$READ_ONLY" | grep -q '"proposal_path":""'; then
  echo "FAIL: read_only mode created a proposal"
  echo "$READ_ONLY"
  exit 1
fi

echo "== agent fixture 4: agent list =="
LIST=$("$FORGE" agent list --workspace "$WS" --json --quiet)
if ! printf '%s' "$LIST" | grep -q '"session_id"'; then
  echo "FAIL: agent list empty"
  echo "$LIST"
  exit 1
fi

echo "== agent fixture 5: resume completed session =="
RESUME=$("$FORGE" agent resume "$SESSION" --workspace "$WS" "${PROVIDER[@]}" --json --quiet)
if ! printf '%s' "$RESUME" | grep -q '"type":"agent_resume"'; then
  echo "FAIL: resume failed"
  echo "$RESUME"
  exit 1
fi

echo "PASS: agent fixture tasks (5/5)"
