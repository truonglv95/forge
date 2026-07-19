#!/usr/bin/env bash

# run_evals.sh
# Run reliability evaluations for different providers and generate JSONL baselines.

set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$DIR")"

EVAL_SCRIPT="$DIR/eval_reliability.py"

mkdir -p "$ROOT_DIR/.forge/evals"

echo "Running eval for Fake provider (Sanity check)..."
python3 "$EVAL_SCRIPT" --provider fake --output "$ROOT_DIR/.forge/evals/fake_baseline.jsonl"

echo "Running eval for Gemini provider..."
python3 "$EVAL_SCRIPT" --provider gemini --output "$ROOT_DIR/.forge/evals/gemini_baseline.jsonl"

echo "Running eval for Ollama provider..."
python3 "$EVAL_SCRIPT" --provider ollama --output "$ROOT_DIR/.forge/evals/ollama_baseline.jsonl"

echo "Running eval for OpenAI-compatible provider..."
python3 "$EVAL_SCRIPT" --provider openai --output "$ROOT_DIR/.forge/evals/openai_baseline.jsonl"

echo "Evaluations completed. Check .forge/evals for the JSONL baselines and JSON summaries."
