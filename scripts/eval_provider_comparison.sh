#!/usr/bin/env bash
# Forge provider comparison benchmark.
#
# Runs `forge eval ai-flow` against multiple providers and prints a
# comparative report. Useful for choosing the best provider for a given
# corpus (latency, success rate, token cost).
#
# Usage:
#   scripts/eval_provider_comparison.sh <provider1,provider2,...> [corpus]
#
# Example:
#   scripts/eval_provider_comparison.sh fake,gemini,ollama
#   scripts/eval_provider_comparison.sh fake,gemini fixtures/eval/agent_reliability_extended.json
#   scripts/eval_provider_comparison.sh groq,cerebras,openrouter fixtures/eval/agent_reliability.json

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FORGE="$ROOT/zig-out/bin/forge"

if [ ! -x "$FORGE" ]; then
    echo "error: forge binary not found at $FORGE" >&2
    echo "Run 'zig build' first." >&2
    exit 2
fi

if [ $# -lt 1 ]; then
    echo "usage: $0 <provider1,provider2,...> [corpus]" >&2
    echo "" >&2
    echo "Providers: fake, zai, gemini, ollama, openai, anthropic, openrouter, nvidia, groq, cerebras" >&2
    echo "" >&2
    echo "Free-tier combos (no credit card required):" >&2
    echo "  $0 zai,groq,cerebras           # zero-config if /etc/.z-ai-config exists" >&2
    echo "  $0 zai,gemini,openrouter       # mix pre-auth + signup-based" >&2
    echo "  $0 groq,cerebras,gemini" >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  $0 fake,gemini,ollama" >&2
    echo "  $0 fake,gemini fixtures/eval/agent_reliability_extended.json" >&2
    exit 2
fi

PROVIDERS="$1"
CORPUS="${2:-fixtures/eval/agent_reliability.json}"
OUTPUT=".forge/evals/comparison_$(date +%Y%m%d_%H%M%S).jsonl"

echo "=== Provider Comparison Benchmark ==="
echo "Providers: $PROVIDERS"
echo "Corpus:    $CORPUS"
echo "Output:    $OUTPUT"
echo ""

cd "$ROOT"
"$FORGE" eval ai-flow \
    --providers "$PROVIDERS" \
    --corpus "$CORPUS" \
    --output "$OUTPUT" \
    --repeat 3 \
    --json

echo ""
echo "=== Summary ==="
"$FORGE" eval summary --output "$OUTPUT"

echo ""
echo "Full results saved to: $OUTPUT"
