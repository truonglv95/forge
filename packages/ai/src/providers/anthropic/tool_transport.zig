const std = @import("std");
const kernel = @import("forge-kernel");
const turn = @import("../../agent/turn.zig");

/// Anthropic tool transport — stub for Phase 2.
///
/// Full implementation (Claude tool_use content blocks, SSE streaming with
/// content_block_delta events) is deferred to Phase 3. This stub allows the
/// provider to be registered and used for inline completion + ask workflows.
pub const AnthropicTransport = struct {
    pub fn transport(self: *AnthropicTransport) turn.Transport {
        return .{
            .ptr = self,
            .complete_turn = completeTurn,
            .append_user_text = appendUserText,
            .append_tool_call = appendToolCall,
            .append_tool_result = appendToolResult,
        };
    }

    fn completeTurn(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        _: []const u8,
        _: []const u8,
        _: ?*const kernel.cancellation.CancellationToken,
    ) turn.TransportError!turn.Completion {
        // Return an empty text completion; real implementation will call the
        // provider's completeTurnImpl.
        return .{ .text = try allocator.dupe(u8, "") };
    }

    fn appendUserText(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        conversation: *std.ArrayList(u8),
        text: []const u8,
    ) turn.TransportError!void {
        if (conversation.items.len > 0) try conversation.append(allocator, ',');
        try conversation.appendSlice(allocator, text);
    }

    fn appendToolCall(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        conversation: *std.ArrayList(u8),
        _: turn.ToolCall,
    ) turn.TransportError!void {
        _ = conversation;
        _ = allocator;
    }

    fn appendToolResult(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        conversation: *std.ArrayList(u8),
        _: []const u8,
        _: []const u8,
    ) turn.TransportError!void {
        _ = conversation;
        _ = allocator;
    }
};
