const std = @import("std");
const kernel = @import("forge-kernel");
const context = @import("../context.zig");
const tool_executor = @import("../tool_executor.zig");
const tool_registry = @import("../tools/registry.zig");
const tool_dispatch = @import("../tools/dispatch.zig");
const mcp_registry = @import("../mcp_registry.zig");
const subagent = @import("../subagent.zig");
const turn = @import("turn.zig");

pub const StepCallback = *const fn (?*anyopaque, u32, []const u8, []const u8) void;

pub const Config = struct {
    max_tool_steps: u32 = 6,
    cancel_token: ?*const kernel.cancellation.CancellationToken = null,
    step_callback: ?StepCallback = null,
    step_context: ?*anyopaque = null,
};

pub const LoopError = error{
    Cancelled,
    ProviderFailed,
    StepLimitReached,
    NotAllowed,
} || tool_dispatch.DispatchError;

/// Provider-agnostic tool loop. The transport adapts wire format per LLM backend.
pub fn run(
    allocator: std.mem.Allocator,
    transport: turn.Transport,
    tool_declarations_json: []const u8,
    intent: []const u8,
    ctx_builder: *const context.ContextBuilder,
    tool_ctx: tool_executor.Context,
    mcp: ?*mcp_registry.Registry,
    config: Config,
) LoopError!void {
    var conversation: std.ArrayList(u8) = .empty;
    defer conversation.deinit(allocator);

    var prompt = std.Io.Writer.Allocating.init(allocator);
    defer prompt.deinit();
    prompt.writer.print(
        "You are a coding agent. Explore the workspace using tools before proposing edits.\nIntent: {s}\n\nContext summary:\n",
        .{intent},
    ) catch return error.ProviderFailed;
    for (ctx_builder.blocks.items) |block| {
        prompt.writer.print("[{s}] {s}\n", .{ @tagName(block.block_type), block.name }) catch return error.ProviderFailed;
    }
    prompt.writer.writeAll("\nCall tools as needed. When you have enough information, respond with brief text only (no tool call).\n") catch return error.ProviderFailed;

    transport.appendUserText(allocator, &conversation, prompt.writer.buffer[0..prompt.writer.end]) catch return error.ProviderFailed;

    var step_index: u32 = 1;
    var turn_i: u32 = 0;
    while (turn_i < config.max_tool_steps) : (turn_i += 1) {
        if (config.cancel_token) |token| {
            if (token.isCancelled()) return error.Cancelled;
        }

        var completion = transport.complete(allocator, conversation.items, tool_declarations_json, config.cancel_token) catch |err| return switch (err) {
            error.Cancelled => error.Cancelled,
            else => error.ProviderFailed,
        };
        defer completion.deinit(allocator);

        switch (completion) {
            .tool_call => |call| {
                if (!tool_registry.isToolAllowed(call.name, tool_ctx.profile, mcp)) return error.NotAllowed;

                const summary = tool_dispatch.execute(allocator, tool_ctx, mcp, call) catch |err| return mapDispatch(err);
                defer allocator.free(summary);

                if (config.step_callback) |callback| {
                    const kind = subagent.classifyTool(call.name).label();
                    callback(config.step_context, step_index, kind, summary);
                }
                step_index += 1;

                transport.appendToolCall(allocator, &conversation, call) catch return error.ProviderFailed;
                transport.appendToolResult(allocator, &conversation, call.name, summary) catch return error.ProviderFailed;
            },
            .text => return,
        }
    }
    return error.StepLimitReached;
}

fn mapDispatch(err: tool_dispatch.DispatchError) LoopError {
    return switch (err) {
        error.Cancelled => error.Cancelled,
        error.NotAllowed => error.NotAllowed,
        else => error.ProviderFailed,
    };
}
