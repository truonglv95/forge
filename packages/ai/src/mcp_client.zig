const std = @import("std");
const process_spawn = @import("forge-util").process_spawn;
const mcp_config = @import("mcp_config.zig");
const mcp_http = @import("mcp_http.zig");
const provider = @import("provider.zig");
const dispatch = @import("tools/dispatch.zig");

pub const ClientError = error{
    SpawnFailed,
    ProtocolError,
    ToolFailed,
    OutOfMemory,
    Timeout,
    UnsupportedTransport,
};

pub const Tool = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    input_schema_json: []const u8,
};

pub const Resource = struct {
    uri: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
    mime_type: ?[]const u8 = null,
};

pub const Prompt = struct {
    name: []const u8,
    description: ?[]const u8 = null,
};

pub const ToolList = struct {
    allocator: std.mem.Allocator,
    items: []Tool,
    pub fn deinit(self: *ToolList) void {
        for (self.items) |item| {
            self.allocator.free(item.name);
            if (item.description) |d| self.allocator.free(d);
            self.allocator.free(item.input_schema_json);
        }
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub const ResourceList = struct {
    allocator: std.mem.Allocator,
    items: []Resource,
    pub fn deinit(self: *ResourceList) void {
        for (self.items) |item| {
            self.allocator.free(item.uri);
            self.allocator.free(item.name);
            if (item.description) |d| self.allocator.free(d);
            if (item.mime_type) |m| self.allocator.free(m);
        }
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub const PromptList = struct {
    allocator: std.mem.Allocator,
    items: []Prompt,
    pub fn deinit(self: *PromptList) void {
        for (self.items) |item| {
            self.allocator.free(item.name);
            if (item.description) |d| self.allocator.free(d);
        }
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

const Backend = union(enum) {
    stdio: StdioBackend,
    http: mcp_http.HttpSession,

    fn deinit(self: *Backend) void {
        switch (self.*) {
            .stdio => |*s| s.deinit(),
            .http => |*h| h.deinit(),
        }
    }

    fn request(self: *Backend, allocator: std.mem.Allocator, method: []const u8, params_json: []const u8) ClientError![]u8 {
        return switch (self.*) {
            .stdio => |*s| s.request(allocator, method, params_json),
            .http => |*h| h.request(method, params_json) catch error.ProtocolError,
        };
    }

    fn notify(self: *Backend, allocator: std.mem.Allocator, method: []const u8, params_json: []const u8) ClientError!void {
        _ = allocator;
        switch (self.*) {
            .stdio => |*s| try s.notify(method, params_json),
            .http => {},
        }
    }
};

const StdioBackend = struct {
    allocator: std.mem.Allocator,
    child: process_spawn.Child,
    pending: std.ArrayList(u8),
    next_id: i64 = 1,
    stderr_log: std.ArrayList(u8),

    fn deinit(self: *StdioBackend) void {
        self.pending.deinit(self.allocator);
        self.stderr_log.deinit(self.allocator);
        self.child.deinit();
    }

    fn notify(self: *StdioBackend, method: []const u8, params_json: []const u8) ClientError!void {
        const msg = try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}\n", .{ method, params_json });
        defer self.allocator.free(msg);
        self.child.writeAll(msg) catch return error.ProtocolError;
    }

    fn request(self: *StdioBackend, allocator: std.mem.Allocator, method: []const u8, params_json: []const u8) ClientError![]u8 {
        const id = self.next_id;
        self.next_id += 1;
        const msg = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}\n", .{ id, method, params_json });
        defer allocator.free(msg);
        self.child.writeAll(msg) catch return error.ProtocolError;

        while (true) {
            const line = try self.readLine();
            defer allocator.free(line);
            if (line.len == 0) continue;
            if (try parseRpcResponse(allocator, line, id)) |result| return result;
        }
    }

    fn readLine(self: *StdioBackend) ClientError![]u8 {
        const max_line: usize = 4 * 1024 * 1024;
        while (true) {
            if (std.mem.indexOfScalar(u8, self.pending.items, '\n')) |nl| {
                const line = try self.allocator.dupe(u8, std.mem.trim(u8, self.pending.items[0..nl], "\r"));
                const rest = try self.allocator.dupe(u8, self.pending.items[nl + 1 ..]);
                self.pending.clearRetainingCapacity();
                self.pending.appendSlice(self.allocator, rest) catch return error.OutOfMemory;
                self.allocator.free(rest);
                return line;
            }
            if (self.pending.items.len >= max_line) return error.ProtocolError;
            if (self.child.stdout_fd < 0) return error.ProtocolError;
            var chunk: [4096]u8 = undefined;
            const n = std.posix.read(self.child.stdout_fd, &chunk) catch return error.ProtocolError;
            if (n == 0) {
                if (self.pending.items.len == 0) return error.ProtocolError;
                return self.allocator.dupe(u8, self.pending.items);
            }
            self.pending.appendSlice(self.allocator, chunk[0..n]) catch return error.OutOfMemory;
            if (self.child.stderr_fd >= 0) {
                const sn = std.posix.read(self.child.stderr_fd, &chunk) catch 0;
                if (sn > 0) self.stderr_log.appendSlice(self.allocator, chunk[0..sn]) catch {};
            }
        }
    }
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    server_name: []const u8,
    backend: Backend,
    instructions: ?[]const u8 = null,
    protocol_version: ?[]const u8 = null,

    pub fn connect(
        allocator: std.mem.Allocator,
        io: std.Io,
        spec: mcp_config.ServerSpec,
        workspace_cwd: []const u8,
    ) ClientError!Session {
        var backend = try connectBackend(allocator, io, spec, workspace_cwd);
        errdefer backend.deinit();

        var session = Session{
            .allocator = allocator,
            .server_name = try allocator.dupe(u8, spec.name),
            .backend = backend,
        };
        errdefer {
            session.deinit();
        }

        const init_params = std.fmt.allocPrint(allocator,
            \\{{"protocolVersion":"2024-11-05","capabilities":{{"roots":{{"listChanged":true}},"sampling":{{}}}},"clientInfo":{{"name":"forge","version":"0.1.0"}},"roots":[{{"uri":"file://{s}","name":"workspace"}}]}}
        , .{workspace_cwd}) catch return error.OutOfMemory;
        defer allocator.free(init_params);

        const init_result = session.backend.request(allocator, "initialize", init_params) catch return error.ProtocolError;
        defer allocator.free(init_result);

        const InitResult = struct {
            protocolVersion: ?[]const u8 = null,
            instructions: ?[]const u8 = null,
        };
        if (std.json.parseFromSlice(InitResult, allocator, init_result, .{ .ignore_unknown_fields = true })) |parsed| {
            defer parsed.deinit();
            if (parsed.value.protocolVersion) |pv| session.protocol_version = try allocator.dupe(u8, pv);
            if (parsed.value.instructions) |ins| session.instructions = try allocator.dupe(u8, ins);
        } else |_| {}

        try session.backend.notify(allocator, "notifications/initialized", "{}");

        return session;
    }

    pub fn deinit(self: *Session) void {
        self.allocator.free(self.server_name);
        if (self.instructions) |ins| self.allocator.free(ins);
        if (self.protocol_version) |pv| self.allocator.free(pv);
        self.backend.deinit();
        self.* = undefined;
    }

    pub fn listTools(self: *Session) ClientError!ToolList {
        const result = try self.backend.request(self.allocator, "tools/list", "{}");
        defer self.allocator.free(result);
        const Root = struct {
            tools: ?[]struct {
                name: []const u8,
                description: ?[]const u8 = null,
                inputSchema: ?std.json.Value = null,
            } = null,
        };
        var parsed = std.json.parseFromSlice(Root, self.allocator, result, .{ .ignore_unknown_fields = true }) catch return error.ProtocolError;
        defer parsed.deinit();
        const tools = parsed.value.tools orelse return ToolList{ .allocator = self.allocator, .items = &.{} };

        var items: std.ArrayList(Tool) = .empty;
        errdefer {
            for (items.items) |item| {
                self.allocator.free(item.name);
                if (item.description) |d| self.allocator.free(d);
                self.allocator.free(item.input_schema_json);
            }
            items.deinit(self.allocator);
        }
        for (tools) |tool| {
            const schema_json = if (tool.inputSchema) |schema|
                try std.json.Stringify.valueAlloc(self.allocator, schema, .{})
            else
                try self.allocator.dupe(u8, "{\"type\":\"object\",\"properties\":{}}");
            try items.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, tool.name),
                .description = if (tool.description) |d| try self.allocator.dupe(u8, d) else null,
                .input_schema_json = schema_json,
            });
        }
        return ToolList{ .allocator = self.allocator, .items = try items.toOwnedSlice(self.allocator) };
    }

    pub fn listResources(self: *Session) ClientError!ResourceList {
        const result = self.backend.request(self.allocator, "resources/list", "{}") catch {
            return ResourceList{ .allocator = self.allocator, .items = &.{} };
        };
        defer self.allocator.free(result);
        const Root = struct {
            resources: ?[]struct {
                uri: []const u8,
                name: []const u8,
                description: ?[]const u8 = null,
                mimeType: ?[]const u8 = null,
            } = null,
        };
        var parsed = std.json.parseFromSlice(Root, self.allocator, result, .{ .ignore_unknown_fields = true }) catch return error.ProtocolError;
        defer parsed.deinit();
        const resources = parsed.value.resources orelse return ResourceList{ .allocator = self.allocator, .items = &.{} };

        var items: std.ArrayList(Resource) = .empty;
        errdefer {
            for (items.items) |item| {
                self.allocator.free(item.uri);
                self.allocator.free(item.name);
                if (item.description) |d| self.allocator.free(d);
                if (item.mime_type) |m| self.allocator.free(m);
            }
            items.deinit(self.allocator);
        }
        for (resources) |res| {
            try items.append(self.allocator, .{
                .uri = try self.allocator.dupe(u8, res.uri),
                .name = try self.allocator.dupe(u8, res.name),
                .description = if (res.description) |d| try self.allocator.dupe(u8, d) else null,
                .mime_type = if (res.mimeType) |m| try self.allocator.dupe(u8, m) else null,
            });
        }
        return ResourceList{ .allocator = self.allocator, .items = try items.toOwnedSlice(self.allocator) };
    }

    pub fn readResource(self: *Session, uri: []const u8) ClientError![]u8 {
        const params = try std.fmt.allocPrint(self.allocator, "{{\"uri\":\"{s}\"}}", .{uri});
        defer self.allocator.free(params);
        const result = try self.backend.request(self.allocator, "resources/read", params);
        defer self.allocator.free(result);
        const Root = struct {
            contents: ?[]struct {
                uri: ?[]const u8 = null,
                mimeType: ?[]const u8 = null,
                text: ?[]const u8 = null,
                blob: ?[]const u8 = null,
            } = null,
        };
        var parsed = std.json.parseFromSlice(Root, self.allocator, result, .{ .ignore_unknown_fields = true }) catch return error.ProtocolError;
        defer parsed.deinit();
        const contents = parsed.value.contents orelse return try self.allocator.dupe(u8, "");
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        for (contents) |part| {
            if (part.text) |text| {
                try out.appendSlice(self.allocator, text);
                try out.append(self.allocator, '\n');
            } else if (part.blob) |blob| {
                try out.appendSlice(self.allocator, "(binary blob, ");
                try out.appendSlice(self.allocator, blob);
                try out.appendSlice(self.allocator, " bytes)\n");
            }
        }
        if (out.items.len == 0) return try self.allocator.dupe(u8, "");
        if (out.items[out.items.len - 1] == '\n') _ = out.pop();
        return try out.toOwnedSlice(self.allocator);
    }

    pub fn listPrompts(self: *Session) ClientError!PromptList {
        const result = self.backend.request(self.allocator, "prompts/list", "{}") catch {
            return PromptList{ .allocator = self.allocator, .items = &.{} };
        };
        defer self.allocator.free(result);
        const Root = struct {
            prompts: ?[]struct {
                name: []const u8,
                description: ?[]const u8 = null,
            } = null,
        };
        var parsed = std.json.parseFromSlice(Root, self.allocator, result, .{ .ignore_unknown_fields = true }) catch return error.ProtocolError;
        defer parsed.deinit();
        const prompts = parsed.value.prompts orelse return PromptList{ .allocator = self.allocator, .items = &.{} };
        var items: std.ArrayList(Prompt) = .empty;
        errdefer {
            for (items.items) |item| {
                self.allocator.free(item.name);
                if (item.description) |d| self.allocator.free(d);
            }
            items.deinit(self.allocator);
        }
        for (prompts) |prompt| {
            try items.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, prompt.name),
                .description = if (prompt.description) |d| try self.allocator.dupe(u8, d) else null,
            });
        }
        return PromptList{ .allocator = self.allocator, .items = try items.toOwnedSlice(self.allocator) };
    }

    pub fn callTool(self: *Session, tool_name: []const u8, arguments_json: []const u8) ClientError!dispatch.ExecutionResult {
        const params = try std.fmt.allocPrint(self.allocator, "{{\"name\":\"{s}\",\"arguments\":{s}}}", .{ tool_name, arguments_json });
        defer self.allocator.free(params);
        const result = try self.backend.request(self.allocator, "tools/call", params);
        defer self.allocator.free(result);
        return formatToolResult(self.allocator, result);
    }

    fn formatToolResult(allocator: std.mem.Allocator, result_json: []const u8) ClientError!dispatch.ExecutionResult {
        const Root = struct {
            isError: ?bool = null,
            content: ?[]struct {
                type: ?[]const u8 = null,
                text: ?[]const u8 = null,
                data: ?[]const u8 = null,
                mimeType: ?[]const u8 = null,
            } = null,
        };
        var parsed = std.json.parseFromSlice(Root, allocator, result_json, .{ .ignore_unknown_fields = true }) catch return error.ProtocolError;
        defer parsed.deinit();
        if (parsed.value.isError == true) return error.ToolFailed;

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var images: std.ArrayList(provider.ImagePart) = .empty;
        errdefer {
            for (images.items) |img| {
                allocator.free(img.mime_type);
                allocator.free(img.data_base64);
            }
            images.deinit(allocator);
        }

        if (parsed.value.content) |parts| {
            for (parts) |part| {
                if (part.text) |text| {
                    try out.appendSlice(allocator, text);
                    try out.append(allocator, '\n');
                } else if (part.data) |data| {
                    const mime = part.mimeType orelse "application/octet-stream";
                    if (std.mem.startsWith(u8, mime, "image/")) {
                        try images.append(allocator, .{
                            .mime_type = try allocator.dupe(u8, mime),
                            .data_base64 = try allocator.dupe(u8, data),
                        });
                    } else {
                        try out.print(allocator, "[{s} base64 {d} chars]\n", .{ mime, data.len });
                    }
                } else if (part.type) |ty| {
                    try out.print(allocator, "[{s} content]\n", .{ty});
                }
            }
        }
        if (out.items.len == 0 and images.items.len == 0) {
            try out.appendSlice(allocator, "(empty tool result)");
        }
        if (out.items.len > 0 and out.items[out.items.len - 1] == '\n') _ = out.pop();
        return .{
            .text = try out.toOwnedSlice(allocator),
            .images = try images.toOwnedSlice(allocator),
        };
    }
};

fn connectBackend(allocator: std.mem.Allocator, io: std.Io, spec: mcp_config.ServerSpec, workspace_cwd: []const u8) ClientError!Backend {
    switch (spec.transport) {
        .http, .sse => {
            const url = spec.url orelse return error.UnsupportedTransport;
            return .{ .http = mcp_http.HttpSession.init(allocator, io, url, spec.headers) catch return error.ProtocolError };
        },
        .stdio => {
            const command = spec.command orelse return error.SpawnFailed;
            var argv: std.ArrayList([]const u8) = .empty;
            errdefer argv.deinit(allocator);
            try argv.append(allocator, command);
            for (spec.args) |arg| try argv.append(allocator, arg);

            var extra_env: std.ArrayList(process_spawn.EnvEntry) = .empty;
            errdefer extra_env.deinit(allocator);
            for (spec.env) |item| try extra_env.append(allocator, .{ .key = item.name, .value = item.value });

            const cwd = spec.cwd orelse workspace_cwd;
            const child = process_spawn.spawn(allocator, argv.items, .{
                .cwd = cwd,
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .pipe,
                .extra_env = extra_env.items,
            }) catch return error.SpawnFailed;

            return .{ .stdio = .{
                .allocator = allocator,
                .child = child,
                .pending = .empty,
                .stderr_log = .empty,
            } };
        },
    }
}

fn parseRpcResponse(allocator: std.mem.Allocator, line: []const u8, id: i64) ClientError!?[]u8 {
    const Response = struct {
        id: ?std.json.Value = null,
        result: ?std.json.Value = null,
        @"error": ?std.json.Value = null,
    };
    var parsed = std.json.parseFromSlice(Response, allocator, line, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    if (parsed.value.id) |id_val| {
        const matches = switch (id_val) {
            .integer => |n| n == id,
            .float => |n| @as(i64, @intFromFloat(n)) == id,
            else => false,
        };
        if (!matches) return null;
    } else return null;
    if (parsed.value.@"error" != null) return error.ProtocolError;
    const result_val = parsed.value.result orelse return error.ProtocolError;
    return std.json.Stringify.valueAlloc(allocator, result_val, .{}) catch return error.OutOfMemory;
}
