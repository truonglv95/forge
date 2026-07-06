const std = @import("std");
const path_mod = @import("path.zig");
const edit = @import("edit.zig");
const transaction = @import("transaction.zig");
const history = @import("history.zig");

/// Shared approved-proposal execution used by every first-party surface.
/// Approval and UI policy remain with the application; mutation, history, and
/// transaction identity remain identical across CLI and IDE.
pub fn applyApproved(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
    workspace_edit: edit.WorkspaceEdit,
    proposal_path: []const u8,
) !u64 {
    try workspace_edit.validate();

    var service = transaction.TransactionService.init(allocator, io, root);
    const tx_id = try history.nextTransactionId(allocator, io, root);
    var record = transaction.TransactionRecord{
        .id = tx_id,
        .state = .approved,
        .workspace_edit = workspace_edit,
        .timestamp_ms = std.Io.Timestamp.now(io, .real).toMilliseconds(),
    };
    defer service.freeRecord(&record);

    try service.apply(&record);
    try history.persistApplied(allocator, io, root, &record, proposal_path);
    return tx_id;
}
