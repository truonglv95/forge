const std = @import("std");
const workspace = @import("forge-workspace");
const mcp_config = @import("mcp_config.zig");
const mcp_client = @import("mcp_client.zig");
const dispatch = @import("tools/dispatch.zig");
const tool_registry = @import("tools/registry.zig");

pub const RegistryError = error{
    OutOfMemory,
};

pub const RegisteredTool = struct {
    qualified_name: []const u8,
    server_name: []const u8,
    tool_name: []const u8,
    description: ?[]const u8,
    input_schema_json: []const u8,
    session_index: usize,
    /// MCP tool annotations JSON (may contain readOnly hint).
    /// When present, Forge uses this to infer risk/approval policy via
    /// mcp_capability.inferPolicy() instead of defaulting to high risk.
    annotations_json: ?[]const u8 = null,
};

pub const RegisteredResource = struct {
    server_name: []const u8,
    uri: []const u8,
    name: []const u8,
    session_index: usize,
};

pub const ServerError = struct {
    server_name: []const u8,
    message: []const u8,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    sessions: []mcp_client.Session,
    tools: []RegisteredTool,
    resources: []RegisteredResource,
    status_lines: []const u8,
    instructions_text: []const u8,
    resources_summary: []const u8,
    prompts_summary: []const u8,
    errors: []ServerError,

    pub fn load(
        allocator: std.mem.Allocator,
        io: std.Io,
        root: workspace.WorkspaceRoot,
        workspace_cwd: []const u8,
        enabled: bool,
        home_dir: ?[]const u8,
        environ_map: ?*const std.process.Environ.Map,
    ) RegistryError!Registry {
        if (!enabled) {
            return try emptyRegistry(allocator, "MCP disabled");
        }

        var cfg = mcp_config.loadAll(allocator, io, root, .{
            .workspace_cwd = workspace_cwd,
            .home_dir = home_dir,
            .environ_map = environ_map,
            .io = io,
        }) catch {
            return try emptyRegistry(allocator, "MCP: config load failed");
        };
        defer cfg.deinit();

        if (!cfg.enabled or cfg.servers.len == 0) {
            return try emptyRegistry(allocator, "MCP: no servers configured");
        }

        var sessions: std.ArrayList(mcp_client.Session) = .empty;
        errdefer {
            for (sessions.items) |*session| session.deinit();
            sessions.deinit(allocator);
        }

        var tools: std.ArrayList(RegisteredTool) = .empty;
        errdefer {
            for (tools.items) |tool| freeTool(allocator, tool);
            tools.deinit(allocator);
        }

        var resources: std.ArrayList(RegisteredResource) = .empty;
        errdefer {
            for (resources.items) |res| freeResource(allocator, res);
            resources.deinit(allocator);
        }

        var errors: std.ArrayList(ServerError) = .empty;
        errdefer {
            for (errors.items) |err_item| {
                allocator.free(err_item.server_name);
                allocator.free(err_item.message);
            }
            errors.deinit(allocator);
        }

        var instructions_buf: std.ArrayList(u8) = .empty;
        errdefer instructions_buf.deinit(allocator);
        var resources_buf: std.ArrayList(u8) = .empty;
        errdefer resources_buf.deinit(allocator);
        var prompts_buf: std.ArrayList(u8) = .empty;
        errdefer prompts_buf.deinit(allocator);

        var connected: u32 = 0;
        var tool_count: u32 = 0;
        var resource_count: u32 = 0;

        for (cfg.servers) |spec| {
            var session = mcp_client.Session.connect(allocator, io, spec, workspace_cwd) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "{s}: connect failed ({s})", .{ spec.name, @errorName(err) });
                try errors.append(allocator, .{
                    .server_name = try allocator.dupe(u8, spec.name),
                    .message = msg,
                });
                continue;
            };

            if (session.instructions) |ins| {
                try instructions_buf.print(allocator, "[{s}] {s}\n", .{ spec.name, ins });
            }

            var listed = session.listTools() catch |err| {
                session.deinit();
                const msg = try std.fmt.allocPrint(allocator, "{s}: tools/list failed ({s})", .{ spec.name, @errorName(err) });
                try errors.append(allocator, .{
                    .server_name = try allocator.dupe(u8, spec.name),
                    .message = msg,
                });
                continue;
            };
            defer listed.deinit();

            var res_list = session.listResources() catch mcp_client.ResourceList{ .allocator = allocator, .items = &.{} };
            defer res_list.deinit();

            var prompt_list = session.listPrompts() catch mcp_client.PromptList{ .allocator = allocator, .items = &.{} };
            defer prompt_list.deinit();

            const session_index = sessions.items.len;
            try sessions.append(allocator, session);
            connected += 1;

            for (listed.items) |tool| {
                const qualified = try makeQualifiedName(allocator, spec.name, tool.name);
                try tools.append(allocator, .{
                    .qualified_name = qualified,
                    .server_name = try allocator.dupe(u8, spec.name),
                    .tool_name = try allocator.dupe(u8, tool.name),
                    .description = if (tool.description) |d| try allocator.dupe(u8, d) else null,
                    .input_schema_json = try allocator.dupe(u8, tool.input_schema_json),
                    .session_index = session_index,
                    .annotations_json = if (tool.annotations_json) |a| try allocator.dupe(u8, a) else null,
                });
                tool_count += 1;
            }

            for (res_list.items) |res| {
                try resources.append(allocator, .{
                    .server_name = try allocator.dupe(u8, spec.name),
                    .uri = try allocator.dupe(u8, res.uri),
                    .name = try allocator.dupe(u8, res.name),
                    .session_index = session_index,
                });
                try resources_buf.print(allocator, "- [{s}] {s} ({s})\n", .{ spec.name, res.name, res.uri });
                resource_count += 1;
            }

            for (prompt_list.items) |prompt| {
                if (prompt.description) |desc| {
                    try prompts_buf.print(allocator, "- [{s}] {s}: {s}\n", .{ spec.name, prompt.name, desc });
                } else {
                    try prompts_buf.print(allocator, "- [{s}] {s}\n", .{ spec.name, prompt.name });
                }
            }
        }

        var status_writer: std.ArrayList(u8) = .empty;
        errdefer status_writer.deinit(allocator);
        try status_writer.print(allocator, "MCP: {d}/{d} servers, {d} tools, {d} resources", .{
            connected,
            cfg.servers.len,
            tool_count,
            resource_count,
        });
        if (errors.items.len > 0) {
            try status_writer.appendSlice(allocator, " | errors:");
            for (errors.items) |err_item| {
                try status_writer.print(allocator, " {s}={s};", .{ err_item.server_name, err_item.message });
            }
        }

        return .{
            .allocator = allocator,
            .sessions = try sessions.toOwnedSlice(allocator),
            .tools = try tools.toOwnedSlice(allocator),
            .resources = try resources.toOwnedSlice(allocator),
            .status_lines = try status_writer.toOwnedSlice(allocator),
            .instructions_text = try instructions_buf.toOwnedSlice(allocator),
            .resources_summary = try resources_buf.toOwnedSlice(allocator),
            .prompts_summary = try prompts_buf.toOwnedSlice(allocator),
            .errors = try errors.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: *Registry) void {
        for (self.tools) |tool| freeTool(self.allocator, tool);
        self.allocator.free(self.tools);
        for (self.resources) |res| freeResource(self.allocator, res);
        self.allocator.free(self.resources);
        for (self.sessions) |*session| session.deinit();
        self.allocator.free(self.sessions);
        self.allocator.free(self.status_lines);
        self.allocator.free(self.instructions_text);
        self.allocator.free(self.resources_summary);
        self.allocator.free(self.prompts_summary);
        for (self.errors) |err_item| {
            self.allocator.free(err_item.server_name);
            self.allocator.free(err_item.message);
        }
        self.allocator.free(self.errors);
        self.* = undefined;
    }

    pub fn isEmpty(self: *const Registry) bool {
        return self.tools.len == 0;
    }

    pub fn hasTool(self: *const Registry, qualified_name: []const u8) bool {
        return self.findTool(qualified_name) != null;
    }

    pub fn findTool(self: *const Registry, qualified_name: []const u8) ?*const RegisteredTool {
        for (self.tools) |*tool| {
            if (std.mem.eql(u8, tool.qualified_name, qualified_name)) return tool;
        }
        return null;
    }

    pub fn callTool(self: *Registry, qualified_name: []const u8, arguments_json: []const u8) RegistryError!dispatch.ExecutionResult {
        const tool = self.findTool(qualified_name) orelse return error.OutOfMemory;
        if (tool.session_index >= self.sessions.len) return error.OutOfMemory;
        return self.sessions[tool.session_index].callTool(tool.tool_name, arguments_json) catch |err| {
            const msg = try std.fmt.allocPrint(self.allocator, "MCP tool '{s}' failed: {s}", .{ qualified_name, @errorName(err) });
            return .{ .text = msg };
        };
    }

    pub fn readResource(self: *Registry, uri: []const u8) RegistryError![]u8 {
        for (self.resources) |res| {
            if (std.mem.eql(u8, res.uri, uri)) {
                return self.sessions[res.session_index].readResource(uri) catch {
                    return try self.allocator.dupe(u8, "resource read failed");
                };
            }
        }
        return try self.allocator.dupe(u8, "resource not found");
    }

    pub fn buildDeclarationsJson(self: *const Registry, allocator: std.mem.Allocator) RegistryError![]u8 {
        if (self.tools.len == 0) {
            return try allocator.dupe(u8, tool_registry.native_declarations_json);
        }

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, tool_registry.native_declarations_json);
        if (out.items.len > 0 and out.items[out.items.len - 1] == ']') {
            _ = out.pop();
        } else {
            try out.append(allocator, '[');
        }

        for (self.tools, 0..) |tool, i| {
            if (i > 0 or tool_registry.native_declarations_json.len > 2) {
                try out.append(allocator, ',');
            }
            const desc = tool.description orelse tool.tool_name;
            const escaped_desc = try jsonEscape(allocator, desc);
            defer allocator.free(escaped_desc);
            const piece = try std.fmt.allocPrint(allocator, "{{\"name\":\"{s}\",\"description\":\"{s}\",\"parameters\":{s}}}", .{
                tool.qualified_name,
                escaped_desc,
                tool.input_schema_json,
            });
            defer allocator.free(piece);
            try out.appendSlice(allocator, piece);
        }
        try out.append(allocator, ']');
        return try out.toOwnedSlice(allocator);
    }

    fn emptyRegistry(allocator: std.mem.Allocator, status: []const u8) RegistryError!Registry {
        return .{
            .allocator = allocator,
            .sessions = &.{},
            .tools = &.{},
            .resources = &.{},
            .status_lines = try allocator.dupe(u8, status),
            .instructions_text = try allocator.dupe(u8, ""),
            .resources_summary = try allocator.dupe(u8, ""),
            .prompts_summary = try allocator.dupe(u8, ""),
            .errors = &.{},
        };
    }

    fn freeTool(allocator: std.mem.Allocator, tool: RegisteredTool) void {
        allocator.free(tool.qualified_name);
        allocator.free(tool.server_name);
        allocator.free(tool.tool_name);
        if (tool.description) |d| allocator.free(d);
        allocator.free(tool.input_schema_json);
        if (tool.annotations_json) |a| allocator.free(a);
    }

    fn freeResource(allocator: std.mem.Allocator, res: RegisteredResource) void {
        allocator.free(res.server_name);
        allocator.free(res.uri);
        allocator.free(res.name);
    }
};

fn makeQualifiedName(allocator: std.mem.Allocator, server_name: []const u8, tool_name: []const u8) ![]u8 {
    var server: std.ArrayList(u8) = .empty;
    defer server.deinit(allocator);
    try server.appendSlice(allocator, "mcp_");
    for (server_name) |c| try server.append(allocator, sanitizeIdent(c));
    try server.append(allocator, '_');
    for (tool_name) |c| try server.append(allocator, sanitizeIdent(c));
    return try server.toOwnedSlice(allocator);
}

fn sanitizeIdent(c: u8) u8 {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9' => std.ascii.toLower(c),
        else => '_',
    };
}

fn jsonEscape(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (text) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            else => try out.append(allocator, c),
        }
    }
    return try out.toOwnedSlice(allocator);
}

test "makeQualifiedName sanitizes" {
    const allocator = std.testing.allocator;
    const name = try makeQualifiedName(allocator, "my-server", "tool.name");
    defer allocator.free(name);
    try std.testing.expectEqualStrings("mcp_my_server_tool_name", name);
}
