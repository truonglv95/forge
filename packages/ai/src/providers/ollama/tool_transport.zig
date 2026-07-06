const std = @import("std");
const ollama_provider = @import("../../ollama_provider.zig");
const tool_registry = @import("../../tools/registry.zig");
const tool_args = @import("../../tools/args.zig");
const mcp_registry = @import("../../mcp_registry.zig");
const turn = @import("../../agent/turn.zig");

pub const OllamaTransport = struct {
    ollama: *ollama_provider.OllamaProvider,
    io: std.Io,
    mcp: ?*mcp_registry.Registry,

    pub fn transport(self: *OllamaTransport) turn.Transport {
        return .{
            .ptr = self,
            .complete_turn = completeTurn,
            .append_user_text = appendUserTurn,
            .append_tool_call = appendAssistantToolCall,
            .append_tool_result = appendToolResult,
        };
    }

    pub fn declarationsJson(self: *const OllamaTransport, allocator: std.mem.Allocator) ![]const u8 {
        const gemini_declarations = blk: {
            if (self.mcp) |reg| break :blk try reg.buildDeclarationsJson(allocator);
            break :blk try allocator.dupe(u8, tool_registry.native_declarations_json);
        };
        defer allocator.free(gemini_declarations);
        return tool_registry.geminiDeclarationsToOllama(allocator, gemini_declarations);
    }

    fn completeTurn(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        conversation_json: []const u8,
        tool_declarations_json: []const u8,
    ) turn.TransportError!turn.Completion {
        const self: *OllamaTransport = @ptrCast(@alignCast(ptr));
        const response_body = fetchChat(self.ollama, allocator, self.io, conversation_json, tool_declarations_json) catch return error.ProviderFailed;
        defer allocator.free(response_body);
        return try parseCompletion(allocator, response_body);
    }

    fn appendUserTurn(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        conversation: *std.ArrayList(u8),
        text: []const u8,
    ) turn.TransportError!void {
        _ = ptr;
        if (conversation.items.len > 0) try conversation.append(allocator, ',');
        const escaped = try jsonString(allocator, text);
        defer allocator.free(escaped);
        const piece = try std.fmt.allocPrint(allocator, "{{\"role\":\"user\",\"content\":{s}}}", .{escaped});
        defer allocator.free(piece);
        try conversation.appendSlice(allocator, piece);
    }

    fn appendAssistantToolCall(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        conversation: *std.ArrayList(u8),
        call: tool_args.ToolCall,
    ) turn.TransportError!void {
        _ = ptr;
        if (conversation.items.len > 0) try conversation.append(allocator, ',');
        var piece: std.ArrayList(u8) = .empty;
        errdefer piece.deinit(allocator);
        try piece.appendSlice(allocator, "{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"function\":{\"name\":\"");
        try piece.appendSlice(allocator, call.name);
        try piece.appendSlice(allocator, "\",\"arguments\":");
        try piece.appendSlice(allocator, call.args_json);
        try piece.appendSlice(allocator, "}}]}");
        try conversation.appendSlice(allocator, piece.items);
    }

    fn appendToolResult(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        conversation: *std.ArrayList(u8),
        tool_name: []const u8,
        result: []const u8,
    ) turn.TransportError!void {
        _ = ptr;
        if (conversation.items.len > 0) try conversation.append(allocator, ',');
        const escaped = try jsonString(allocator, result);
        defer allocator.free(escaped);
        const piece = try std.fmt.allocPrint(allocator, "{{\"role\":\"tool\",\"name\":\"{s}\",\"content\":{s}}}", .{ tool_name, escaped });
        defer allocator.free(piece);
        try conversation.appendSlice(allocator, piece);
    }
};

fn trimTrailingSlash(url: []const u8) []const u8 {
    var end = url.len;
    while (end > 0 and url[end - 1] == '/') end -= 1;
    return url[0..end];
}

fn fetchChat(
    ollama: *ollama_provider.OllamaProvider,
    allocator: std.mem.Allocator,
    io: std.Io,
    messages_body: []const u8,
    tools_json: []const u8,
) ![]u8 {
    const trimmed = trimTrailingSlash(ollama.base_url);
    const endpoint = try std.fmt.allocPrint(allocator, "{s}/api/chat", .{trimmed});
    defer allocator.free(endpoint);

    const payload = try std.fmt.allocPrint(allocator,
        \\{{"model":"{s}","messages":[{s}],"tools":{s},"stream":false}}
    , .{ ollama.model_name, messages_body, tools_json });
    defer allocator.free(payload);

    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    var response_alloc = std.Io.Writer.Allocating.init(allocator);
    defer response_alloc.deinit();

    const result = client.fetch(.{
        .location = .{ .url = endpoint },
        .method = .POST,
        .payload = payload,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .response_writer = &response_alloc.writer,
    }) catch return error.ProviderFailed;

    if (result.status != .ok) return error.ProviderFailed;
    return try allocator.dupe(u8, response_alloc.writer.buffer[0..response_alloc.writer.end]);
}

fn parseCompletion(allocator: std.mem.Allocator, body: []const u8) turn.TransportError!turn.Completion {
    const Root = struct {
        message: ?struct {
            content: ?[]const u8 = null,
            tool_calls: ?[]struct {
                function: struct {
                    name: []const u8,
                    arguments: std.json.Value,
                },
            } = null,
        } = null,
    };

    var parsed = std.json.parseFromSlice(Root, allocator, body, .{ .ignore_unknown_fields = true }) catch return error.MalformedResponse;
    defer parsed.deinit();

    const message = parsed.value.message orelse return error.MalformedResponse;

    if (message.tool_calls) |calls| {
        if (calls.len == 0) return error.MalformedResponse;
        const first = calls[0];
        const args_owned = std.json.Stringify.valueAlloc(allocator, first.function.arguments, .{}) catch return error.MalformedResponse;
        return .{ .tool_call = .{
            .name = try allocator.dupe(u8, first.function.name),
            .args_json = args_owned,
        } };
    }

    const content = message.content orelse return error.MalformedResponse;
    return .{ .text = try allocator.dupe(u8, content) };
}

fn jsonString(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.append(allocator, '"');
    for (text) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, c),
        }
    }
    try out.append(allocator, '"');
    return try out.toOwnedSlice(allocator);
}
