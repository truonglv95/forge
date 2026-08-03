# Forge project instructions

Use these rules when proposing workspace edits in this repository.

---

## Core rules

- Prefer minimal, focused diffs that match existing Zig conventions.
- Never commit secrets, API keys, or credentials.
- AI proposals must go through review before apply (`apply_mode = "review"` in `forge.toml`).
- Run `zig build test` after substantive code changes.
- Keep package boundaries: workspace mutations flow through `workspace/transaction`.
- When editing IDE code, preserve the command/event split documented in RFC-0008.

---

## Repository layout

```
forge/
├── apps/
│   ├── forge-cli/src/       # CLI commands (main.zig, agent_cmd.zig, apply.zig, ...)
│   ├── forge-ide/           # Native macOS IDE (renderer, workbench, panels)
│   └── forge-agent/         # Reserved — post-MVP standalone agent entrypoint
├── packages/
│   ├── util/                # Domain-independent helpers, no service lifecycle
│   ├── core/                # Shared domain types: IDs, errors, Subsystem enum
│   ├── kernel/              # Lifecycle, command dispatcher, event bus, tasks, config
│   ├── workspace/           # File I/O, transactions, search, watcher, snapshots
│   ├── editor/              # Buffer, cursor, selection, undo history
│   ├── renderer/            # Window, GPU, text layout, input (IDE only)
│   ├── lsp/                 # LSP JSON-RPC client (never mutates files directly)
│   ├── ai/                  # Context, providers, agent, proposals, MCP
│   └── plugin/              # Post-MVP extension sandbox (WASM)
├── docs/
│   ├── rfc/                 # Architectural decisions (RFC-0001 … RFC-0012)
│   ├── roadmap/ROADMAP.md   # Canonical milestone plan with exit criteria
│   ├── evaluation/          # AI evaluation docs and measurement guides
│   └── AI_MODE_TOOL_MATRIX.md
└── .forge/                  # Per-workspace Forge state (evals, parsers, settings)
```

**Dependency direction (strictly enforced):**
```
apps → feature packages (ai, editor, lsp, renderer, workspace)
     → kernel / core
     → util
```
Cycles are forbidden. Never add a dependency that reverses this direction.

---

## AI package map (`packages/ai/src/`)

The `ai` package is the most active. Key modules:

| File | Role |
|---|---|
| `agent.zig` | Main entry point: `Config`, `run()`. Orchestrates all sub-phases. |
| `agent/loop.zig` | Step loop, compaction, `ApprovalCallback` interface |
| `agent/context_phase.zig` | Context assembly before each model call |
| `agent/tool_phase.zig` | Tool call dispatch and response handling |
| `proposal_workflow.zig` | Ask/Plan flow: `GenerateOptions`, `Result`, repair loop |
| `tool_executor.zig` | Executes native tools (search, read_file, replace_file_content, ...) |
| `tools/registry.zig` | `policyFor()` — Risk/Approval policy per tool wire name |
| `tools.zig` | `CapabilityProfile` enum: `read_only`, `propose`, `propose_and_task` |
| `context_loader.zig` | Builds context from files, codebase index, git diff, diagnostics |
| `context_budget.zig` | Token/byte budget enforcement and per-item cost tracking |
| `context_rerank.zig` | Reranks retrieved chunks before final context packing |
| `codebase_search.zig` | Semantic + keyword search, embedding integration |
| `provider.zig` | Provider-neutral streaming interface |
| `providers/` | gemini, ollama, openai, openrouter, nvidia, fake |
| `mcp_client.zig` | MCP protocol client |
| `mcp_registry.zig` | Registry of connected MCP servers and their tools |
| `routing.zig` | Intent-based routing (Ask/Plan/Agent mode selection) |
| `intent_classifier.zig` | Classifies prompt intent → capability profile |
| `repair_loop.zig` | Re-runs agent inside disposable snapshot on validation failure |
| `validation_runner.zig` | Runs format/build/test after proposal apply |
| `ecosystem.zig` | AI ecosystem manifest (tools, context sources, skill packs) |
| `run_record.zig` | Persists run inputs, steps, decisions, token usage |
| `secret_scanner.zig` | Detects common secret patterns before context is sent |

---

## Workspace package map (`packages/workspace/src/`)

| File | Role |
|---|---|
| `transaction.zig` | `TransactionService`, `TransactionState`, apply/undo/rollback |
| `edit.zig` | `WorkspaceEdit`, `FileEdit`, validation rules |
| `snapshot.zig` | `FileSnapshot` — versioned bytes + content hash |
| `path.zig` | `WorkspacePath` (no `..`, no absolute, no NUL), `WorkspaceRoot` |
| `history.zig` | Persisted transaction history, undo chain |
| `recovery.zig` | Write-ahead recovery record and restart recovery |
| `atomic.zig` | Atomic write primitives (tmp → rename) |
| `search.zig` | Literal text and filename search |
| `codebase_index.zig` | Semantic chunk index, embedding store, freshness checks |
| `transaction.zig` | `TransactionState`: proposed → validated → approved → applying → applied |

---

## Kernel patterns

### Commands (mutations)
```zig
// Commands express intent to change state; they return success or error.
const Dispatcher = kernel.command.Dispatcher(MyCmd, Result, Context, Error, execute);
var dispatcher = Dispatcher{ .context = &ctx };
const outcome = try dispatcher.dispatch(.{ .my_action = args });
// outcome.id: CommandId — monotonically assigned only on success
```

### Events (facts)
```zig
// Events announce facts that already happened; callbacks are pure observers.
var bus = kernel.event.EventBus(MyEvent).init(allocator);
defer bus.deinit();
const token = try bus.subscribe(&handler, Handler.receive);
try bus.publish(.{ .file_saved = path });
bus.unsubscribe(token); // Always unsubscribe before handler is freed
```

**Rule:** Use commands for mutations, events for facts. Never use an event to
decide whether an operation is valid — that is a command's job.

---

## Transaction pattern (AI edits)

AI **never** writes files. The mandatory flow:

```
Prompt
  → context_loader builds Context + budget
  → provider streams response
  → proposal_workflow parses WorkspaceEdit
  → TransactionService.validatePreconditions() — hash check prevents stale overwrite
  → User approves (CLI: --yes flag; IDE: diff UI)
  → TransactionService.apply() — atomic, all-or-nothing
  → validation_runner runs fmt/build/test
  → TransactionService.undo() available if needed
```

Key invariants:
- `TransactionState` must be `.approved` before `apply()` is called.
- Every `modify`/`delete` operation requires `expected_hash` — no hash = `StaleContent` error.
- `apply()` stores `FileBackup` before first mutation; `undo()` restores them.
- If interrupted mid-apply, `recovery.zig` restores state on next workspace open.

---

## Tool capability profiles

```zig
// tools.zig
pub const CapabilityProfile = enum {
    read_only,        // Ask mode: search, read_file, git_diff, list_tree
    propose,          // Plan mode: read_only + replace_file_content (review-gated)
    propose_and_task, // Agent mode: propose + run_command + MCP tools
};
```

Tool approval policy (`tools/registry.zig`):
```
read_file, search, list_tree  → risk: low,    approval: automatic
replace_file_content          → risk: high,   approval: review
run_command, run_task         → risk: high,   approval: every_time
fetch_url, remember           → risk: medium, approval: every_time
unknown MCP tool              → risk: high,   approval: every_time
```

---

## Zig conventions in this codebase

### Error handling
```zig
// Always propagate errors with try; never silently swallow.
const result = try some_operation();

// Use errdefer for cleanup on failure paths.
var list: std.ArrayList(u8) = .empty;
errdefer list.deinit(allocator);

// Error sets are additive with ||
pub const MyError = error{Foo, Bar} || OtherError;
```

### Allocator ownership
- Every function that allocates takes an `allocator: std.mem.Allocator` parameter.
- Caller owns the returned allocation; always provide `defer allocator.free(result)`.
- In tests, use `std.testing.allocator` (catches leaks automatically).
- Use `errdefer` to free on failure; `defer` to free on success.

### Structs and init
```zig
// Prefer .empty sentinel for ArrayList/HashMap init (Zig 0.16.0 idiom).
var list: std.ArrayList(T) = .empty;
defer list.deinit(allocator);

// Struct init pattern — pass allocator to methods, not stored by default.
pub fn init(allocator: std.mem.Allocator, io: std.Io, root: WorkspaceRoot) Service {
    return .{ .allocator = allocator, .io = io, .root = root };
}
```

### Tests
```zig
test "descriptive name in snake_case" {
    // Use std.testing.allocator for leak detection.
    const allocator = std.testing.allocator;
    // Use try std.testing.expect* variants; never use unreachable in tests.
    try std.testing.expectEqual(expected, actual);
    try std.testing.expectError(error.Foo, fallible_call());
}

// Keep every exported symbol in the package test graph:
test {
    std.testing.refAllDecls(@This());
}
```

### Module structure
- Each package has a `root.zig` that re-exports public API with `pub const`.
- Internal modules do not need to be `pub` in `root.zig`.
- Package name in `build.zig` uses `forge-` prefix: `forge-ai`, `forge-workspace`, etc.

---

## What AI must NOT do

1. **Never call** `atomic.writeFile()` or any filesystem write directly — all writes go through `TransactionService`.
2. **Never bypass** the `expected_hash` precondition on `modify`/`delete` operations.
3. **Never store** credentials, API keys, or secrets in `forge.toml` or any tracked file.
4. **Never block** the render thread — all I/O, LSP, model, and task calls are async.
5. **Never create** a dependency cycle in the package graph.
6. **Never add** a new package without updating `build.zig` and writing at least one unit test.
7. **Never interpret** prose model output as an implicit file operation — only structured `WorkspaceEdit` JSON is valid.

---

## Common pitfalls

- **Stale content error**: If `expected_hash` doesn't match the current file hash, the transaction is rejected. Re-read the file snapshot before proposing edits to the same file twice.
- **EventBus leak**: Always `unsubscribe(token)` before the subscriber is freed. Subscriptions are not reference-counted.
- **Render thread**: `forge-ide` components may not call workspace/LSP/AI directly from render callbacks. Use the task system.
- **WorkspacePath**: Never construct from user input without calling `WorkspacePath.parse()`. It enforces containment, no `..`, no absolute paths.
- **Transaction state machine**: Cannot call `apply()` on a `.proposed` record — must transition through `.validated` → `.approved` first.

---

## Running checks

```bash
# Format, build, and test (same as CI):
./scripts/check.sh

# Fast check (format + AST only, no compilation):
./scripts/check.sh --fast

# Build and test manually:
zig build
zig build test

# Test a specific package:
zig build test-ai
zig build test-workspace

# CLI smoke:
zig build run -- help
zig build run -- version
zig build run -- doctor

# AI evaluation (fake provider, deterministic):
./scripts/eval_reliability.sh --provider fake --min-success-rate 1.0

# AI evaluation (live Ollama):
./scripts/eval_reliability.sh --provider ollama --repeat 3
```

---

## RFC reference

| RFC | Topic |
|---|---|
| RFC-0001 | Package structure and dependency direction |
| RFC-0002 | Runtime ownership, allocator policy, error handling |
| RFC-0003 | Commands, events, and WorkspaceEdit authority |
| RFC-0004 | Renderer and platform strategy (macOS MVP) |
| RFC-0005 | Run and session records schema |
| RFC-0006 | Context budget and redaction rules |
| RFC-0007 | Agent tool capability model and approval tiers |
| RFC-0008 | IDE shell architecture (command/event split) |
| RFC-0009 | Isolated repair trials (disposable snapshot workspace) |
| RFC-0010 | Crash recovery boundaries |
| RFC-0011 | Language chunker registry |
| RFC-0012 | Project-aware parser resolution |

Read the relevant RFC before making architectural decisions.
