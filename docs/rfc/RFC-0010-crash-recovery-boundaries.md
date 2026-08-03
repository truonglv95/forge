# RFC-0010: Crash Recovery Boundaries

**Status:** Accepted  
**Date:** 2026-07-06

## Recoverable boundaries

### Agent tool turns

Before tool execution, Forge persists the provider-native conversation, tool
name, arguments, and next step index. If the process stops after the model tool
call but before its result, resume executes that pending call once, appends the
result to the existing conversation, and continues the same session.

### Workspace transactions

Before mutating files, Forge persists an active transaction marker and a backup
manifest. Each manifest entry records the path and whether it existed before
the transaction:

- existing files are restored from their backup;
- files created by the interrupted transaction are deleted;
- deleted files are recreated from their backup.

A normal apply error rolls back immediately, restores state to `approved`, and
clears the marker. Only process termination leaves the marker for startup
recovery.

## Tests

- Resume from a synthetic crash checkpoint between tool call and tool result.
- Recover a mixed modify/create/delete transaction from its active marker.
- Assert a normal multi-file apply failure restores prior content and leaves no
  active recovery marker.
