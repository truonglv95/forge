const std = @import("std");
const workspace = @import("forge-workspace");
const ai = @import("forge-ai");
const args_mod = @import("args.zig");

pub const AiConfig = struct {
    allocator: std.mem.Allocator,
    provider: []const u8,
    model: ?[]const u8 = null,
    ollama_url: ?[]const u8 = null,
    openrouter_url: ?[]const u8 = null,
    embedding_provider: ?[]const u8 = null,
    embedding_model: ?[]const u8 = null,
    embedding_url: ?[]const u8 = null,

    pub fn deinit(self: *AiConfig) void {
        self.allocator.free(self.provider);
        if (self.model) |model| self.allocator.free(model);
        if (self.ollama_url) |url| self.allocator.free(url);
        if (self.openrouter_url) |url| self.allocator.free(url);
        if (self.embedding_provider) |provider| self.allocator.free(provider);
        if (self.embedding_model) |model| self.allocator.free(model);
        if (self.embedding_url) |url| self.allocator.free(url);
        self.* = undefined;
    }

    pub fn load(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot) !?AiConfig {
        _ = root;
        var provider: []const u8 = "auto";
        var model: ?[]const u8 = null;
        var ollama_url: ?[]const u8 = null;
        var openrouter_url: ?[]const u8 = null;
        var embedding_provider: ?[]const u8 = null;
        var embedding_model: ?[]const u8 = null;
        var embedding_url: ?[]const u8 = null;
        var owned_provider: ?[]u8 = null;
        defer if (owned_provider) |value| allocator.free(value);
        var owned_model: ?[]u8 = null;
        defer if (owned_model) |value| allocator.free(value);
        var owned_ollama_url: ?[]u8 = null;
        defer if (owned_ollama_url) |value| allocator.free(value);
        var owned_openrouter_url: ?[]u8 = null;
        defer if (owned_openrouter_url) |value| allocator.free(value);
        var owned_embedding_provider: ?[]u8 = null;
        defer if (owned_embedding_provider) |value| allocator.free(value);
        var owned_embedding_model: ?[]u8 = null;
        defer if (owned_embedding_model) |value| allocator.free(value);
        var owned_embedding_url: ?[]u8 = null;
        defer if (owned_embedding_url) |value| allocator.free(value);

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
                    if (parsed.ai_ollama_url) |value| {
                        owned_ollama_url = try allocator.dupe(u8, value);
                        ollama_url = owned_ollama_url;
                    }
                    if (parsed.ai_openrouter_url) |value| {
                        owned_openrouter_url = try allocator.dupe(u8, value);
                        openrouter_url = owned_openrouter_url;
                    }
                    if (parsed.ai_embedding_provider) |value| {
                        owned_embedding_provider = try allocator.dupe(u8, value);
                        embedding_provider = owned_embedding_provider;
                    }
                    if (parsed.ai_embedding_model) |value| {
                        owned_embedding_model = try allocator.dupe(u8, value);
                        embedding_model = owned_embedding_model;
                    }
                    if (parsed.ai_embedding_url) |value| {
                        owned_embedding_url = try allocator.dupe(u8, value);
                        embedding_url = owned_embedding_url;
                    }
                } else |_| {}
            } else |_| {}
        } else |_| {}

        const settings_abs = workspace.global_store.joinHome(allocator, "settings.toml") catch return try finalizeAiConfig(allocator, provider, model, ollama_url, openrouter_url, embedding_provider, embedding_model, embedding_url);
        defer allocator.free(settings_abs);
        const content = workspace.global_store.readAbsoluteFile(allocator, io, settings_abs) catch return try finalizeAiConfig(allocator, provider, model, ollama_url, openrouter_url, embedding_provider, embedding_model, embedding_url);
        defer allocator.free(content);
        const parsed = workspace.Config.parse(content) catch return try finalizeAiConfig(allocator, provider, model, ollama_url, openrouter_url, embedding_provider, embedding_model, embedding_url);
        return try finalizeAiConfig(
            allocator,
            parsed.ai_provider,
            parsed.ai_model orelse model,
            parsed.ai_ollama_url orelse ollama_url,
            parsed.ai_openrouter_url orelse openrouter_url,
            parsed.ai_embedding_provider orelse embedding_provider,
            parsed.ai_embedding_model orelse embedding_model,
            parsed.ai_embedding_url orelse embedding_url,
        );
    }

    fn finalizeAiConfig(
        allocator: std.mem.Allocator,
        provider_name: []const u8,
        model: ?[]const u8,
        ollama_url: ?[]const u8,
        openrouter_url: ?[]const u8,
        embedding_provider: ?[]const u8,
        embedding_model: ?[]const u8,
        embedding_url: ?[]const u8,
    ) !?AiConfig {
        const provider = try allocator.dupe(u8, provider_name);
        errdefer allocator.free(provider);
        const owned_model = if (model) |value| try allocator.dupe(u8, value) else null;
        errdefer if (owned_model) |value| allocator.free(value);
        const owned_ollama_url = if (ollama_url) |value| try allocator.dupe(u8, value) else null;
        errdefer if (owned_ollama_url) |value| allocator.free(value);
        const owned_openrouter_url = if (openrouter_url) |value| try allocator.dupe(u8, value) else null;
        errdefer if (owned_openrouter_url) |value| allocator.free(value);
        const owned_embedding_provider = if (embedding_provider) |value| try allocator.dupe(u8, value) else null;
        errdefer if (owned_embedding_provider) |value| allocator.free(value);
        const owned_embedding_model = if (embedding_model) |value| try allocator.dupe(u8, value) else null;
        errdefer if (owned_embedding_model) |value| allocator.free(value);
        const owned_embedding_url = if (embedding_url) |value| try allocator.dupe(u8, value) else null;
        return .{
            .allocator = allocator,
            .provider = provider,
            .model = owned_model,
            .ollama_url = owned_ollama_url,
            .openrouter_url = owned_openrouter_url,
            .embedding_provider = owned_embedding_provider,
            .embedding_model = owned_embedding_model,
            .embedding_url = owned_embedding_url,
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
