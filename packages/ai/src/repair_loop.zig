const std = @import("std");
const workspace = @import("forge-workspace");
const validation_runner = @import("validation_runner.zig");

pub const TrialError = error{
    InvalidProposal,
    WorkspaceFailed,
    OutOfMemory,
};

pub const TrialResult = struct {
    passed: bool,
    report: []const u8,
};

pub fn hasFailures(results: []const validation_runner.Result) bool {
    for (results) |item| {
        if (!item.skipped and item.exit_code != 0) return true;
    }
    return false;
}

/// Applies proposal to workspace, runs validation_tasks, then restores checkpoint.
pub fn trialApplyAndValidate(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    workspace_cwd: []const u8,
    proposal_body: []const u8,
) TrialError!TrialResult {
    var proposal = workspace.OwnedProposal.parseJson(allocator, proposal_body) catch return error.InvalidProposal;
    defer proposal.deinit();

    const tasks = proposal.metadata.validation_tasks;
    if (tasks.len == 0) {
        return .{ .passed = true, .report = try allocator.dupe(u8, "") };
    }

    const workspace_edit = proposal.workspaceEdit();
    workspace_edit.validate() catch return error.InvalidProposal;

    const checkpoint_id = workspace.checkpoint.createFromEdits(allocator, io, root, proposal.files, .{
        .label = "repair-trial",
    }) catch return error.WorkspaceFailed;

    var service = workspace.TransactionService.init(allocator, io, root);
    var record = workspace.TransactionRecord{
        .id = 0,
        .state = .approved,
        .workspace_edit = workspace_edit,
        .timestamp_ms = std.Io.Timestamp.now(io, .real).toMilliseconds(),
    };
    defer service.freeRecord(&record);

    service.apply(&record) catch {
        workspace.checkpoint.restore(allocator, io, root, checkpoint_id) catch {};
        const report = try allocator.dupe(u8, "proposal failed to apply (stale hash or invalid edit)");
        return .{ .passed = false, .report = report };
    };

    const results = validation_runner.runTasks(allocator, workspace_cwd, tasks) catch {
        workspace.checkpoint.restore(allocator, io, root, checkpoint_id) catch {};
        const report = try allocator.dupe(u8, "validation runner failed");
        return .{ .passed = false, .report = report };
    };
    defer validation_runner.freeResults(allocator, results);

    workspace.checkpoint.restore(allocator, io, root, checkpoint_id) catch return error.WorkspaceFailed;

    const report = validation_runner.formatLines(allocator, results) catch return error.OutOfMemory;
    return .{ .passed = !hasFailures(results), .report = report };
}

test "hasFailures detects non-zero exit" {
    const results = [_]validation_runner.Result{
        .{ .task = "zig build test", .exit_code = 0, .output = "" },
        .{ .task = "zig build", .exit_code = 1, .output = "error" },
    };
    try std.testing.expect(hasFailures(&results));
    try std.testing.expect(!hasFailures(&results[0..1]));
}
