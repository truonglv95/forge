# RFC-0001: Project Structure and Dependency Direction

- Status: Accepted
- Date: 2026-07-02
- Owners: Forge maintainers

## Summary

Forge uses a Zig monorepo with applications under `apps/` and reusable
subsystems under `packages/`. Package dependencies flow toward small shared
foundations and must remain acyclic.

## Context

Forge must eventually support a native IDE, a headless CLI, and controlled AI
editing. These applications need to share workspace, command, and domain logic
without making the UI, renderer, LSP, or AI subsystems depend on one another's
implementations.

The initial repository contained the desired directories, but `build.zig` still
compiled the Zig starter sources in `src/`. Package boundaries were therefore
aspirational rather than enforced by the compiler.

## Decision

### Applications

- `apps/forge-cli` is the first executable and the M0/M1 delivery surface.
- `apps/forge-ide` will become the native desktop application in M2.
- `apps/forge-agent` is reserved for a post-MVP workflow and must not influence
  current interfaces.

Applications compose packages. Reusable domain logic must not live in an
application directory.

### Packages

| Package | Owns |
|---|---|
| `util` | Domain-independent helpers and data structures |
| `core` | Stable shared types, IDs, and errors |
| `kernel` | Lifecycle, commands, events, tasks, and configuration orchestration |
| `workspace` | Paths, file I/O, watcher, search, configuration, and transactions |
| `editor` | Buffer, cursor, selection, and edit history |
| `renderer` | Native window, GPU, text layout, input, and view composition |
| `lsp` | Language server transport, protocol, and capability mapping |
| `ai` | Context construction, providers, and edit proposals |
| `plugin` | Versioned capability boundary and sandbox, deferred until M6 |

### Dependency direction

```text
apps
  -> feature packages (workspace, editor, renderer, lsp, ai, plugin)
      -> kernel/core
          -> util
```

The exact allowed edges are:

- `util` depends only on the Zig standard library;
- `core` may depend on `util`;
- `kernel` may depend on `core` and `util`;
- feature packages may depend on `kernel`, `core`, and `util` when required;
- applications may depend on any package they compose;
- feature packages must not depend directly on other feature packages without a
  follow-up RFC.

The M0 build graph currently uses only the dependencies each package needs. The
compiler therefore catches undeclared imports and helps prevent accidental
cycles.

### Package roots and tests

- Every package exposes `packages/<name>/src/root.zig`.
- Public declarations form that package's explicit boundary.
- Unit tests live beside the code they validate.
- `zig build test` runs tests for every package and application root.
- Package roots must not contain placeholder behavior presented as a real API.

### Mutation ownership

This RFC reserves, but does not fully specify, the following rule:

- commands request mutations;
- events report facts that already occurred;
- AI and LSP propose `WorkspaceEdit` transactions;
- the workspace layer validates and applies filesystem transactions.

The concrete command, event, allocator, and transaction contracts require
separate RFCs before M1 implementation.

## Consequences

### Positive

- The CLI can deliver value before the native renderer is complete.
- The compiler enforces declared dependencies.
- Feature implementations remain replaceable behind package boundaries.
- AI has no architectural path to write files directly.

### Costs

- Shared types must be designed carefully to prevent `core` from becoming a
  dumping ground.
- Cross-feature behavior may require application-level orchestration.
- New dependency edges require deliberate review and sometimes an RFC.

## Rejected alternatives

### A single `src/` tree

Rejected because subsystem ownership and dependency direction would remain
implicit as the project grows.

### One package per application

Rejected because the CLI and IDE need to share kernel and workspace behavior
without copying code.

### Event bus for all communication

Rejected because queries and synchronous operations that require results become
difficult to trace and type. Direct interfaces remain valid for those cases.

### Plugin architecture during M0

Rejected because no stable internal capability boundary has been proven through
dogfooding. The package reserves the boundary without committing to a runtime.

## Validation

This decision is considered enforced when:

- `build.zig` declares every package explicitly;
- the starter `src/` executable is removed;
- `zig build test` runs every package test;
- CI checks formatting, build, tests, and CLI smoke commands.
