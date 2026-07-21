#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TARGETS=(
  "apps/forge-ide/src"
  "packages/ai/src"
  "packages/workspace/src"
)

PATTERN='catch \{\}|catch return|catch unreachable'

echo "Forge catch audit"
echo "Pattern: $PATTERN"
echo

for target in "${TARGETS[@]}"; do
  count="$(rg -n "$PATTERN" "$target" -g '*.zig' | wc -l | tr -d ' ')"
  printf "%-28s %s\n" "$target" "$count"
done

echo
echo "Top files:"
rg -n "$PATTERN" "${TARGETS[@]}" -g '*.zig' \
  | cut -d: -f1 \
  | sort \
  | uniq -c \
  | sort -nr \
  | head -20
