const std = @import("std");
const agent_session = @import("../agent/session.zig");
const agent_ui_queue_mod = @import("agent_ui_queue.zig");
const kernel = @import("forge-kernel");

pub const AgentController = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    session: agent_session.Session,
    ui_queue: agent_ui_queue_mod.Queue = .{},
    cancel_source: ?*kernel.cancellation.CancellationTokenSource = null,
    chat_history: std.ArrayListUnmanaged(@import("../workbench.zig").ChatMessage),
    prompt_buffer: @import("forge-editor").Buffer,
    chat_system_prompt: @import("forge-editor").Buffer,

    // Configurations
    provider: []const u8 = "auto",
    model: ?[]const u8 = null,
    ollama_url: ?[]const u8 = null,
    openrouter_url: ?[]const u8 = null,
    embedding_provider: ?[]const u8 = null,
    embedding_model: ?[]const u8 = null,
    embedding_url: ?[]const u8 = null,
    mcp_enabled: bool = true,
    enable_hyde: bool = false,
    models: []const @import("../ui/agent/agent_composer.zig").ModelOption = &.{},
    embedding_models: []const @import("../ui/agent/agent_composer.zig").ModelOption = &.{},
    mcp_collapsed_servers: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !AgentController {
        var self = AgentController{
            .allocator = allocator,
            .io = io,
            .session = agent_session.Session.init(allocator, io),
            .chat_history = .empty,
            .prompt_buffer = try @import("forge-editor").Buffer.init(allocator),
            .chat_system_prompt = try @import("forge-editor").Buffer.init(allocator),
            .provider = try allocator.dupe(u8, "auto"),
            .mcp_collapsed_servers = std.StringHashMap(void).init(allocator),
        };
        errdefer self.deinit();
        return self;
    }

    pub fn deinit(self: *AgentController) void {
        var collapsed_iter = self.mcp_collapsed_servers.iterator();
        while (collapsed_iter.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.mcp_collapsed_servers.deinit();

        self.prompt_buffer.deinit();
        self.chat_system_prompt.deinit();
        for (self.chat_history.items) |msg| {
            self.allocator.free(msg.content);
            if (msg.tool_kind) |kind| self.allocator.free(kind);
            if (msg.tool_content) |content| self.allocator.free(content);
        }
        self.chat_history.deinit(self.allocator);
        self.ui_queue.deinit(self.allocator);

        // Free config
        self.allocator.free(self.provider);
        if (self.model) |model| self.allocator.free(model);
        if (self.ollama_url) |url| self.allocator.free(url);
        if (self.openrouter_url) |url| self.allocator.free(url);
        if (self.embedding_provider) |provider| self.allocator.free(provider);
        if (self.embedding_model) |model| self.allocator.free(model);
        if (self.embedding_url) |url| self.allocator.free(url);

        for (self.models) |m| {
            self.allocator.free(m.id);
            self.allocator.free(m.label);
            self.allocator.free(m.provider);
            if (m.base_url) |url| self.allocator.free(url);
        }
        self.allocator.free(self.models);

        for (self.embedding_models) |m| {
            self.allocator.free(m.id);
            self.allocator.free(m.label);
            self.allocator.free(m.provider);
            if (m.base_url) |url| self.allocator.free(url);
        }
        self.allocator.free(self.embedding_models);

        // Additional cleanup for session if necessary
    }

    pub fn isMcpServerCollapsed(self: *const AgentController, server_name: []const u8) bool {
        return self.mcp_collapsed_servers.contains(server_name);
    }

    pub fn toggleMcpServerCollapsed(self: *AgentController, server_name: []const u8) !bool {
        if (self.mcp_collapsed_servers.fetchRemove(server_name)) |entry| {
            self.allocator.free(entry.key);
            return false;
        }
        try self.mcp_collapsed_servers.put(try self.allocator.dupe(u8, server_name), {});
        return true;
    }
};
