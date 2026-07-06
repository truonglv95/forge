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
pub const StepBeginCallback = *const fn (?*anyopaque, u32, []const u8) void;
pub const TurnCallback = *const fn (?*anyopaque, u32) void;
pub const CheckpointCallback = *const fn (
    ?*anyopaque,
    conversation_json: []const u8,
    next_step_index: u32,
    pending_tool: []const u8,
    pending_args_json: []const u8,
) bool;
pub const ApprovalCallback = *const fn (
    ?*anyopaque,
    tool_name: []const u8,
    args_json: []const u8,
    policy: tool_registry.Policy,
) bool;

pub const Config = struct {
    max_tool_steps: u32 = 6,
    cancel_token: ?*const kernel.cancellation.CancellationToken = null,
    turn_callback: ?TurnCallback = null,
    turn_context: ?*anyopaque = null,
    step_begin_callback: ?StepBeginCallback = null,
    step_begin_context: ?*anyopaque = null,
    step_callback: ?StepCallback = null,
    step_context: ?*anyopaque = null,
    checkpoint_callback: ?CheckpointCallback = null,
    checkpoint_context: ?*anyopaque = null,
    initial_conversation_json: []const u8 = "",
    initial_step_index: u32 = 1,
    pending_tool: []const u8 = "",
    pending_args_json: []const u8 = "",
    approval_callback: ?ApprovalCallback = null,
    approval_context: ?*anyopaque = null,
    approve_every_time_tools: bool = false,
};

pub const RunState = struct {
    conversation_json: []u8,
    next_step_index: u32,
    final_text: ?[]u8 = null,

    pub fn deinit(self: *RunState, allocator: std.mem.Allocator) void {
        allocator.free(self.conversation_json);
        if (self.final_text) |text| allocator.free(text);
        self.* = undefined;
    }
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
) LoopError!RunState {
    var conversation: std.ArrayList(u8) = .empty;
    defer conversation.deinit(allocator);

    var prompt = std.Io.Writer.Allocating.init(allocator);
    defer prompt.deinit();
    prompt.writer.print(
        "You are a coding agent. Explore the workspace using tools before answering.\n" ++
            "Use search, list_tree, and read_file to gather facts. Do not guess file contents.\n" ++
            "Call tools as needed. Only respond with plain text when you have enough evidence.\n" ++
            "Intent: {s}\n\nContext summary:\n",
        .{intent},
    ) catch return error.ProviderFailed;
    for (ctx_builder.blocks.items) |block| {
        prompt.writer.print("[{s}] {s}\n", .{ @tagName(block.block_type), block.name }) catch return error.ProviderFailed;
    }

    if (config.initial_conversation_json.len > 0) {
        conversation.appendSlice(allocator, config.initial_conversation_json) catch return error.ProviderFailed;
    } else {
        transport.appendUserText(allocator, &conversation, prompt.writer.buffer[0..prompt.writer.end]) catch return error.ProviderFailed;
    }

    var step_index: u32 = config.initial_step_index;
    if (config.pending_tool.len > 0) {
        const pending_call = turn.ToolCall{
            .name = @constCast(config.pending_tool),
            .args_json = @constCast(config.pending_args_json),
        };
        try executeTool(allocator, transport, &conversation, pending_call, tool_ctx, mcp, config, step_index, false);
        step_index += 1;
    }

    var turn_i: u32 = 0;
    while (turn_i < config.max_tool_steps) : (turn_i += 1) {
        if (config.cancel_token) |token| {
            if (token.isCancelled()) return error.Cancelled;
        }

        if (config.turn_callback) |callback| {
            callback(config.turn_context, step_index);
        }

        var completion = transport.complete(allocator, conversation.items, tool_declarations_json, config.cancel_token) catch |err| return switch (err) {
            error.Cancelled => error.Cancelled,
            else => error.ProviderFailed,
        };
        defer completion.deinit(allocator);

        switch (completion) {
            .tool_call => |call| {
                try executeTool(allocator, transport, &conversation, call, tool_ctx, mcp, config, step_index, true);
                step_index += 1;
            },
            .text => return .{
                .conversation_json = conversation.toOwnedSlice(allocator) catch return error.ProviderFailed,
                .next_step_index = step_index,
                .final_text = allocator.dupe(u8, completion.text) catch return error.ProviderFailed,
            },
        }
    }
    return error.StepLimitReached;
}

fn executeTool(
    allocator: std.mem.Allocator,
    transport: turn.Transport,
    conversation: *std.ArrayList(u8),
    call: turn.ToolCall,
    tool_ctx: tool_executor.Context,
    mcp: ?*mcp_registry.Registry,
    config: Config,
    step_index: u32,
    append_call: bool,
) LoopError!void {
    if (!tool_registry.isToolAllowed(call.name, tool_ctx.profile, mcp)) return error.NotAllowed;
    if (config.step_begin_callback) |callback| callback(config.step_begin_context, step_index, call.name);

    if (append_call) transport.appendToolCall(allocator, conversation, call) catch return error.ProviderFailed;
    if (config.checkpoint_callback) |checkpoint| {
        if (!checkpoint(config.checkpoint_context, conversation.items, step_index, call.name, call.args_json)) return error.ProviderFailed;
    }

    const policy = tool_registry.policyFor(call.name);
    if (policy.approval == .every_time or policy.approval == .review) {
        if (config.approval_callback) |approve| {
            if (!approve(config.approval_context, call.name, call.args_json, policy)) return error.NotAllowed;
        } else if (policy.approval == .every_time and !config.approve_every_time_tools) {
            return error.NotAllowed;
        } else if (policy.approval == .review) {
            return error.NotAllowed;
        }
    }

    const summary = tool_dispatch.execute(allocator, tool_ctx, mcp, call) catch |err| return mapDispatch(err);
    defer allocator.free(summary);
    transport.appendToolResult(allocator, conversation, call.name, summary) catch return error.ProviderFailed;

    if (config.step_callback) |callback| {
        const kind = subagent.classifyTool(call.name).label();
        callback(config.step_context, step_index, kind, summary);
    }
    if (config.checkpoint_callback) |checkpoint| {
        if (!checkpoint(config.checkpoint_context, conversation.items, step_index + 1, "", "")) return error.ProviderFailed;
    }
}

fn mapDispatch(err: tool_dispatch.DispatchError) LoopError {
    return switch (err) {
        error.Cancelled => error.Cancelled,
        error.NotAllowed => error.NotAllowed,
        else => error.ProviderFailed,
    };
}
