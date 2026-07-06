const std = @import("std");
const ollama_provider = @import("../../ollama_provider.zig");
const tool_registry = @import("../../tools/registry.zig");
const tool_args = @import("../../tools/args.zig");
const mcp_registry = @import("../../mcp_registry.zig");
const turn = @import("../../agent/turn.zig");
const kernel = @import("forge-kernel");
const ollama_ndjson = @import("../../ollama_ndjson.zig");

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
        cancel_token: ?*const kernel.cancellation.CancellationToken,
    ) turn.TransportError!turn.Completion {
        const self: *OllamaTransport = @ptrCast(@alignCast(ptr));
        if (cancel_token) |token| {
            if (token.isCancelled()) return error.Cancelled;
        }

        var bridge = StreamBridge{ .ollama = self.ollama };
        var parser = ollama_ndjson.Parser.init(allocator, .{
            .on_chunk = StreamBridge.onChunk,
            .context = &bridge,
        });
        defer parser.deinit();

        fetchStreamChatInto(self.ollama, allocator, self.io, conversation_json, tool_declarations_json, cancel_token, &parser) catch |err| switch (err) {
            error.Cancelled => return error.Cancelled,
            else => return error.ProviderFailed,
        };
        parser.finish() catch return error.MalformedResponse;
        if (parser.terminal_error) |_| return error.ProviderFailed;

        self.ollama.latest_usage = parser.latest_usage;

        if (parser.takeToolCall()) |call| {
            return .{ .tool_call = .{
                .name = call.name,
                .args_json = call.args_json,
            } };
        }

        const text = parser.assembledText();
        if (text.len == 0) return error.MalformedResponse;
        return .{ .text = try allocator.dupe(u8, text) };
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

const StreamBridge = struct {
    ollama: *ollama_provider.OllamaProvider,

    fn onChunk(context: ?*anyopaque, chunk: []const u8) void {
        const bridge: *StreamBridge = @ptrCast(@alignCast(context.?));
        if (bridge.ollama.stream_callback) |callback| {
            callback(bridge.ollama.stream_context, chunk);
        }
    }
};

fn trimTrailingSlash(url: []const u8) []const u8 {
    var end = url.len;
    while (end > 0 and url[end - 1] == '/') end -= 1;
    return url[0..end];
}

fn fetchStreamChatInto(
    ollama: *ollama_provider.OllamaProvider,
    allocator: std.mem.Allocator,
    io: std.Io,
    messages_body: []const u8,
    tools_json: []const u8,
    cancel_token: ?*const kernel.cancellation.CancellationToken,
    parser: *ollama_ndjson.Parser,
) !void {
    if (cancel_token) |token| {
        if (token.isCancelled()) return error.Cancelled;
    }

    const trimmed = trimTrailingSlash(ollama.base_url);
    const endpoint = try std.fmt.allocPrint(allocator, "{s}/api/chat", .{trimmed});
    defer allocator.free(endpoint);

    const payload = try std.fmt.allocPrint(allocator,
        \\{{"model":"{s}","messages":[{s}],"tools":{s},"stream":true}}
    , .{ ollama.model_name, messages_body, tools_json });
    defer allocator.free(payload);

    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    const result = client.fetch(.{
        .location = .{ .url = endpoint },
        .method = .POST,
        .payload = payload,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .response_writer = parser.ioWriter(),
    }) catch return error.ProviderFailed;

    parser.releaseWriter();

    if (result.status != .ok) return error.ProviderFailed;
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
