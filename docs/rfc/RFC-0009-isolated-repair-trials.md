# RFC-0009: Isolated Repair Trials

**Status:** Accepted  
**Date:** 2026-07-06

## Decision

AI proposal repair runs in a disposable sibling snapshot of the current
workspace. The snapshot includes dirty source files, excludes `.git`, `.forge`,
build caches, and `node_modules`, and is deleted after validation.

The proposal is applied only to the snapshot. Allowlisted validation tasks run
with the snapshot as their working directory. A failed report may be returned
to the planner for at most two repair attempts; the final proposal still enters
the normal human review and transaction boundary.

## Safety boundary

Snapshot isolation protects the authoritative workspace from proposal edits and
removes the old apply-then-restore failure mode. It is not an OS/container
security boundary: a hostile project build script could access paths outside
its working directory. Validation commands remain allowlisted, but running an
untrusted repository requires a future container or remote sandbox backend.

## Limits

- 50,000 copied files.
- 512 MiB copied content.
- Symlinks and special files are not copied.
- Trial directories are unique per timestamp and worker thread and are removed
  on every normal/error return.

## Verification

The deterministic repair test applies a create operation and validation inside
the snapshot, then verifies that the authoritative workspace is unchanged and
the trial-only file does not exist there.
