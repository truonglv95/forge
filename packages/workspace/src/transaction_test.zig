//! Transaction safety verification tests.
//!
//! Verifies:
//!   - State machine guards (cannot apply unless in .approved state)
//!   - Stale hash detection blocks apply before any write
//!   - Path traversal escape is rejected by WorkspacePath.parse
//!   - Undo fails when record is not in .applied state

const std = @import("std");
const transaction = @import("transaction.zig");
const edit = @import("edit.zig");
const path_mod = @import("path.zig");

// ---------------------------------------------------------------------------

test "transaction: cannot apply when state is not approved" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = path_mod.WorkspaceRoot.init(tmp.dir, ".");
    var svc = transaction.TransactionService.init(allocator, io, root);

    // A single-file modify edit — state is .proposed, not .approved.
    var files_arr = [1]edit.FileEdit{.{
        .path = "dummy.txt",
        .operation = .modify,
        .expected_hash = 42,
        .edits = &.{},
    }};
    var record = transaction.TransactionRecord{
        .id = 99,
        .state = .proposed,
        .workspace_edit = .{ .files = &files_arr },
        .timestamp_ms = 0,
    };

    try std.testing.expectError(error.InvalidState, svc.apply(&record));
}

test "transaction: stale hash is rejected before any write" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Write a file.
    {
        var f = try tmp.dir.createFile(io, "data.txt", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "version A");
    }

    const root = path_mod.WorkspaceRoot.init(tmp.dir, ".");
    var svc = transaction.TransactionService.init(allocator, io, root);

    var files_arr = [1]edit.FileEdit{.{
        .path = "data.txt",
        .operation = .modify,
        .expected_hash = 0xDEADBEEF, // intentionally wrong
        .edits = &.{},
    }};

    var record = transaction.TransactionRecord{
        .id = 1,
        .state = .approved,
        .workspace_edit = .{ .files = &files_arr },
        .timestamp_ms = 0,
    };

    try std.testing.expectError(error.StaleContent, svc.apply(&record));

    // File must remain unchanged.
    var buf: [64]u8 = undefined;
    var f = try tmp.dir.openFile(io, "data.txt", .{});
    defer f.close(io);
    const n = try f.readPositionalAll(io, &buf, 0);
    try std.testing.expectEqualStrings("version A", buf[0..n]);
}

test "transaction: path traversal escape is rejected by WorkspacePath" {
    // WorkspacePath.parse must reject any attempt to escape the workspace.
    try std.testing.expectError(error.ContainsEscape, path_mod.WorkspacePath.parse("../../etc/passwd"));
    try std.testing.expectError(error.ContainsEscape, path_mod.WorkspacePath.parse("../outside.txt"));
    try std.testing.expectError(error.AbsolutePath, path_mod.WorkspacePath.parse("/etc/passwd"));
}

test "transaction: undo fails when not in applied state" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = path_mod.WorkspaceRoot.init(tmp.dir, ".");
    var svc = transaction.TransactionService.init(allocator, io, root);

    var files_arr = [0]edit.FileEdit{};
    var record = transaction.TransactionRecord{
        .id = 5,
        .state = .proposed,
        .workspace_edit = .{ .files = &files_arr },
        .timestamp_ms = 0,
    };

    try std.testing.expectError(error.InvalidState, svc.undo(&record));
}

test "transaction: validate rejects empty transaction" {
    const ws_edit = edit.WorkspaceEdit{ .files = &.{} };
    try std.testing.expectError(error.EmptyTransaction, ws_edit.validate());
}

test "transaction: validate rejects duplicate paths" {
    const files = [2]edit.FileEdit{
        .{ .path = "src/main.zig", .operation = .modify, .expected_hash = 1, .edits = &.{} },
        .{ .path = "src/main.zig", .operation = .modify, .expected_hash = 1, .edits = &.{} },
    };
    const ws_edit = edit.WorkspaceEdit{ .files = &files };
    try std.testing.expectError(error.DuplicatePath, ws_edit.validate());
}
