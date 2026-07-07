const std = @import("std");
const kernel = @import("forge-kernel");
const tool_args = @import("../tools/args.zig");

pub const ToolCall = tool_args.ToolCall;

pub const Completion = union(enum) {
    text: []u8,
    tool_call: ToolCall,

    pub fn deinit(self: *Completion, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text => |text| allocator.free(text),
            .tool_call => |*call| call.deinit(allocator),
        }
        self.* = undefined;
    }
};

/// Provider adapter: one model turn given serialized conversation state.
pub const Transport = struct {
    ptr: *anyopaque,
    complete_turn: *const fn (
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        conversation_json: []const u8,
        tool_declarations_json: []const u8,
        cancel_token: ?*const kernel.cancellation.CancellationToken,
    ) TransportError!Completion,
    append_user_text: *const fn (
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        conversation: *std.ArrayList(u8),
        text: []const u8,
    ) TransportError!void,
    append_tool_call: *const fn (
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        conversation: *std.ArrayList(u8),
        call: ToolCall,
    ) TransportError!void,
    append_tool_result: *const fn (
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        conversation: *std.ArrayList(u8),
        tool_name: []const u8,
        result: []const u8,
    ) TransportError!void,

    pub fn complete(
        self: Transport,
        allocator: std.mem.Allocator,
        conversation_json: []const u8,
        tool_declarations_json: []const u8,
        cancel_token: ?*const kernel.cancellation.CancellationToken,
    ) TransportError!Completion {
        return self.complete_turn(self.ptr, allocator, conversation_json, tool_declarations_json, cancel_token);
    }

    pub fn appendUserText(self: Transport, allocator: std.mem.Allocator, conversation: *std.ArrayList(u8), text: []const u8) TransportError!void {
        return self.append_user_text(self.ptr, allocator, conversation, text);
    }

    pub fn appendToolCall(self: Transport, allocator: std.mem.Allocator, conversation: *std.ArrayList(u8), call: ToolCall) TransportError!void {
        return self.append_tool_call(self.ptr, allocator, conversation, call);
    }

    pub fn appendToolResult(self: Transport, allocator: std.mem.Allocator, conversation: *std.ArrayList(u8), tool_name: []const u8, result: []const u8) TransportError!void {
        return self.append_tool_result(self.ptr, allocator, conversation, tool_name, result);
    }
};

pub const TransportError = error{
    Cancelled,
    ProviderFailed,
    AuthenticationFailed,
    RateLimitExceeded,
    ContextLengthExceeded,
    NetworkError,
    MalformedResponse,
    OutOfMemory,
};
