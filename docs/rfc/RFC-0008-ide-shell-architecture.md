# RFC-0008: IDE Shell Architecture

- Status: Accepted
- Date: 2026-07-04
- Owners: Forge maintainers

## Summary

Forge IDE is a **native workbench**, not a VS Code/Electron clone. UI threads
dispatch **commands** (intent); kernel and workspace emit **events** (facts).
Extensions load through a **capability host** with a Forge-native manifest —
not VS Code `package.json` compatibility.

## Context

The initial `forge-ide` spike copied Cursor/VS Code layout (agent-left, mock
explorer, monolithic `main.zig`). That code is useful for renderer integration
but is the wrong long-term shape:

- File explorer was a flat mock list with no mutations.
- No command palette or kernel command bridge.
- No extension discovery, activation, or contribution model.
- AI and filesystem work risked blocking the render thread.

Forge's invariant: **only `workspace/transaction` mutates the filesystem** for
AI proposals; the IDE shell may use `workspace/atomic` for direct user edits
(open/save/create/delete initiated by explicit user commands).

## Decision

### Layering

```text
┌─────────────────────────────────────────────────────────────┐
│  renderer (main thread) — input, layout, draw               │
└───────────────────────────┬─────────────────────────────────┘
                            │ WorkbenchCommand ↑
                            │ WorkbenchEvent   ↓
┌───────────────────────────▼─────────────────────────────────┐
│  workbench — tabs, explorer state, panel layout, palette    │
└───────────────────────────┬─────────────────────────────────┘
                            │
         ┌──────────────────┼──────────────────┐
         ▼                  ▼                  ▼
   forge-editor      forge-workspace     extension Host
   (buffer)          (atomic I/O)        (manifest + activate)
         │                  │                  │
         └──────────────────┴──────────────────┘
                            │
                     forge-kernel
              (Dispatcher, EventBus, tasks)
```

### Command / event split

| Kind | Examples | Thread |
|------|----------|--------|
| **Command** (intent) | `open_file`, `save_active`, `explorer_create_file`, `run_extension_command` | Posted from UI; executed on workbench or worker |
| **Event** (fact) | `file_opened`, `file_saved`, `explorer_refreshed`, `extension_activated` | Published after success; UI subscribes |

Commands never mutate hidden global state. The workbench owns all IDE state.

### Explorer

- **Tree model** built from `workspace/tree.scan`, not a flat file list.
- **Expand/collapse** is UI state only (does not touch disk).
- **User mutations** (`create_file`, `create_folder`, `delete`, `rename`) go
  through `explorer/ops.zig` → `workspace/atomic` → `explorer_refreshed` event.
- Selection drives create/rename targets.

### Extensions (M4 host, M7 WASM)

Forge extensions are **not** VS Code extensions.

Discovery paths (in order):

1. `<workspace>/extensions/*/forge.toml`
2. `<workspace>/.forge/extensions/*/forge.toml`
3. Built-in extensions compiled into `forge-ide`

Manifest (`forge.toml`):

```toml
[extension]
id = "forge.samples.hello"
name = "Hello Sample"
version = "0.1.0"
api_version = 1

[[commands]]
id = "hello.say"
title = "Say Hello"
```

Host lifecycle:

1. **Discover** — parse manifests, validate `api_version`
2. **Activate** — call `activate(ctx)` (builtin Zig or future WASM)
3. **Contribute** — register commands, views, keybindings into workbench registry
4. **Deactivate** — reverse order on shutdown

Extensions **must not** write files directly. They dispatch workbench commands
or return `WorkspaceEdit` proposals (same as AI/LSP).

### Render thread rules

- No blocking I/O, LSP, model calls, or subprocess on the render thread.
- Heavy work uses `kernel/task` workers; results arrive as events.
- Frame budget per RFC-0004.

## Consequences

- IDE code splits into `workbench/`, `explorer/`, `extension/`, `ui/`.
- VS Code extension marketplace is explicitly out of scope for M4–M6.
- Extension authors target Forge manifest + capability API.

## Validation

- Unit tests: explorer tree build, manifest parse, command dispatch.
- Integration: create file in explorer → appears in tree → open in tab → save.
- Extension sample activates and registers a command visible to command palette.
