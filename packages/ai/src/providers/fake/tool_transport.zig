const std = @import("std");
const kernel = @import("forge-kernel");
const tool_registry = @import("../../tools/registry.zig");
const tool_args = @import("../../tools/args.zig");
const mcp_registry = @import("../../mcp_registry.zig");
const turn = @import("../../agent/turn.zig");

pub const FakeTransport = struct {
    mcp: ?*mcp_registry.Registry,

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
        _ = ptr;
        _ = tool_declarations_json;
        if (cancel_token) |token| {
            if (token.isCancelled()) return error.Cancelled;
        }

        if (std.mem.indexOf(u8, conversation_json, "functionResponse") != null) {
            return .{ .text = try allocator.dupe(u8, "Exploration complete.") };
        }

        return .{ .tool_call = .{
            .name = try allocator.dupe(u8, "search"),
            .args_json = try allocator.dupe(u8, "{\"term\":\"sample\"}"),
        } };
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
