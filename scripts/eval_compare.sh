#!/usr/bin/env bash
# eval_compare.sh — run eval corpus against every provider that has
# credentials configured, then print a side-by-side comparison table.
#
# Usage:
#   scripts/eval_compare.sh                 # default corpus, 1 repeat
#   EVAL_CORPUS=fixtures/eval/provider_comparison.json \
#     EVAL_REPEAT=3 scripts/eval_compare.sh
#
# Output:
#   .forge/evals/compare-<timestamp>.json   — combined summary
#   stdout                                  — formatted comparison table
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUTDIR="$ROOT/.forge/evals"
mkdir -p "$OUTDIR"

CORPUS="${EVAL_CORPUS:-$ROOT/fixtures/eval/agent_reliability.json}"
REPEAT="${EVAL_REPEAT:-1}"
MAX_STEPS="${EVAL_MAX_STEPS:-8}"

# Detect which providers have credentials.
AVAILABLE=()
[[ -n "${GEMINI_API_KEY:-}" || -n "${GOOGLE_API_KEY:-}" ]] && AVAILABLE+=(gemini)
[[ -n "${ANTHROPIC_API_KEY:-}" || -n "${CLAUDE_API_KEY:-}" ]] && AVAILABLE+=(anthropic)
[[ -n "${OPENAI_API_KEY:-}" ]] && AVAILABLE+=(openai)
[[ -n "${OPENROUTER_API_KEY:-}" ]] && AVAILABLE+=(openrouter)
[[ -n "${NVIDIA_API_KEY:-}" ]] && AVAILABLE+=(nvidia)
if command -v ollama >/dev/null 2>&1 && curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
  AVAILABLE+=(ollama)
fi
AVAILABLE+=(fake) # baseline — always available

if [[ ${#AVAILABLE[@]} -eq 1 ]]; then
  echo "No paid LLM providers have API keys configured."
  echo "Set one of: GEMINI_API_KEY, ANTHROPIC_API_KEY, OPENAI_API_KEY,"
  echo "OPENROUTER_API_KEY, NVIDIA_API_KEY, or run ollama locally."
  echo "Running only the 'fake' baseline."
fi

echo "==> Providers to evaluate: ${AVAILABLE[*]}"
echo "==> Corpus: $CORPUS"
echo "==> Repeat: $REPEAT"
echo

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

# Build once upfront so each provider eval doesn't rebuild.
echo "==> Building forge..."
(cd "$ROOT" && "$ZIG_BIN" build)

# Run eval against each provider, collect summaries.
declare -a SUMMARY_FILES=()
for PROVIDER in "${AVAILABLE[@]}"; do
  OUTPUT="$OUTDIR/compare-${TIMESTAMP}-${PROVIDER}.jsonl"
  echo "==> Evaluating: $PROVIDER"

  EVAL_OUTPUT="$OUTPUT" \
  EVAL_CORPUS="$CORPUS" \
  EVAL_REPEAT="$REPEAT" \
  EVAL_MAX_STEPS="$MAX_STEPS" \
  EVAL_MODEL="${EVAL_MODEL:-}" \
    python3 "$ROOT/scripts/eval_reliability.py" \
      --provider "$PROVIDER" \
      --corpus "$CORPUS" \
      --repeat "$REPEAT" \
      --max-steps "$MAX_STEPS" \
      --output "$OUTPUT" \
      --min-success-rate 0.0 \
      ${EVAL_MODEL:+--model "$EVAL_MODEL"} \
      > "$OUTDIR/compare-${TIMESTAMP}-${PROVIDER}.stdout.json" || true

  # The eval script writes a .summary.json alongside the .jsonl
  SUMMARY="$OUTDIR/compare-${TIMESTAMP}-${PROVIDER}.summary.json"
  if [[ -f "$SUMMARY" ]]; then
    SUMMARY_FILES+=("$SUMMARY")
  fi
done

# Merge summaries and print comparison table.
REPORT_ARGS=(--timestamp "$TIMESTAMP" --outdir "$OUTDIR" --baseline-name "fake")
for SF in "${SUMMARY_FILES[@]}"; do
  REPORT_ARGS+=(--summary "$SF")
done
python3 "$ROOT/scripts/eval_compare_report.py" "${REPORT_ARGS[@]}"
