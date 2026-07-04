const std = @import("std");
const workspace = @import("forge-workspace");
const args_mod = @import("args.zig");

pub const OpenedWorkspace = struct {
    path: []const u8,
    root: workspace.WorkspaceRoot,

    pub fn open(allocator: std.mem.Allocator, io: std.Io, parsed: args_mod.CliArgs) !OpenedWorkspace {
        const path = parsed.flags.workspace orelse ".";
        var root = try workspace.WorkspaceRoot.open(io, path);
        errdefer root.close(io);
        try workspace.recovery.recoverPending(allocator, io, root);
        return .{ .path = path, .root = root };
    }

    pub fn close(self: *OpenedWorkspace, io: std.Io) void {
        self.root.close(io);
        self.* = undefined;
    }
};

pub fn loadProposal(
    allocator: std.mem.Allocator,
    io: std.Io,
    opened: OpenedWorkspace,
    proposal_path: []const u8,
) !workspace.OwnedProposal {
    if (std.fs.path.isAbsolute(proposal_path)) {
        var file = try std.Io.Dir.openFile(std.Io.Dir.cwd(), io, proposal_path, .{});
        defer file.close(io);
        const stat = try file.stat(io);
        const size: usize = @intCast(stat.size);
        const content = try allocator.alloc(u8, size);
        errdefer allocator.free(content);
        const read_len = try file.readPositionalAll(io, content, 0);
        if (read_len != size) return error.UnexpectedEof;
        return workspace.OwnedProposal.parseJson(allocator, content);
    }
    return workspace.OwnedProposal.readPath(allocator, io, opened.root, proposal_path);
}

pub fn approved(parsed: args_mod.CliArgs) bool {
    return parsed.flags.non_interactive or parsed.flags.yes;
}

pub fn applyProposal(
    allocator: std.mem.Allocator,
    io: std.Io,
    opened: OpenedWorkspace,
    proposal_path: []const u8,
    writer: *std.Io.Writer,
    json: bool,
) !u8 {
    var proposal = try loadProposal(allocator, io, opened, proposal_path);
    defer proposal.deinit();

    const workspace_edit = proposal.workspaceEdit();
    try workspace_edit.validate();

    var service = workspace.TransactionService.init(allocator, io, opened.root);
    const tx_id = try workspace.history.nextTransactionId(allocator, io, opened.root);

    var record = workspace.TransactionRecord{
        .id = tx_id,
        .state = .approved,
        .workspace_edit = workspace_edit,
        .timestamp_ms = std.Io.Timestamp.now(io, .real).toMilliseconds(),
    };
    defer service.freeRecord(&record);

    try service.apply(&record);
    try workspace.history.persistApplied(allocator, io, opened.root, &record, proposal_path);

    if (json) {
        try writer.print("{{\"status\":\"ok\",\"type\":\"apply\",\"transaction_id\":{d},\"state\":\"applied\"}}\n", .{tx_id});
    } else {
        try writer.print("Applied transaction {d}\n", .{tx_id});
    }

    return 0;
}
