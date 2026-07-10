const std = @import("std");
const gemini_provider = @import("provider.zig");
const tool_registry = @import("../../tools/registry.zig");
const tool_args = @import("../../tools/args.zig");
const mcp_registry = @import("../../mcp_registry.zig");
const turn = @import("../../agent/turn.zig");
const kernel = @import("forge-kernel");
const gemini_sse = @import("sse.zig");

const stream_endpoint_base = "https://generativelanguage.googleapis.com/v1beta/models/";

pub const GeminiTransport = struct {
    gemini: *gemini_provider.GeminiProvider,
    io: std.Io,
    mcp: ?*mcp_registry.Registry,

    pub fn transport(self: *GeminiTransport) turn.Transport {
        return .{
            .ptr = self,
            .complete_turn = completeTurn,
            .append_user_text = appendUserTurn,
            .append_tool_call = appendModelFunctionCall,
            .append_tool_result = appendFunctionResponse,
        };
    }

    pub fn declarationsJson(self: *const GeminiTransport, allocator: std.mem.Allocator) ![]const u8 {
        if (self.mcp) |reg| {
            return reg.buildDeclarationsJson(allocator);
        }
        return try allocator.dupe(u8, tool_registry.native_declarations_json);
    }

    fn completeTurn(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        conversation_json: []const u8,
        tool_declarations_json: []const u8,
        cancel_token: ?*const kernel.cancellation.CancellationToken,
    ) turn.TransportError!turn.Completion {
        const self: *GeminiTransport = @ptrCast(@alignCast(ptr));
        if (cancel_token) |token| {
            if (token.isCancelled()) return error.Cancelled;
        }

        var bridge = SseBridge{ .gemini = self.gemini };
        var parser = gemini_sse.Parser.init(allocator, .{
            .on_chunk = SseBridge.onChunk,
            .context = &bridge,
        });
        defer parser.deinit();

        fetchStreamGenerateContentInto(self.gemini, allocator, self.io, conversation_json, tool_declarations_json, cancel_token, &parser) catch |err| return switch (err) {
            error.Cancelled => error.Cancelled,
            error.AuthenticationFailed => error.AuthenticationFailed,
            error.RateLimitExceeded => error.RateLimitExceeded,
            error.ContextLengthExceeded => error.ContextLengthExceeded,
            error.NetworkError => error.NetworkError,
            else => error.ProviderFailed,
        };
        parser.finish() catch return error.MalformedResponse;
        if (parser.terminal_error) |_| return error.ProviderFailed;

        self.gemini.latest_usage = parser.latest_usage;

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
        const piece = try std.fmt.allocPrint(allocator, "{{\"role\":\"user\",\"parts\":[{{\"text\":{s}}}]}}", .{escaped});
        defer allocator.free(piece);
        try conversation.appendSlice(allocator, piece);
    }

    fn appendModelFunctionCall(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        conversation: *std.ArrayList(u8),
        call: tool_args.ToolCall,
    ) turn.TransportError!void {
        _ = ptr;
        if (conversation.items.len > 0) try conversation.append(allocator, ',');
        const piece = try std.fmt.allocPrint(allocator, "{{\"role\":\"model\",\"parts\":[{{\"functionCall\":{{\"name\":\"{s}\",\"args\":{s}}}}}]}}", .{ call.name, call.args_json });
        defer allocator.free(piece);
        try conversation.appendSlice(allocator, piece);
    }

    fn appendFunctionResponse(
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
        const piece = try std.fmt.allocPrint(allocator, "{{\"role\":\"user\",\"parts\":[{{\"functionResponse\":{{\"name\":\"{s}\",\"response\":{{\"output\":{s}}}}}}}]}}", .{ tool_name, escaped });
        defer allocator.free(piece);
        try conversation.appendSlice(allocator, piece);
    }
};

const SseBridge = struct {
    gemini: *gemini_provider.GeminiProvider,

    fn onChunk(context: ?*anyopaque, kind: gemini_sse.ChunkKind, chunk: []const u8) void {
        const bridge: *SseBridge = @ptrCast(@alignCast(context.?));
        switch (kind) {
            .thought => if (bridge.gemini.thinking_callback) |callback| {
                callback(bridge.gemini.thinking_context, chunk);
            },
            .text => if (bridge.gemini.stream_callback) |callback| {
                callback(bridge.gemini.stream_context, chunk);
            },
        }
    }
};

fn fetchStreamGenerateContentInto(
    gemini: *gemini_provider.GeminiProvider,
    allocator: std.mem.Allocator,
    io: std.Io,
    contents_body: []const u8,
    declarations_json: []const u8,
    cancel_token: ?*const kernel.cancellation.CancellationToken,
    parser: *gemini_sse.Parser,
) !void {
    if (cancel_token) |token| {
        if (token.isCancelled()) return error.Cancelled;
    }

    const endpoint = try std.fmt.allocPrint(allocator, "{s}{s}:streamGenerateContent?alt=sse", .{ stream_endpoint_base, gemini.model_name });
    defer allocator.free(endpoint);

    const payload = try std.fmt.allocPrint(allocator,
        \\{{"contents":[{s}],"tools":[{{"functionDeclarations":{s}}}],"generationConfig":{{"temperature":0.2,"thinkingConfig":{{"includeThoughts":true}}}}}}
    , .{ contents_body, declarations_json });
    defer allocator.free(payload);

    const api_headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "x-goog-api-key", .value = gemini.creds.api_key },
    };

    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    const result = client.fetch(.{
        .location = .{ .url = endpoint },
        .method = .POST,
        .payload = payload,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .extra_headers = &api_headers,
        .response_writer = parser.ioWriter(),
    }) catch return error.NetworkError;

    parser.releaseWriter();

    if (result.status != .ok) {
        return switch (result.status) {
            .unauthorized, .forbidden => error.AuthenticationFailed,
            .too_many_requests => error.RateLimitExceeded,
            .bad_request, .payload_too_large => error.ContextLengthExceeded,
            else => error.ProviderFailed,
        };
    }
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

test "jsonString escapes quotes" {
    const allocator = std.testing.allocator;
    const s = try jsonString(allocator, "say \"hi\"\n");
    defer allocator.free(s);
    try std.testing.expectEqualStrings("\"say \\\"hi\\\"\\n\"", s);
}
