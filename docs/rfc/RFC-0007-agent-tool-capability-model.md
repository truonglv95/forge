# RFC-0007: Agent Tool Capability Model

**Status:** Accepted  
**Date:** 2026-07-04

## Summary

Agent sessions invoke **tools** through a capability-scoped registry. Tools may
read workspace state or edit files. By default edits are review-gated; when the
user explicitly trusts tools, edit tools apply immediately through the
transaction service rather than bypassing workspace safety.

## Capability profiles

| Profile | Allowed tools |
|---|---|
| `read_only` | `read_file`, `search`, `list_tree`, `show_context` |
| `propose` | read tools + `propose_edit` |
| `propose_and_task` | propose tools + `run_task` (never `apply_proposal`) |

`apply_proposal` and `undo` require a separate human or CLI approval gate
(`--yes`, IDE button). Agent edit tools can auto-apply only after an explicit
trust grant (`/tools trust-all`, `--trust-all`, or equivalent UI policy), and
still use transaction history, stale-write checks, checkpoints, and undo.

Mode mapping is fixed: Ask and Plan use `read_only`; Agent uses
`propose_and_task`. Tool declarations are filtered before being sent to the
provider and checked again during dispatch. MCP tools are Agent-only, high-risk,
and require approval on every call.

## Tool surface (v1)

```text
search(query)        → bounded path + line + source snippet observations
list_tree(path,depth)→ bounded workspace paths under a subtree
read_file(path,range)→ numbered source content + snapshot hash
run_task(name)       → zig build test|build|fmt (argv array, no shell)
propose_edit()       → planner → reviewable proposal JSON on disk
```

Native tools also expose policy metadata (`low|medium|high` risk and
`automatic|review|every_time` approval). Capability profiles control access;
policy metadata controls the approval UX for an allowed call.

## Session schema (v3)

```json
{
  "schema_version": 3,
  "session_id": "sess_1783113260319",
  "intent": "search sample",
  "capability_profile": "propose",
  "max_steps": 8,
  "run_ids": ["run_1783113260320"],
  "proposal_path": ".forge/proposals/run_1783113260320.json",
  "execution_state": "proposal_ready",
  "next_step_index": 3,
  "pending_tool": "",
  "pending_tool_args": "",
  "conversation_json": "provider-native serialized turns",
  "provider_kind": "gemini",
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
service after the approval gate passes. `forge agent run --trust-all` trusts all
tools for the current session; edit tools directly apply via transactions and
therefore may return no proposal path.

## Safety rules

1. Max steps enforced before each tool invocation.
2. `run_task` uses `kernel.process` with fixed argv — no shell interpolation.
3. Every tool call is logged in the session JSON.
4. Cancellation token propagates to provider and child processes.
5. IDE model callbacks cannot mutate editor buffers; edits cross the same
   proposal/review/transaction boundary as CLI changes.
6. Proposal validation runs after apply and persists a `validation_failed`
   state when an allowlisted check fails.
7. Resume restores the persisted capability at least privilege and rejects an
   explicitly different provider transport.
8. IDE tools marked `every_time` pause before execution and expose tool name,
   arguments, and risk with explicit Approve once / Reject controls. Cancel
   rejects and wakes a waiting worker.

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
- [x] `--yes` apply gate for proposal mode
- [x] Explicit trust mode for direct transaction-backed agent edits
- [x] SIGINT → cancel (macOS/Linux via `cancel_scope`)
- [x] IDE Agents window wiring
- [x] Structured read/search/tree observations
- [x] Transaction-only IDE apply path and post-apply validation
- [x] Exact provider-turn checkpoint/resume (conversation + pending tool args)
- [x] IDE per-tool risk approval gate
