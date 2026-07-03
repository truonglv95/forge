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
