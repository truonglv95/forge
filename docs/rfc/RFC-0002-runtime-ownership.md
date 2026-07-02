# RFC-0002: Runtime Ownership, Errors, and Lifecycle

- Status: Accepted
- Date: 2026-07-02
- Owners: Forge maintainers

## Summary

Forge uses explicit allocator ownership, deterministic resource teardown,
structured error propagation, and state-machine lifecycles. Subsystems must make
ownership visible in their APIs and must not rely on hidden global state.

## Context

Forge will host long-lived services, short-lived commands, background tasks, and
foreign libraries. Without a consistent ownership model, allocator lifetimes,
callbacks, and shutdown ordering can produce leaks, use-after-free bugs, or lost
errors—especially during cancellation and recovery.

## Decision

### Allocators

- The application root owns the process allocator and long-lived arenas.
- A component that stores allocated memory receives an allocator during `init`
  and stores it until `deinit`.
- The component that allocates memory is responsible for freeing it unless the
  return type explicitly transfers ownership.
- Borrowed slices and pointers are valid only for the documented call or owner
  lifetime. Non-owning types must say so in their documentation.
- Public APIs must not allocate from an undocumented global allocator.
- Arena allocation is reserved for values that share a clear bulk lifetime. It
  is not the default for mutable long-lived services.

### Initialization and teardown

- Resource-owning types use `init`/`deinit` or an equivalent explicit pair.
- After successful initialization, the owner installs `defer`/`errdefer`
  immediately.
- `deinit` releases owned resources in reverse dependency order.
- Services follow explicit lifecycle transitions. Invalid transitions return an
  error instead of being silently accepted.
- Shutdown and cancellation are normal control flows, not crashes.

### Errors

- Recoverable failures use Zig error unions.
- Errors gain context at subsystem boundaries through structured diagnostics or
  logging; they are not silently swallowed.
- Libraries do not terminate the process. Only application roots choose exit
  codes.
- `catch unreachable` is permitted only where an invariant has been established
  locally and is covered by a test.
- Error sets should be specific at stable boundaries and inferred inside small
  implementation units.

### Callbacks and events

- The subscriber owns callback context and must keep it alive until unsubscribe
  or event bus teardown.
- The publisher owns event payload data for the duration of `publish` unless a
  payload explicitly transfers ownership.
- Event publication iterates over a subscription snapshot so callback execution
  cannot invalidate the current traversal.
- Event handlers should remain small and schedule expensive work rather than
  blocking the publisher.

### Threading

- Mutable objects are single-owner by default and are not thread-safe unless
  documented otherwise.
- Filesystem, LSP, model, and long-running task work must not block the render
  thread.
- Cancellation tokens and worker ownership will be specified before background
  task execution is added in M1.

## Consequences

This model makes lifetimes and shutdown behavior more verbose, but it allows
Forge to use Zig's allocator testing and deterministic teardown effectively.
Subsystem APIs cannot hide ambiguous ownership behind convenience functions.

## Validation

- Unit tests use `std.testing.allocator` for allocating components.
- `zig build test` must report no allocator leaks.
- Lifecycle tests cover valid and invalid transitions.
- Code review rejects undocumented ownership transfer and process termination in
  packages.
