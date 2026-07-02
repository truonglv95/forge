# Forge Delivery Roadmap

> Canonical roadmap — last updated: 2026-07-02

This roadmap is the source of truth for Forge's development order and status.
The [Project Vision](../PROJECT_VISION.md) explains the product and architecture;
this document answers **what comes next and when a milestone is considered
complete**.

## Status legend

- `[x]` completed and verified;
- `[ ]` not completed;
- only one milestone may be `In progress` at a time;
- do not begin the next milestone until the current milestone's required exit
  criteria are met, except for explicitly identified risk-reduction spikes.

## Overview

| Milestone | Deliverable | Status |
|---|---|---|
| M0 | Reproducible Zig monorepo + architecture decisions | **In progress** |
| M1 | Kernel + headless workspace CLI | Not started |
| M2 | Native editor vertical slice | Not started |
| M3 | Zig language intelligence + task feedback | Not started |
| M4 | Safe AI editing MVP | Not started |
| M5 | Dogfoodable alpha | Not started |
| M6 | Beta foundation + extensibility decision | Not started |

## M0 — Foundation and decisions

**Outcome:** a clean clone can build and test successfully; package structure
and foundational decisions no longer rely on placeholders.

### Current baseline

- [x] Create the `apps/`, `packages/`, and `docs/` skeleton.
- [x] Pin the minimum Zig version to `0.16.0` in `build.zig.zon`.
- [x] Write the project vision and canonical roadmap.
- [x] Write a README that accurately reflects the pre-alpha status.
- [x] Replace the Zig starter code in `src/`.
- [x] Connect `apps/forge-cli` and every package to the build graph.
- [x] Replace `hello` placeholders with minimal package APIs and tests.
- [x] Define a minimal schema and parser for `forge.toml`.
- [x] Make the bootstrap script idempotent and prevent it from overwriting
  existing source files.
- [x] Add CI for formatting checks, build, tests, and CLI smoke checks.

### Required RFCs and spikes

- [x] RFC-0001: project structure and dependency rules.
- [x] RFC-0002: allocator ownership, error boundaries, and resource lifecycle.
- [x] RFC-0003: `Command`, `Event`, `WorkspaceEdit`, and transaction semantics.
- [ ] Renderer spike: window, GPU surface, and text shaping on macOS.
- [ ] RFC: MVP platform and renderer stack based on spike results.

### Exit criteria

- [x] `zig build` and `zig build test` pass locally.
- [x] `zig build run -- version` runs the real CLI from `apps/forge-cli`.
- [x] Every package has a test step and follows the dependency direction.
- [ ] CI is green on the MVP platform.
- [x] No Zig starter code or `hello` placeholders remain.
- [ ] The renderer decision is supported by a prototype and measurements, not
  preference alone.

## M1 — Kernel and headless workspace

**Outcome:** the CLI opens, searches, and observes a real workspace using the
same primitives the IDE will use.

### Scope

- [ ] Typed service registry and deterministic lifecycle.
- [ ] Command dispatcher with typed results and errors.
- [ ] Typed events, subscription ownership, and unsubscribe support.
- [ ] Task scheduling, cancellation, and structured logging.
- [ ] Configuration loading, merging, and validation.
- [ ] Canonical paths and atomic file reads/writes.
- [ ] Ignore rules, file tree, and filename/text search.
- [ ] Cross-platform file watcher abstraction.

### Demo

```bash
forge inspect <path>
```

The command must display a file tree, run searches, and stream file events.

### Exit criteria

- [ ] Lifecycle, event ordering, and cancellation have unit tests.
- [ ] Atomic file transactions and stale-write protection have tests.
- [ ] The watcher does not loop on files written by Forge.
- [ ] Permission errors, symlinks, and deleted files have documented behavior.

## M2 — Native editor vertical slice

**Outcome:** the desktop application can open, edit, undo/redo, and save a real
Zig file.

### Scope

- [ ] Native window/event loop and GPU surface.
- [ ] Font discovery, shaping, glyph atlas, and text layout.
- [ ] Benchmark ropes and piece tables; record the decision.
- [ ] Buffer, cursor, selection, and edit history.
- [ ] Viewport, scrolling, hit testing, keyboard input, and IME support.
- [ ] Minimal file tree, command palette, and default theme.
- [ ] Dirty state, atomic save, and external-change conflict UI.

### Exit criteria

- [ ] Unicode, newline variants, and large files pass the test corpus.
- [ ] Undo/redo passes property tests.
- [ ] Save never silently overwrites an external edit.
- [ ] Baselines exist for cold/warm startup, idle memory, and frame time.

## M3 — Language intelligence and task feedback

**Outcome:** Forge is capable of completing a small Zig change.

### Scope

- [ ] Incremental parsing and syntax highlighting.
- [ ] LSP JSON-RPC transport, lifecycle, and cancellation.
- [ ] Diagnostics, hover, definition, and completion.
- [ ] References, rename, and code actions.
- [ ] Task runner for format/build/test with streaming output.
- [ ] Problems panel and source navigation.

### Exit criteria

- [ ] LSP crashes and restarts do not corrupt editor state.
- [ ] Stale LSP responses are discarded.
- [ ] Rename is previewed as a multi-file `WorkspaceEdit`.
- [ ] Tasks can be canceled and never block the render thread.

## M4 — Safe AI editing MVP

**Outcome:** AI completes a small change from prompt to verified diff without
having direct write access to the workspace.

### Scope

- [ ] Provider-neutral model interface and OS secret storage.
- [ ] Context builder with token budgets, file selection, and redaction.
- [ ] Streaming prompt/plan UI.
- [ ] Convert structured proposals into multi-file `WorkspaceEdit` values.
- [ ] Diff preview, approve/reject, and atomic apply.
- [ ] Format/build/test feedback loop.
- [ ] Transaction-level undo and local metrics.

### Exit criteria

- [ ] The model layer has no filesystem write API.
- [ ] Secrets and excluded files are absent from context by default.
- [ ] Stale proposals are rejected or safely rebased and verified.
- [ ] Multi-file edits apply and undo atomically.
- [ ] Provider or tool failures never lose user edits.

## M5 — Daily-use alpha

**Outcome:** the development team can dogfood Forge daily for a defined
workflow.

### Scope

- [ ] Tabs/splits, recent workspaces, and session restore.
- [ ] Minimal PTY terminal or a task console sufficient for the MVP workflow.
- [ ] Settings, keybindings, and an accessibility baseline.
- [ ] Recovery journal, safe mode, and opt-in crash reporting.
- [ ] Packaging, signing, updates, and rollback on the MVP platform.
- [ ] Performance and correctness hardening based on dogfood data.

### Exit criteria

- [ ] The alpha can be installed and rolled back.
- [ ] Crash/recovery tests lose no data.
- [ ] One Forge change is completed end to end using only Forge.
- [ ] The support matrix and known limitations are published.

## M6 — Beta and extensibility decision

**Outcome:** stabilize proven APIs and decide whether to invest in plugins and
additional platforms.

### Scope

- [ ] Stabilize command/event/workspace APIs based on dogfood evidence.
- [ ] Threat model and capability model for extensions.
- [ ] WASM plugin spike covering limits, permissions, and manifest versioning.
- [ ] Multi-platform spike based on the renderer abstraction.
- [ ] Compatibility tests, migration policy, and beta quality gates.

### Exit criteria

- [ ] Public boundaries have versioning and compatibility policies.
- [ ] The plugin decision is based on spike results and demonstrated demand.
- [ ] A second platform does not require breaking the editor/kernel boundary.
- [ ] The beta release meets published quality gates.

## Deferred until after M6

- extension marketplace;
- cloud sync and team collaboration;
- autonomous coding agent;
- remote development;
- full debugger/notebook platform;
- Forge Cloud, Enterprise, and a custom language.

These items require separate roadmaps and RFCs and must not enter the MVP's
critical path.

## Cross-cutting gates

Every milestone must maintain:

- `zig fmt --check`, builds, and tests in CI;
- allocator and leak checks where appropriate;
- no filesystem, LSP, or model calls blocking the render thread;
- structured errors at subsystem boundaries;
- benchmarks compared against a reference corpus and machine;
- RFCs for decisions that are difficult to reverse;
- documentation and roadmap updates whenever scope changes.

## Next five actions

1. Build the macOS renderer spike and record startup/frame baselines.
2. Select the MVP renderer stack in an RFC based on measured results.
3. Implement canonical workspace-relative path validation.
4. Implement atomic file primitives and stale-write protection.
5. Add failure-injection tests for transaction rollback before M1.
