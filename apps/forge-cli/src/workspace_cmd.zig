const std = @import("std");
const workspace = @import("forge-workspace");
const ai = @import("forge-ai");
const args_mod = @import("args.zig");

pub const AiConfig = struct {
    allocator: std.mem.Allocator,
    provider: []const u8,
    model: ?[]const u8 = null,

    pub fn deinit(self: *AiConfig) void {
        self.allocator.free(self.provider);
        if (self.model) |model| self.allocator.free(model);
        self.* = undefined;
    }

    pub fn load(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot) !?AiConfig {
        var provider: []const u8 = "auto";
        var model: ?[]const u8 = null;
        var owned_provider: ?[]u8 = null;
        defer if (owned_provider) |value| allocator.free(value);
        var owned_model: ?[]u8 = null;
        defer if (owned_model) |value| allocator.free(value);

        if (workspace.global_store.joinHome(allocator, workspace.global_store.config_file)) |global_path| {
            defer allocator.free(global_path);
            if (workspace.global_store.readAbsoluteFile(allocator, io, global_path)) |content| {
                defer allocator.free(content);
                if (workspace.Config.parse(content)) |parsed| {
                    owned_provider = try allocator.dupe(u8, parsed.ai_provider);
                    provider = owned_provider.?;
                    if (parsed.ai_model) |model_name| {
                        owned_model = try allocator.dupe(u8, model_name);
                        model = owned_model;
                    }
                } else |_| {}
            } else |_| {}
        } else |_| {}

        const wp = workspace.WorkspacePath.parse("forge.toml") catch return try finalizeAiConfig(allocator, provider, model);
        var snap = workspace.FileSnapshot.read(allocator, io, root, wp) catch return try finalizeAiConfig(allocator, provider, model);
        defer snap.deinit();
        const parsed = workspace.Config.parse(snap.content) catch return try finalizeAiConfig(allocator, provider, model);
        return try finalizeAiConfig(allocator, parsed.ai_provider, parsed.ai_model orelse model);
    }

    fn finalizeAiConfig(allocator: std.mem.Allocator, provider_name: []const u8, model: ?[]const u8) !?AiConfig {
        const provider = try allocator.dupe(u8, provider_name);
        errdefer allocator.free(provider);
        const owned_model = if (model) |value| try allocator.dupe(u8, value) else null;
        return .{
            .allocator = allocator,
            .provider = provider,
            .model = owned_model,
        };
    }
};

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

pub fn scheduleSemanticIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    opened: OpenedWorkspace,
) void {
    ai.index_warm.scheduleBackground(allocator, io, environ_map, opened.root, opened.path);
}

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

    const tx_id = try workspace.execution.applyApproved(allocator, io, opened.root, workspace_edit, proposal_path);

    if (json) {
        try writer.print("{{\"status\":\"ok\",\"type\":\"apply\",\"transaction_id\":{d},\"state\":\"applied\"}}\n", .{tx_id});
    } else {
        try writer.print("Applied transaction {d}\n", .{tx_id});
    }

    return 0;
}
