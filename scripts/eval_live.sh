#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROVIDER="${1:-gemini}"
MIN_RATE="${MIN_SUCCESS_RATE:-0.66}"
OUTPUT="${EVAL_OUTPUT:-$ROOT/.forge/evals/live-${PROVIDER}.jsonl}"
CORPUS="${EVAL_CORPUS:-$ROOT/fixtures/eval/agent_reliability.json}"

# Provider credential/availability check.
# Each provider maps to one or more env vars; we SKIP (exit 0) when no
# credentials are present so a CI run can invoke this script for every
# provider without failing on the ones that aren't configured.
case "$PROVIDER" in
  gemini)
    if [[ -z "${GEMINI_API_KEY:-}" && -z "${GOOGLE_API_KEY:-}" ]]; then
      echo "SKIP: live eval ($PROVIDER) — no GEMINI_API_KEY or GOOGLE_API_KEY"
      exit 0
    fi
    ;;
  anthropic)
    if [[ -z "${ANTHROPIC_API_KEY:-}" && -z "${CLAUDE_API_KEY:-}" ]]; then
      echo "SKIP: live eval ($PROVIDER) — no ANTHROPIC_API_KEY or CLAUDE_API_KEY"
      exit 0
    fi
    ;;
  openai)
    if [[ -z "${OPENAI_API_KEY:-}" ]]; then
      echo "SKIP: live eval ($PROVIDER) — no OPENAI_API_KEY"
      exit 0
    fi
    ;;
  openrouter)
    if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
      echo "SKIP: live eval ($PROVIDER) — no OPENROUTER_API_KEY"
      exit 0
    fi
    ;;
  nvidia)
    if [[ -z "${NVIDIA_API_KEY:-}" ]]; then
      echo "SKIP: live eval ($PROVIDER) — no NVIDIA_API_KEY"
      exit 0
    fi
    ;;
  groq)
    if [[ -z "${GROQ_API_KEY:-}" ]]; then
      echo "SKIP: live eval ($PROVIDER) — no GROQ_API_KEY"
      exit 0
    fi
    ;;
  cerebras)
    if [[ -z "${CEREBRAS_API_KEY:-}" ]]; then
      echo "SKIP: live eval ($PROVIDER) — no CEREBRAS_API_KEY"
      exit 0
    fi
    ;;
  zai)
    # Z.AI uses /etc/.z-ai-config (pre-auth) or ZAI_TOKEN env var.
    if [[ -z "${ZAI_TOKEN:-}" && ! -r /etc/.z-ai-config && ! -r ~/.z-ai-config ]]; then
      echo "SKIP: live eval ($PROVIDER) — no /etc/.z-ai-config and no ZAI_TOKEN"
      echo "  Install z-ai-web-dev-sdk CLI: npm i -g z-ai-web-dev-sdk"
      exit 0
    fi
    ;;
  ollama)
    if ! command -v ollama >/dev/null 2>&1; then
      echo "SKIP: live eval ($PROVIDER) — ollama not installed"
      exit 0
    fi
    if ! curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
      echo "SKIP: live eval ($PROVIDER) — ollama server not reachable"
      exit 0
    fi
    ;;
  fake)
    # Always available — used as a baseline.
    ;;
  *)
    echo "error: unsupported provider '$PROVIDER'"
    echo "supported: zai | gemini | anthropic | openai | openrouter | nvidia | groq | cerebras | ollama | fake"
    exit 2
    ;;
esac

# Locate zig binary — prefer PATH, fall back to pip-installed ziglang.
ZIG_BIN="$(command -v zig 2>/dev/null || true)"
if [[ -z "$ZIG_BIN" ]]; then
  ZIG_BIN="$HOME/.local/lib/python3.13/site-packages/ziglang/zig"
fi
if [[ ! -x "$ZIG_BIN" ]]; then
  echo "ERROR: zig binary not found. Install with 'pip install ziglang' or add to PATH."
  exit 2
fi
export C_INCLUDE_PATH="${C_INCLUDE_PATH:-/home/z/.local/include}"
export LIBRARY_PATH="${LIBRARY_PATH:-/home/z/.local/lib}"

echo "==> Building forge (if needed)..."
(cd "$ROOT" && "$ZIG_BIN" build)

echo "==> Running eval corpus against: $PROVIDER"
exec python3 "$ROOT/scripts/eval_reliability.py" \
  --provider "$PROVIDER" \
  --corpus "$CORPUS" \
  --min-success-rate "$MIN_RATE" \
  --repeat "${EVAL_REPEAT:-1}" \
  --max-steps "${EVAL_MAX_STEPS:-8}" \
  --output "$OUTPUT" \
  ${EVAL_MODEL:+--model "$EVAL_MODEL"}
