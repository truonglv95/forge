#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROVIDER="${1:-gemini}"
MIN_RATE="${MIN_SUCCESS_RATE:-0.66}"
OUTPUT="${EVAL_OUTPUT:-$ROOT/.forge/evals/live-${PROVIDER}.jsonl}"

if [[ "$PROVIDER" == "gemini" ]]; then
  if [[ -z "${GEMINI_API_KEY:-}" && -z "${GOOGLE_API_KEY:-}" ]]; then
    echo "SKIP: live eval ($PROVIDER) — no GEMINI_API_KEY or GOOGLE_API_KEY"
    exit 0
  fi
elif [[ "$PROVIDER" == "ollama" ]]; then
  if ! command -v ollama >/dev/null 2>&1; then
    echo "SKIP: live eval ($PROVIDER) — ollama not installed"
    exit 0
  fi
  if ! curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    echo "SKIP: live eval ($PROVIDER) — ollama server not reachable"
    exit 0
  fi
else
  echo "error: unsupported provider '$PROVIDER' (use gemini or ollama)"
  exit 2
fi

(cd "$ROOT" && zig build)
exec python3 "$ROOT/scripts/eval_reliability.py" \
  --provider "$PROVIDER" \
  --min-success-rate "$MIN_RATE" \
  --repeat "${EVAL_REPEAT:-1}" \
  --output "$OUTPUT" \
  ${EVAL_MODEL:+--model "$EVAL_MODEL"}
