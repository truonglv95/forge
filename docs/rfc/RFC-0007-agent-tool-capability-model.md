# RFC-0007: Agent Tool Capability Model

**Status:** Accepted  
**Date:** 2026-07-04

## Summary

Agent sessions invoke **tools** through a capability-scoped registry. Tools may
read workspace state or propose edits; only explicit approval can apply changes.

## Capability profiles

| Profile | Allowed tools |
|---|---|
| `read_only` | `read_file`, `search`, `list_tree`, `show_context` |
| `propose` | read tools + `propose_edit` |
| `propose_and_task` | propose tools + `run_task` (never `apply_proposal`) |

`apply_proposal` and `undo` require a separate human or CLI approval gate
(`--yes`, IDE button). Agents never auto-apply unless explicitly approved.

## Tool surface (v1)

```text
search(query)        → workspace content search
list_tree()          → file/dir counts under root
read_file(path)      → snapshot + hash summary
run_task(name)       → zig build test|build|fmt (argv array, no shell)
propose_edit()       → planner → proposal JSON on disk
```

## Session schema (v1)

```json
{
  "schema_version": 1,
  "session_id": "sess_1783113260319",
  "intent": "search sample",
  "capability_profile": "propose",
  "max_steps": 8,
  "run_ids": ["run_1783113260320"],
  "proposal_path": ".forge/proposals/run_1783113260320.json",
  "tool_calls": [
    { "index": 1, "tool": "search", "summary": "search 'search' -> 1 hits" },
    { "index": 2, "tool": "propose", "summary": "proposal at .forge/proposals/..." }
  ],
  "steps": []
}
```

`steps` mirrors agent step records for backward compatibility; `tool_calls` is
the canonical audit log for tool invocations.

## Step budget

| `--max-steps` | Default agent path |
|---|---|
| 1 | search only → fails before propose |
| 2 | search → propose |
| 3 | search → list_tree → propose |
| ≥4 | search → list_tree → read_file (first hit) → propose |

## CLI

```bash
forge agent run "intent" --capability propose --max-steps 4 --provider fake
forge agent resume <session_id> --workspace .
forge agent list --workspace . --json
```

`forge agent run --yes` applies the resulting proposal through the transaction
service after the approval gate passes.

## Safety rules

1. Max steps enforced before each tool invocation.
2. `run_task` uses `kernel.process` with fixed argv — no shell interpolation.
3. Every tool call is logged in the session JSON.
4. Cancellation token propagates to provider and child processes.

## Implementation

- `packages/ai/src/tools.zig` — capability matrix
- `packages/ai/src/tool_executor.zig` — tool implementations
- `packages/ai/src/agent.zig` — step loop + session persistence
- `packages/workspace/src/sessions.zig` — session store + index
- `apps/forge-cli/src/agent_cmd.zig` — CLI commands

## Exit criteria

- [x] Tool registry + capability profiles
- [x] `forge agent run` multi-step loop
- [x] Session persistence + resume
- [x] `--yes` apply gate (no silent apply)
- [x] SIGINT → cancel (macOS/Linux via `cancel_scope`)
- [ ] IDE Agents window wiring (Phase 4)
