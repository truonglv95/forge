const std = @import("std");
const core_provider = @import("../../provider.zig");
const nvidia_provider = @import("provider.zig");
const openai_sse = @import("../openai/sse.zig");
const tool_registry = @import("../../tools/registry.zig");
const tool_args = @import("../../tools/args.zig");
const mcp_registry = @import("../../mcp_registry.zig");
const turn = @import("../../agent/turn.zig");
const kernel = @import("forge-kernel");

pub const NvidiaTransport = struct {
    nvidia: *nvidia_provider.NvidiaProvider,
    io: std.Io,
    mcp: ?*mcp_registry.Registry,

    pub fn transport(self: *NvidiaTransport) turn.Transport {
        return .{
            .ptr = self,
            .complete_turn = completeTurn,
            .append_user_text = appendUserTurn,
            .append_tool_call = appendAssistantToolCall,
            .append_tool_result = appendToolResult,
        };
    }

    pub fn declarationsJson(self: *const NvidiaTransport, allocator: std.mem.Allocator) ![]const u8 {
        if (self.mcp) |reg| return reg.buildDeclarationsJson(allocator);
        return try allocator.dupe(u8, tool_registry.native_declarations_json);
    }

    fn completeTurn(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        conversation_json: []const u8,
        tool_declarations_json: []const u8,
        cancel_token: ?*const kernel.cancellation.CancellationToken,
    ) turn.TransportError!turn.Completion {
        const self: *NvidiaTransport = @ptrCast(@alignCast(ptr));
        if (cancel_token) |token| if (token.isCancelled()) return error.Cancelled;

        var bridge = StreamBridge{ .nvidia = self.nvidia };
        var parser = openai_sse.Parser.init(allocator, .{
            .on_chunk = StreamBridge.onChunk,
            .context = &bridge,
        });
        defer parser.deinit();

        fetchStreamChatInto(self.nvidia, allocator, self.io, conversation_json, tool_declarations_json, cancel_token, &parser) catch |err| return switch (err) {
            error.Cancelled => error.Cancelled,
            error.AuthenticationFailed => error.AuthenticationFailed,
            error.RateLimitExceeded => error.RateLimitExceeded,
            error.ContextLengthExceeded => error.ContextLengthExceeded,
            error.NetworkError => error.NetworkError,
            else => error.ProviderFailed,
        };
        parser.finish() catch return error.MalformedResponse;

        self.nvidia.latest_usage = parser.latest_usage;

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
        const args = if (validJson(allocator, call.args_json)) call.args_json else "{}";
        const args_escaped = try jsonString(allocator, args);
        defer allocator.free(args_escaped);
        const piece = try std.fmt.allocPrint(allocator,
            \\{{"role":"assistant","content":"","tool_calls":[{{"id":"{s}","type":"function","function":{{"name":"{s}","arguments":{s}}}}}]}}
        , .{ "forge_tool_call", call.name, args_escaped });
        defer allocator.free(piece);
        try conversation.appendSlice(allocator, piece);
    }

    fn appendToolResult(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        conversation: *std.ArrayList(u8),
        tool_name: []const u8,
        result: []const u8,
        images: []const core_provider.ImagePart,
    ) turn.TransportError!void {
        _ = ptr;
        _ = images;
        if (conversation.items.len > 0) try conversation.append(allocator, ',');
        const escaped = try jsonString(allocator, result);
        defer allocator.free(escaped);
        const piece = try std.fmt.allocPrint(allocator, "{{\"role\":\"tool\",\"tool_call_id\":\"forge_tool_call\",\"name\":\"{s}\",\"content\":{s}}}", .{ tool_name, escaped });
        defer allocator.free(piece);
        try conversation.appendSlice(allocator, piece);
    }
};

const StreamBridge = struct {
    nvidia: *nvidia_provider.NvidiaProvider,

    fn onChunk(context: ?*anyopaque, chunk: []const u8) void {
        const bridge: *StreamBridge = @ptrCast(@alignCast(context.?));
        if (bridge.nvidia.stream_callback) |callback| callback(bridge.nvidia.stream_context, chunk);
    }
};

fn fetchStreamChatInto(
    nvidia: *nvidia_provider.NvidiaProvider,
    allocator: std.mem.Allocator,
    io: std.Io,
    messages_body: []const u8,
    tools_json: []const u8,
    cancel_token: ?*const kernel.cancellation.CancellationToken,
    parser: *openai_sse.Parser,
) !void {
    if (cancel_token) |token| if (token.isCancelled()) return error.Cancelled;

    const endpoint = try nvidia_provider.buildChatEndpoint(allocator, nvidia.base_url);
    defer allocator.free(endpoint);

    const openai_tools = tool_registry.geminiDeclarationsToOllama(allocator, tools_json) catch return error.ProviderFailed;
    defer allocator.free(openai_tools);

    const model_escaped = try jsonString(allocator, nvidia.model_name);
    defer allocator.free(model_escaped);
    const payload = try std.fmt.allocPrint(allocator,
        \\{{"model":{s},"messages":[{s}],"tools":{s},"tool_choice":"auto","stream":true}}
    , .{ model_escaped, messages_body, openai_tools });
    defer allocator.free(payload);

    const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{nvidia.creds.api_key});
    defer allocator.free(auth);
    const headers = [_]std.http.Header{
        .{ .name = "Authorization", .value = auth },
        .{ .name = "HTTP-Referer", .value = "https://forge.local" },
        .{ .name = "X-Title", .value = "Forge" },
    };

    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    const result = client.fetch(.{
        .location = .{ .url = endpoint },
        .method = .POST,
        .payload = payload,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .extra_headers = &headers,
        .response_writer = parser.ioWriter(),
    }) catch return error.NetworkError;

    parser.releaseWriter();

    return switch (result.status) {
        .ok => {},
        .unauthorized, .forbidden => error.AuthenticationFailed,
        .too_many_requests => error.RateLimitExceeded,
        .payload_too_large, .uri_too_long, .bad_request => error.ContextLengthExceeded,
        .request_timeout, .service_unavailable, .bad_gateway, .gateway_timeout => error.NetworkError,
        else => error.ProviderFailed,
    };
}

fn validJson(allocator: std.mem.Allocator, text: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return false;
    parsed.deinit();
    return true;
}

fn jsonString(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
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

test "jsonString escapes model ids" {
    const value = try jsonString(std.testing.allocator, "openai/gpt-4o-mini");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("\"openai/gpt-4o-mini\"", value);
}
