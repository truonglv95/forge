# RFC-0005: Run and Session Records

**Status:** Accepted  
**Date:** 2026-07-03

## Summary

Forge records every AI interaction as a versioned **Run** stored under
`.forge/runs/`. Runs link intents to proposals, transactions, and validation
outcomes. Agent **Sessions** (multi-step) are a later extension built on run IDs.

## Run schema (v1)

```json
{
  "schema_version": 1,
  "run_id": "run_1783093228577",
  "surface": "cli",
  "intent": "add integration test",
  "state": "proposed",
  "proposal_path": ".forge/proposals/run_1783093228577.json",
  "transaction_id": 0,
  "provider_id": "fake",
  "model_id": "fake-model-1",
  "timestamp_ms": 1783093228577
}
```

### States

`planning` → `proposed` → `reviewing` → `applying` → `verifying` → `done`

Failure/cancel: `failed`, `cancelled`

### Surfaces

`cli`, `ide`, `agent_window` — same schema, different UX origin.

## Storage layout

```text
.forge/
  runs/
    index.jsonl          # append-only index for listing
    run_<timestamp>.json # full record
  proposals/
    run_<timestamp>.json # proposal payload (WorkspaceEdit JSON)
  history.jsonl          # transaction journal (existing)
```

## Rules

1. Runs are append-mostly; state updates rewrite the run JSON file atomically.
2. Runs never store raw provider API keys or full prompt dumps by default.
3. `proposal_path` must point inside workspace or `.forge/proposals/`.
4. CLI commands `forge ask` create runs; `forge apply` updates `transaction_id`
   and state via future hook.
5. Session schema (v1 deferred): `{ session_id, run_ids[], mode, approval_policy }`.

## Implementation

- `packages/ai/src/run_record.zig` — types + JSON formatting
- `packages/workspace/src/runs.zig` — atomic persistence
- `forge ask` — first consumer

## Exit criteria

- [x] Schema documented
- [x] CLI writes run + index on `forge ask`
- [x] `forge run list/show` commands
- [ ] IDE/agents window use same paths
