const std = @import("std");
const kernel = @import("forge-kernel");
const context = @import("../context.zig");
const context_manifest = @import("../context_manifest.zig");
const mcp_registry = @import("../mcp_registry.zig");
const provider = @import("../provider.zig");
const routing = @import("../routing.zig");
const tools = @import("../tools.zig");
const tool_executor = @import("../tool_executor.zig");
const tool_registry = @import("../tools/registry.zig");
const agent_loop = @import("loop.zig");
const turn = @import("turn.zig");

pub const Error = error{
    Unsupported,
    Cancelled,
    ProviderFailed,
    AuthenticationFailed,
    RateLimitExceeded,
    ContextLengthExceeded,
    NetworkError,
    StepLimitReached,
    DuplicateLoop,
    NoProgress,
};

pub const Input = struct {
    io: std.Io,
    llm: provider.Provider,
    mcp: *mcp_registry.Registry,
    intent: []const u8,
    ctx_builder: *const context.ContextBuilder,
    tool_ctx: tool_executor.Context,
    profile: tools.CapabilityProfile,
    task_intent: routing.TaskIntent,
    max_steps: u32,
    cancel_token: ?*const kernel.cancellation.CancellationToken = null,
    turn_callback: ?agent_loop.TurnCallback = null,
    turn_context: ?*anyopaque = null,
    step_begin_callback: ?agent_loop.StepBeginCallback = null,
    step_begin_context: ?*anyopaque = null,
    step_callback: ?agent_loop.StepCallback = null,
    step_context: ?*anyopaque = null,
    checkpoint_callback: ?agent_loop.CheckpointCallback = null,
    checkpoint_context: ?*anyopaque = null,
    initial_conversation_json: []const u8 = "",
    initial_step_index: u32 = 1,
    pending_tool: []const u8 = "",
    pending_args_json: []const u8 = "",
    approval_callback: ?agent_loop.ApprovalCallback = null,
    approval_context: ?*anyopaque = null,
    approve_every_time_tools: bool = false,
    max_context_recovery_attempts: u8 = 2,
};

pub fn runTransport(
    allocator: std.mem.Allocator,
    transport: turn.Transport,
    declarations: []const u8,
    intent: []const u8,
    ctx_builder: *const context.ContextBuilder,
    tool_ctx: tool_executor.Context,
    mcp: ?*mcp_registry.Registry,
    config: agent_loop.Config,
) Error!agent_loop.RunState {
    return agent_loop.run(allocator, transport, declarations, intent, ctx_builder, tool_ctx, mcp, config) catch |err| switch (err) {
        error.Cancelled => return error.Cancelled,
        error.AuthenticationFailed => return error.AuthenticationFailed,
        error.RateLimitExceeded => return error.RateLimitExceeded,
        error.ContextLengthExceeded => return error.ContextLengthExceeded,
        error.NetworkError => return error.NetworkError,
        error.StepLimitReached => return error.StepLimitReached,
        error.DuplicateLoop => return error.DuplicateLoop,
        error.NoProgress => return error.NoProgress,
        else => return error.ProviderFailed,
    };
}

pub fn runNative(
    allocator: std.mem.Allocator,
    input: Input,
) Error!?agent_loop.RunState {
    const caps = input.llm.capabilities();
    if (!caps.tool_calls) return null;

    var tool_binding = input.llm.toolLoopBinding(input.io, input.mcp, input.cancel_token);
    const raw_declarations = input.llm.toolDeclarationsJson(allocator, input.mcp) catch return error.ProviderFailed;
    defer allocator.free(raw_declarations);

    const preloaded_retrieval = context_manifest.hasPreloadedRetrieval(input.ctx_builder);
    const declarations = routing.filterDeclarationsForRoute(
        allocator,
        raw_declarations,
        input.profile,
        input.task_intent,
        input.intent,
        preloaded_retrieval,
    ) catch return error.ProviderFailed;
    defer allocator.free(declarations);

    const state = try runTransport(
        allocator,
        tool_binding.transport(),
        declarations,
        input.intent,
        input.ctx_builder,
        input.tool_ctx,
        input.mcp,
        .{
            .max_tool_steps = input.max_steps,
            .cancel_token = input.cancel_token,
            .turn_callback = input.turn_callback,
            .turn_context = input.turn_context,
            .step_begin_callback = input.step_begin_callback,
            .step_begin_context = input.step_begin_context,
            .step_callback = input.step_callback,
            .step_context = input.step_context,
            .checkpoint_callback = input.checkpoint_callback,
            .checkpoint_context = input.checkpoint_context,
            .initial_conversation_json = input.initial_conversation_json,
            .initial_step_index = input.initial_step_index,
            .pending_tool = input.pending_tool,
            .pending_args_json = input.pending_args_json,
            .approval_callback = input.approval_callback,
            .approval_context = input.approval_context,
            .approve_every_time_tools = input.approve_every_time_tools,
            .task_intent = input.task_intent,
            .preloaded_retrieval = preloaded_retrieval,
            .max_context_recovery_attempts = input.max_context_recovery_attempts,
        },
    );
    return state;
}

pub fn mapError(err: Error) anyerror {
    return switch (err) {
        error.Unsupported => error.ProviderFailed,
        error.Cancelled => error.Cancelled,
        error.AuthenticationFailed => error.AuthenticationFailed,
        error.RateLimitExceeded => error.RateLimitExceeded,
        error.ContextLengthExceeded => error.ContextLengthExceeded,
        error.NetworkError => error.NetworkError,
        error.StepLimitReached => error.StepLimitReached,
        error.DuplicateLoop => error.DuplicateLoop,
        error.NoProgress => error.NoProgress,
        error.ProviderFailed => error.ProviderFailed,
    };
}
