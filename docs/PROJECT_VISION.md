# Forge

> **AI-first native IDE, built in Zig.**

## 1. Product vision

Forge is not intended to be a lighter clone of VS Code. Forge is a native
development environment where AI participates throughout the software change
lifecycle: understanding the codebase, planning changes, producing edits,
running validation tools, and presenting the result for the developer to decide.

Every AI-generated change must:

- have a clear scope;
- be previewable and reviewable;
- be verifiable with formatters, compilers, and tests;
- be accepted or rejected atomically;
- be undoable and auditable.

The near-term goal is not to build an entire ecosystem. It is to prove one
valuable **vertical slice**: open a project, edit code in a native editor, ask AI
to produce a change, review the diff, run validation, and safely apply or undo
the result.

## 2. Product boundaries

### Forge will be

- a native desktop application, initially focused on macOS;
- an editor capable enough for Forge to be developed using Forge itself;
- a platform with a small kernel and clearly bounded subsystems;
- a controlled AI workflow that never overwrites the workspace without review.

### Forge is not yet

- a fully featured competitor to VS Code or JetBrains IDEs;
- a cloud platform, marketplace, or enterprise suite;
- a VS Code-compatible extension ecosystem;
- an autonomous agent allowed to change projects without review.

Forge Cloud, SDK, Marketplace, Enterprise, and Forge Language are long-term
possibilities. They enter the roadmap only after the IDE demonstrates
product-market fit.

## 3. Engineering principles

### Native first

The core and desktop application are written in Zig, without Electron or Node.js
as the IDE runtime. C and C++ libraries may be used when they substantially
reduce technical risk—for example in font shaping, parsing, or GPU
abstraction—but they must sit behind interfaces owned by Forge.

### Small kernel, explicit boundaries

The kernel owns shared primitives:

- lifecycle and service ownership;
- typed event bus;
- command dispatch and history;
- task scheduling and cancellation;
- configuration and diagnostics.

The kernel contains no editor, LSP, AI, or renderer business logic. Packages
depend in one direction and must not create dependency cycles.

```text
apps
  -> feature packages (ai, editor, lsp, renderer, workspace)
      -> kernel/core
          -> util
```

### Commands for mutations, events for facts

- A **command** expresses an intent to mutate state and returns success or
  failure.
- An **event** announces that something has already happened; subscribers do not
  determine whether the originating operation is valid.
- Direct interface calls are appropriate for queries and synchronous flows that
  require a result. Not all communication is forced through the event bus.

This rule prevents opaque event chains while keeping mutations auditable.

### AI proposes transactions

AI never mutates the editor buffer or filesystem directly. It proposes a
`WorkspaceEdit` containing preconditions, a set of file changes, and metadata.
The system then follows this flow:

```text
Prompt -> Context -> Model -> Proposed WorkspaceEdit
       -> Preview diff -> Validate -> User approval -> Apply transaction
       -> Format/build/test -> Result -> Undo if needed
```

Before applying an edit, Forge checks each file's version or hash so it cannot
overwrite newer user changes. Operations such as symbol rename may originate in
the LSP subsystem but still pass through the same transaction pipeline.

### Measure before optimizing

Startup, memory, and latency goals require reproducible benchmarks. Forge does
not trade correctness or debuggability for unmeasured optimization.

## 4. Target architecture

```text
                         Forge IDE
                            |
                     Application Shell
                 /          |           \
            Editor UI    Panels/UI    Command UI
                 \          |           /
                     Forge Kernel
          /          /          \             \
     Workspace    Editor       Tooling          AI
     files/watch   buffer       LSP/tasks    context/model
          \          \          /             /
                   WorkspaceEdit
                         |
                 Validation + History
                         |
                      Filesystem
```

Planned package boundaries:

| Package | Responsibilities | Non-responsibilities |
|---|---|---|
| `util` | Domain-independent data structures and helpers | Service lifecycle |
| `core` | Shared domain types, errors/results, and IDs | Orchestration |
| `kernel` | Lifecycle, commands, events, tasks, and config | Editor and AI logic |
| `workspace` | Paths, file I/O, watcher, search, and file transactions | Text rendering |
| `editor` | Buffer, cursor, selection, and edit history | Filesystem and AI |
| `renderer` | Window, GPU, text layout, input, and view composition | Document semantics |
| `lsp` | Process transport, protocol, and capabilities | Editor mutation |
| `ai` | Context, provider abstraction, and proposal generation | Directly applying edits |
| `plugin` | Capability API and sandbox after MVP | Core feature delivery |

## 5. Current repository baseline — 2026-07-02

The repository is in the **foundation** stage and has not completed M0:

- the `apps/`, `packages/`, and `docs/` layout is connected through a Zig 0.16.0
  build graph;
- every package has a minimal owned contract and unit tests;
- `apps/forge-cli` is the installed executable and exposes foundation commands;
- `forge.toml` has a strict M0 schema and parser;
- RFC-0001 defines package ownership and dependency direction;
- CI checks formatting, build, tests, and CLI smoke commands;
- allocator ownership and transaction semantics are now specified by RFC-0002
  and RFC-0003;
- the renderer stack still needs a measured spike before M0 is complete.

Every milestone below starts from this baseline. The current directory structure
must not be treated as a validated architecture.

## 6. Delivery roadmap

> Official status, checklists, and exit criteria are tracked in the
> [Forge Delivery Roadmap](roadmap/ROADMAP.md). The sections below describe the
> direction of each milestone. If status differs, the roadmap is authoritative.

The roadmap uses exit criteria instead of speculative deadlines. Work proceeds
to the next milestone only after the current milestone's required criteria are
met.

### M0 — Foundation and decisions

**Outcome:** a monorepo that builds and tests, supported by enough documented
decisions to begin development without guessing at the architecture.

- replace the starter `src/` executable with `apps/forge-cli`;
- declare every package in `build.zig` and add a test step for each one;
- complete the README, bootstrap script, and minimal `forge.toml` schema;
- add CI for `zig fmt --check`, build, and tests;
- write RFCs for the dependency graph, error and allocator ownership, and
  platform strategy;
- select the MVP platform and build a window/GPU/text stack spike.

**Exit criteria**

- a clean clone can bootstrap and run `zig build test`;
- `zig build run -- version` runs the real Forge CLI;
- CI is green on the MVP platform;
- no starter code or package `hello` placeholders remain;
- an RFC documents the renderer stack decision with a measured prototype.

### M1 — Kernel and headless workspace

**Outcome:** the CLI opens and observes a real workspace using the same
primitives the IDE will reuse.

- typed service registry and deterministic lifecycle;
- command dispatcher with explicit results and errors;
- typed event subscription, unsubscription, and ownership;
- task cancellation and structured logging;
- configuration loading, merging, and validation;
- canonical paths, atomic file reads/writes, ignore rules, and file watcher;
- basic filename and text search.

**Demo:** `forge inspect <path>` displays the file tree, searches content, and
streams file events as the project changes.

**Exit criteria**

- lifecycle, event ordering, cancellation, and file transactions have unit
  tests;
- the watcher does not loop on files written by Forge;
- Forge can inspect its own repository and deliberately handles permissions and
  symlinks.

### M2 — Native editor vertical slice

**Outcome:** the desktop application can open, edit, and save a real source file.

- window/event loop and GPU surface on the MVP platform;
- font discovery, shaping, glyph atlas, and text layout;
- editor buffer, choosing between a rope and piece table after benchmarks;
- cursor, selection, viewport, scrolling, hit testing, and input methods;
- open/save, dirty state, undo/redo, and external-change conflicts;
- minimal file tree, command palette, and default theme.

**Demo:** open the Forge repository, edit a Zig file, undo/redo, save it, and
reopen it without content corruption.

**Exit criteria**

- Unicode, newline variants, and large files work against a test corpus;
- undo/redo passes property tests without corrupting the buffer;
- saves are atomic and never silently overwrite external edits;
- startup, idle memory, and frame-time benchmark baselines exist.

### M3 — Language intelligence and task feedback

**Outcome:** Forge is useful enough to develop a small Zig change.

- syntax highlighting and incremental parsing;
- LSP JSON-RPC transport, lifecycle, and cancellation;
- diagnostics, hover, definition, completion, references, and rename;
- task runner for format/build/test with streaming output;
- problems panel and navigation from diagnostics to source.

**Demo:** edit a Zig package, receive diagnostics, rename a symbol, run the
formatter, and execute `zig build test` inside Forge.

**Exit criteria**

- LSP crashes and restarts do not corrupt editor state;
- stale LSP responses are discarded;
- rename is previewed as a multi-file `WorkspaceEdit`;
- tasks can be canceled and output never blocks the UI thread.

### M4 — Safe AI editing MVP

**Outcome:** AI completes a small controlled change from prompt to verified diff.

- provider-neutral model interface and OS secret storage;
- context builder with budgets, file selection, and redaction rules;
- streaming chat and plan UI;
- parser for structured proposals and multi-file `WorkspaceEdit` values;
- diff preview, per-file selection, approve/reject, and atomic apply;
- post-apply format/build/test loop;
- local telemetry for latency, token use, and apply success, with opt-in required
  before transmitting any data.

**Demo:** ask AI to add a small Forge feature, review the diff, apply it, run
tests, and undo the entire transaction.

**Exit criteria**

- the model has no direct file-write API;
- stale proposals are rejected or safely rebased;
- secrets and excluded files are absent from context by default;
- the entire multi-file transaction can be undone;
- provider, build, or test failures are visible and never lose user edits.

### M5 — Daily-use alpha

**Outcome:** the development team can dogfood Forge daily within a defined scope.

- tabs/splits, recent workspaces, and session restore;
- a minimal PTY terminal or a task console sufficient for the MVP workflow;
- settings, keybindings, and a basic accessibility pass;
- opt-in crash reporting, recovery journal, and safe mode;
- packaging, signing, and an update channel for the MVP platform;
- performance and correctness hardening based on dogfood data.

**Exit criteria**

- an installable alpha is released with rollback support;
- crash/recovery tests lose no data;
- the team completes at least one end-to-end change using only Forge;
- known limitations and the support matrix are published.

### M6 — Beta and extensibility decision

**Outcome:** prove Forge can expand without prematurely locking in its
architecture.

- stabilize public command, event, and workspace APIs proven through dogfooding;
- define a threat model and capability model for extensions;
- spike a WASM runtime, resource limits, and versioned plugin manifest;
- spike an additional platform using the renderer abstraction;
- establish beta quality gates, migration policy, and compatibility tests.

The plugin marketplace, cloud sync, and autonomous agent receive separate
roadmaps only after this milestone and only when supported by demonstrated need.

## 7. Cross-cutting quality gates

Every milestone must maintain:

- `zig fmt --check`, builds, and tests in CI;
- test allocator and leak checks where appropriate;
- no filesystem, LSP, or model calls blocking the render thread;
- structured errors with context at subsystem boundaries; errors are never
  silently swallowed;
- benchmarks stored and compared against their baselines;
- RFCs for decisions that are difficult to reverse;
- documentation updates whenever interfaces or scope change.

## 8. Priorities and non-goals

When tradeoffs are necessary, prioritize in this order:

1. Never lose or overwrite user data.
2. Correctness, observability, and debuggability.
3. One valuable end-to-end workflow.
4. Responsiveness and resource use.
5. Feature breadth and number of platforms.

Do not build before M5: real-time collaboration, a full debugger, notebooks,
remote development, a marketplace, a cloud backend, a custom programming
language, or enterprise administration.

## 9. Success metrics

Numerical targets will be set after the M0 spike. The roadmap initially defines
what to measure:

- cold and warm startup time on a reference machine;
- idle memory with a reference workspace;
- p50 and p95 input-to-frame latency;
- open and search time against a reference corpus;
- crash-free sessions and recovery success rate;
- percentage of AI proposals applied, validated successfully, and later undone;
- time from prompt to verified change;
- percentage of dogfood tasks completed without returning to another IDE.

## 10. Immediate next actions

1. Build and measure the macOS renderer spike.
2. Select the MVP renderer stack in an RFC using the spike results.
3. Implement workspace path normalization and atomic file primitives.
4. Add stale-write and rollback tests for `WorkspaceEdit` transactions.
5. Begin the M1 headless workspace only after the renderer decision closes M0.

## 11. Long-term direction

If the IDE reaches daily-use quality and the AI editing loop proves valuable,
Forge may expand into a CLI, Agent, SDK, plugin ecosystem, and team services.
This is a conditional direction, not an MVP commitment.

The north star remains unchanged: **AI and developers collaborate through
changes that can be understood, reviewed, verified, and undone.**
