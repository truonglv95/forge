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
cp -R "$ROOT/fixtures/sample.txt" "$WS/"
cp -R "$ROOT/fixtures/proposals" "$WS/"

echo "== eval: context secret trap =="
echo 'API_KEY=secret' > "$WS/.env"
CTX=$("$FORGE" context "review" --file .env --workspace "$WS" --json)
if printf '%s' "$CTX" | grep -q '"name":".env".*"included":true'; then
  echo "FAIL: .env should not be included in context"
  exit 1
fi

echo "== eval: ask -> diff -> dry-run apply =="
OUT=$("$FORGE" ask "create eval note" --workspace "$WS" --json --quiet)
RUN_ID=$(printf '%s' "$OUT" | sed -n 's/.*"run_id":"\([^"]*\)".*/\1/p')
PROP=$(printf '%s' "$OUT" | sed -n 's/.*"proposal_path":"\([^"]*\)".*/\1/p')
if [[ -z "$RUN_ID" || -z "$PROP" ]]; then
  echo "FAIL: ask did not produce run/proposal paths"
  echo "$OUT"
  exit 1
fi

"$FORGE" run show "$RUN_ID" --workspace "$WS" --json --quiet >/dev/null
"$FORGE" diff "$PROP" --workspace "$WS" --json --quiet >/dev/null
"$FORGE" apply "$PROP" --workspace "$WS" --dry-run --json --quiet >/dev/null

echo "== eval: stale hash rejection =="
echo "changed content" > "$WS/sample.txt"
STALE="proposals/modify-sample.proposal.json"
if "$FORGE" apply "$STALE" --workspace "$WS" --yes 2>/dev/null; then
  echo "FAIL: stale proposal should not apply"
  exit 1
fi

echo "PASS: eval safety slice ($RUN_ID)"
