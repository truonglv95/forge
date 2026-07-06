const std = @import("std");
const gemini_provider = @import("../../gemini_provider.zig");
const tool_registry = @import("../../tools/registry.zig");
const tool_args = @import("../../tools/args.zig");
const mcp_registry = @import("../../mcp_registry.zig");
const turn = @import("../../agent/turn.zig");

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
    ) turn.TransportError!turn.Completion {
        const self: *GeminiTransport = @ptrCast(@alignCast(ptr));
        const response_body = fetchGenerateContent(self.gemini, allocator, self.io, conversation_json, tool_declarations_json) catch return error.ProviderFailed;
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

fn fetchGenerateContent(
    gemini: *gemini_provider.GeminiProvider,
    allocator: std.mem.Allocator,
    io: std.Io,
    contents_body: []const u8,
    declarations_json: []const u8,
) ![]u8 {
    const endpoint = try std.fmt.allocPrint(allocator, "https://generativelanguage.googleapis.com/v1beta/models/{s}:generateContent", .{gemini.model_name});
    defer allocator.free(endpoint);

    const payload = try std.fmt.allocPrint(allocator,
        \\{{"contents":[{s}],"tools":[{{"functionDeclarations":{s}}}],"generationConfig":{{"temperature":0.2}}}}
    , .{ contents_body, declarations_json });
    defer allocator.free(payload);

    const api_headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "x-goog-api-key", .value = gemini.creds.api_key },
    };

    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    var response_alloc = std.Io.Writer.Allocating.init(allocator);
    defer response_alloc.deinit();

    const result = client.fetch(.{
        .location = .{ .url = endpoint },
        .method = .POST,
        .payload = payload,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .extra_headers = &api_headers,
        .response_writer = &response_alloc.writer,
    }) catch return error.ProviderFailed;

    if (result.status != .ok) return error.ProviderFailed;
    return try allocator.dupe(u8, response_alloc.writer.buffer[0..response_alloc.writer.end]);
}

fn parseCompletion(allocator: std.mem.Allocator, body: []const u8) turn.TransportError!turn.Completion {
    const Root = struct {
        candidates: ?[]struct {
            content: ?struct {
                parts: ?[]struct {
                    text: ?[]const u8 = null,
                    functionCall: ?struct {
                        name: ?[]const u8 = null,
                        args: ?std.json.Value = null,
                    } = null,
                } = null,
            } = null,
        } = null,
    };

    var parsed = std.json.parseFromSlice(Root, allocator, body, .{ .ignore_unknown_fields = true }) catch return error.MalformedResponse;
    defer parsed.deinit();

    const candidates = parsed.value.candidates orelse return error.MalformedResponse;
    if (candidates.len == 0) return error.MalformedResponse;
    const content = candidates[0].content orelse return error.MalformedResponse;
    const parts = content.parts orelse return error.MalformedResponse;
    if (parts.len == 0) return error.MalformedResponse;

    for (parts) |part| {
        if (part.functionCall) |fc| {
            const name = fc.name orelse return error.MalformedResponse;
            const args_owned = if (fc.args) |args_val|
                std.json.Stringify.valueAlloc(allocator, args_val, .{}) catch return error.MalformedResponse
            else
                allocator.dupe(u8, "{}") catch return error.MalformedResponse;
            return .{ .tool_call = .{
                .name = try allocator.dupe(u8, name),
                .args_json = args_owned,
            } };
        }
    }

    for (parts) |part| {
        if (part.text) |text| {
            return .{ .text = try allocator.dupe(u8, text) };
        }
    }
    return error.MalformedResponse;
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
