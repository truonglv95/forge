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

PROVIDER_FLAGS=(--provider fake)

echo "== eval: context secret trap =="
echo 'API_KEY=secret' > "$WS/.env"
CTX=$("$FORGE" context "review" --file .env --workspace "$WS" --json)
if printf '%s' "$CTX" | grep -q '"name":".env".*"included":true'; then
  echo "FAIL: .env should not be included in context"
  exit 1
fi

echo "== eval: context secret pattern in file =="
echo 'const key = "sk-test123456789";' > "$WS/leak.zig"
CTX2=$("$FORGE" context "review" --file leak.zig --workspace "$WS" --json)
if printf '%s' "$CTX2" | grep -q '"name":"leak.zig".*"included":true'; then
  echo "FAIL: leak.zig with sk- pattern should be excluded"
  exit 1
fi

echo "== eval: context byte budget truncation =="
python3 -c 'print("x" * 500)' > "$WS/large.txt"
CTX3=$("$FORGE" context "review" --file large.txt --workspace "$WS" --budget-bytes 100 --json)
if ! printf '%s' "$CTX3" | grep -q '"truncated":true'; then
  echo "FAIL: large.txt should be truncated under budget"
  echo "$CTX3"
  exit 1
fi

echo "== eval: ask -> diff -> apply -> undo =="
OUT=$("$FORGE" ask "create eval note" --workspace "$WS" "${PROVIDER_FLAGS[@]}" --json --quiet)
RUN_ID=$(printf '%s' "$OUT" | sed -n 's/.*"run_id":"\([^"]*\)".*/\1/p')
PROP=$(printf '%s' "$OUT" | sed -n 's/.*"proposal_path":"\([^"]*\)".*/\1/p')
if [[ -z "$RUN_ID" || -z "$PROP" ]]; then
  echo "FAIL: ask did not produce run/proposal paths"
  echo "$OUT"
  exit 1
fi

"$FORGE" run show "$RUN_ID" --workspace "$WS" --json --quiet >/dev/null
"$FORGE" diff "$PROP" --workspace "$WS" --json --quiet >/dev/null
APPLY_OUT=$("$FORGE" apply "$PROP" --workspace "$WS" --yes --json --quiet)
TX_ID=$(printf '%s' "$APPLY_OUT" | sed -n 's/.*"transaction_id":\([0-9][0-9]*\).*/\1/p')
if [[ -z "$TX_ID" ]]; then
  echo "FAIL: apply did not return transaction_id"
  echo "$APPLY_OUT"
  exit 1
fi

"$FORGE" undo "$TX_ID" --workspace "$WS" --json --quiet >/dev/null

echo "== eval: agent run =="
AGENT_OUT=$("$FORGE" agent run "search sample" --workspace "$WS" "${PROVIDER_FLAGS[@]}" --json --quiet)
if ! printf '%s' "$AGENT_OUT" | grep -q '"type":"agent_run"'; then
  echo "FAIL: agent run did not complete"
  echo "$AGENT_OUT"
  exit 1
fi
SESSION_ID=$(printf '%s' "$AGENT_OUT" | sed -n 's/.*"session_id":"\([^"]*\)".*/\1/p')
if [[ -z "$SESSION_ID" ]]; then
  echo "FAIL: agent run did not return session_id"
  exit 1
fi

echo "== eval: agent resume =="
RESUME_OUT=$("$FORGE" agent resume "$SESSION_ID" --workspace "$WS" "${PROVIDER_FLAGS[@]}" --json --quiet)
if ! printf '%s' "$RESUME_OUT" | grep -q '"type":"agent_resume"'; then
  echo "FAIL: agent resume did not complete"
  echo "$RESUME_OUT"
  exit 1
fi

echo "== eval: agent step limit =="
if "$FORGE" agent run "search sample" --workspace "$WS" "${PROVIDER_FLAGS[@]}" --max-steps 1 --json --quiet 2>/dev/null; then
  echo "FAIL: agent with --max-steps 1 should fail before propose"
  exit 1
fi

echo "== eval: stale hash rejection =="
echo "changed content" > "$WS/sample.txt"
STALE="proposals/modify-sample.proposal.json"
if "$FORGE" apply "$STALE" --workspace "$WS" --yes 2>/dev/null; then
  echo "FAIL: stale proposal should not apply"
  exit 1
fi

echo "== eval: forge doctor =="
if ! "$FORGE" doctor --workspace "$WS" --json --quiet | grep -q '"ready":true'; then
  echo "FAIL: doctor reported not ready"
  exit 1
fi

echo "== eval: doctor fake provider =="
if ! "$FORGE" doctor --provider fake --json --quiet | grep -q '"ai.provider".*"ok":true'; then
  echo "FAIL: doctor --provider fake should report ok"
  exit 1
fi

echo "== eval: corpus tasks =="
bash "$ROOT/scripts/eval_corpus.sh"

echo "== eval: agent fixture tasks =="
bash "$ROOT/scripts/eval_agent.sh"

echo "== eval: agent reliability baseline =="
bash "$ROOT/scripts/eval_reliability.sh" --provider fake --min-success-rate 0.66

echo "PASS: eval safety slice ($RUN_ID)"
