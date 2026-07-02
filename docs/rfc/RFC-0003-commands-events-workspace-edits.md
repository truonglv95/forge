# RFC-0003: Commands, Events, and Workspace Edit Transactions

- Status: Accepted
- Date: 2026-07-02
- Owners: Forge maintainers

## Summary

Forge represents mutation intent as commands, completed facts as typed events,
and code changes as validated `WorkspaceEdit` transactions. AI and LSP may
propose changes but cannot apply them directly.

## Context

Forge needs one safe path for user, AI, and language-tooling changes. If each
subsystem mutates editor buffers or files independently, review, undo, stale-file
protection, and auditing become inconsistent.

## Decision

### Commands

- A command is an explicit request to mutate state.
- Dispatch is synchronous at the command boundary and returns a typed result or
  error. Long-running work may return a task handle in M1.
- Successful commands receive monotonic `CommandId` values for diagnostics and
  future history correlation.
- Failed commands do not consume an ID and must not publish success events.
- A command handler owns mutation validation; subscribers cannot veto an already
  completed command through an event.

### Events

- An event describes a fact that has already occurred.
- Event types are known at compile time; untyped string topic names are not part
  of the kernel API.
- Subscribers receive borrowed payloads and cannot retain references unless
  ownership is explicitly transferred.
- Subscription lifetime is explicit through a token and `unsubscribe`.
- Event delivery order follows subscription snapshot order. Cross-event ordering
  is not guaranteed across future asynchronous executors.

### Workspace edits

A `WorkspaceEdit` is a non-owning proposal containing one or more `FileEdit`
values. Each file operation is one of:

- `create`: the path must not exist and has no expected hash;
- `modify`: the current content must match `expected_hash`;
- `delete`: the current content must match `expected_hash` and has no text edits.

All paths are workspace-relative. Absolute and duplicate paths are invalid. Text
edits use byte offsets against the exact content identified by the expected hash
and must be ordered without overlap.

### Transaction pipeline

```text
Producer -> Validate shape -> Load current versions -> Check preconditions
         -> Preview diff -> User approval -> Apply atomically
         -> Format/build/test -> Record result -> Undo if requested
```

M0 implements structural validation only. Filesystem precondition checks,
preview, atomic application, history, and rollback belong to M1/M2 and must pass
failure-injection tests before AI editing begins.

### Authority boundaries

- AI and LSP may construct proposals.
- The editor may display and preview proposals.
- Only the workspace transaction service may mutate files.
- The application layer obtains user approval and orchestrates validation tools.
- Model-provider code must never receive a filesystem write capability.

## Required invariants

- No transaction is empty.
- No path is empty, absolute, or repeated.
- Modify and delete operations carry stale-write preconditions.
- Create operations cannot masquerade as modifications.
- Text edit ranges are valid, ordered, and non-overlapping.
- Multi-file apply and undo are all-or-nothing.
- Validation failure performs no mutation and emits no success event.

## Consequences

All mutation producers share one review and safety pipeline. This adds conversion
work for LSP edits and AI proposals, but prevents those systems from bypassing
data-safety guarantees.

## Validation

- Kernel unit tests cover command success/failure IDs and event unsubscribe.
- Workspace unit tests reject missing hashes, duplicate paths, invalid ranges,
  and overlapping edits.
- M1 adds temporary-directory tests for stale files, partial write failure,
  rollback, and recovery.
