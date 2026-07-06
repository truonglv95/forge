const std = @import("std");
const kernel = @import("forge-kernel");
const tool_registry = @import("../../tools/registry.zig");
const tool_args = @import("../../tools/args.zig");
const mcp_registry = @import("../../mcp_registry.zig");
const turn = @import("../../agent/turn.zig");
const streaming = @import("../../streaming.zig");

pub const FakeTransport = struct {
    mcp: ?*mcp_registry.Registry,
    short_script: bool = false,
    stream_callback: ?*const fn (?*anyopaque, []const u8) void = null,
    stream_context: ?*anyopaque = null,

    pub fn transport(self: *FakeTransport) turn.Transport {
        return .{
            .ptr = self,
            .complete_turn = completeTurn,
            .append_user_text = appendUserTurn,
            .append_tool_call = appendModelFunctionCall,
            .append_tool_result = appendFunctionResponse,
        };
    }

    pub fn declarationsJson(self: *const FakeTransport, allocator: std.mem.Allocator) ![]const u8 {
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
        const self: *FakeTransport = @ptrCast(@alignCast(ptr));
        _ = tool_declarations_json;
        if (cancel_token) |token| {
            if (token.isCancelled()) return error.Cancelled;
        }

        const response_count = countFunctionResponses(conversation_json);
        if (self.short_script) {
            return switch (response_count) {
                0 => .{ .tool_call = .{
                    .name = try allocator.dupe(u8, "search"),
                    .args_json = try allocator.dupe(u8, "{\"term\":\"sample\"}"),
                } },
                else => return try emitTextCompletion(allocator, "Exploration complete.", cancel_token, self),
            };
        }

        return switch (response_count) {
            0 => .{ .tool_call = .{
                .name = try allocator.dupe(u8, "search"),
                .args_json = try allocator.dupe(u8, "{\"term\":\"sample\"}"),
            } },
            1 => .{ .tool_call = .{
                .name = try allocator.dupe(u8, "list_tree"),
                .args_json = try allocator.dupe(u8, "{}"),
            } },
            else => return try emitTextCompletion(allocator, "Exploration complete.", cancel_token, self),
        };
    }

    fn emitTextCompletion(
        allocator: std.mem.Allocator,
        text: []const u8,
        cancel_token: ?*const kernel.cancellation.CancellationToken,
        self: *const FakeTransport,
    ) turn.TransportError!turn.Completion {
        if (cancel_token) |token| {
            if (self.stream_callback) |callback| {
                streaming.emitChunks(text, token, .{
                    .on_chunk = callback,
                    .on_chunk_context = self.stream_context,
                }) catch return error.ProviderFailed;
            }
        } else if (self.stream_callback) |callback| {
            callback(self.stream_context, text);
        }
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

fn countFunctionResponses(conversation_json: []const u8) usize {
    const needle = "functionResponse";
    var count: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, conversation_json, start, needle)) |idx| {
        count += 1;
        start = idx + needle.len;
    }
    return count;
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
