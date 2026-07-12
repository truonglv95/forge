const std = @import("std");
const kernel = @import("forge-kernel");
const context = @import("../context.zig");
const tool_executor = @import("../tool_executor.zig");
const tool_registry = @import("../tools/registry.zig");
const tool_dispatch = @import("../tools/dispatch.zig");
const mcp_registry = @import("../mcp_registry.zig");
const subagent = @import("../subagent.zig");
const tool_observation = @import("../tool_observation.zig");
const loop_prompt = @import("loop_prompt.zig");
const routing = @import("../routing.zig");
const turn = @import("turn.zig");
const compaction = @import("compaction.zig");

pub const StepCallback = *const fn (?*anyopaque, u32, []const u8, []const u8) void;
pub const StepBeginCallback = *const fn (?*anyopaque, u32, []const u8, []const u8) void;
pub const TurnCallback = *const fn (?*anyopaque, u32) void;
pub const CompactionCallback = *const fn (
    ?*anyopaque,
    reason: []const u8,
    before_bytes: usize,
    after_bytes: usize,
    step_index: u32,
    attempt: u8,
) void;
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
    compaction_callback: ?CompactionCallback = null,
    compaction_context: ?*anyopaque = null,
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
    task_intent: routing.TaskIntent = .explore_codebase,
    preloaded_retrieval: bool = false,
    max_context_recovery_attempts: u8 = 3,
    max_conversation_bytes: usize = 256 * 1024,
    max_conversation_compactions: u8 = 4,
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
    AuthenticationFailed,
    RateLimitExceeded,
    ContextLengthExceeded,
    NetworkError,
    StepLimitReached,
    DuplicateLoop,
    NoProgress,
    NotAllowed,
} || tool_dispatch.DispatchError;

const LoopGuard = struct {
    const window: usize = 32;

    seen: [window]u64 = .{0} ** window,
    cursor: usize = 0,
    filled: usize = 0,

    consecutive_non_evidence: u8 = 0,

    fn noteToolCall(self: *LoopGuard, tool_name: []const u8, args_json: []const u8) LoopError!void {
        const hash = callHash(tool_name, args_json);
        self.seen[self.cursor] = hash;
        self.cursor = (self.cursor + 1) % window;
        if (self.filled < window) self.filled += 1;

        if (isEvidenceTool(tool_name)) {
            self.consecutive_non_evidence = 0;
        } else if (isBroadTool(tool_name)) {
            self.consecutive_non_evidence +|= 1;
            if (self.consecutive_non_evidence >= 8) self.consecutive_non_evidence = 0;
        }
    }
};

fn callHash(tool_name: []const u8, args_json: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(tool_name);
    hasher.update("\n");
    const trimmed = std.mem.trim(u8, args_json, &std.ascii.whitespace);
    hasher.update(trimmed);
    return hasher.final();
}

fn isEvidenceTool(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, "read_file");
}

fn isBroadTool(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, "search") or
        std.mem.eql(u8, tool_name, "codebase_search") or
        std.mem.eql(u8, tool_name, "list_tree");
}

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

    var guard = LoopGuard{};

    const prompt = loop_prompt.buildExplorePrompt(allocator, intent, ctx_builder, .{
        .task_intent = config.task_intent,
        .preloaded_retrieval = config.preloaded_retrieval,
    }) catch return error.ProviderFailed;
    defer allocator.free(prompt);

    if (config.initial_conversation_json.len > 0) {
        conversation.appendSlice(allocator, config.initial_conversation_json) catch return error.ProviderFailed;
    } else {
        transport.appendUserText(allocator, &conversation, prompt) catch return error.ProviderFailed;
    }

    var step_index: u32 = config.initial_step_index;
    if (config.pending_tool.len > 0) {
        const pending_call = turn.ToolCall{
            .name = @constCast(config.pending_tool),
            .args_json = @constCast(config.pending_args_json),
        };
        try executeTool(allocator, transport, &conversation, pending_call, tool_ctx, mcp, config, &guard, step_index, false);
        step_index += 1;
    }

    var turn_i: u32 = 0;
    var malformed_repairs: u8 = 0;
    var context_recoveries: u8 = 0;
    var conversation_compactions: u8 = 0;
    while (turn_i < config.max_tool_steps) : (turn_i += 1) {
        if (config.cancel_token) |token| {
            if (token.isCancelled()) return error.Cancelled;
        }

        if (config.turn_callback) |callback| {
            callback(config.turn_context, step_index);
        }

        try compactConversationIfNeeded(allocator, transport, &conversation, intent, ctx_builder, config, step_index, &conversation_compactions);

        var completion = transport.complete(allocator, conversation.items, tool_declarations_json, config.cancel_token) catch |err| switch (err) {
            error.Cancelled => return error.Cancelled,
            error.AuthenticationFailed => return error.AuthenticationFailed,
            error.RateLimitExceeded => return error.RateLimitExceeded,
            error.ContextLengthExceeded => {
                if (context_recoveries >= config.max_context_recovery_attempts) return error.ContextLengthExceeded;
                context_recoveries += 1;
                const before_bytes = conversation.items.len;
                const recovery_prompt = compaction.buildRecoveryPrompt(
                    allocator,
                    intent,
                    ctx_builder,
                    conversation.items,
                    config.task_intent,
                    compaction.recoveryOptions(context_recoveries),
                ) catch return error.ProviderFailed;
                defer allocator.free(recovery_prompt);
                conversation.clearRetainingCapacity();
                transport.appendUserText(allocator, &conversation, recovery_prompt) catch return error.ProviderFailed;
                emitCompaction(config, "provider_context_length", before_bytes, conversation.items.len, step_index, context_recoveries);
                if (config.checkpoint_callback) |checkpoint| {
                    if (!checkpoint(config.checkpoint_context, conversation.items, step_index, "", "")) return error.ProviderFailed;
                }
                continue;
            },
            error.NetworkError => return error.NetworkError,
            error.MalformedResponse => {
                if (malformed_repairs >= 2) return error.ProviderFailed;
                malformed_repairs += 1;
                transport.appendUserText(
                    allocator,
                    &conversation,
                    "Your previous response was not valid for the tool loop. Reply with either plain answer text or a valid tool call using JSON object arguments. If a tool failed, try corrected arguments or use another evidence-gathering tool.",
                ) catch return error.ProviderFailed;
                continue;
            },
            else => return error.ProviderFailed,
        };
        defer completion.deinit(allocator);

        switch (completion) {
            .tool_call => |call| {
                try executeTool(allocator, transport, &conversation, call, tool_ctx, mcp, config, &guard, step_index, true);
                step_index += 1;
            },
            .text => return .{
                .conversation_json = conversation.toOwnedSlice(allocator) catch return error.ProviderFailed,
                .next_step_index = step_index,
                .final_text = allocator.dupe(u8, completion.text) catch return error.ProviderFailed,
            },
        }
    }
    try checkpointCompactResume(allocator, transport, &conversation, intent, ctx_builder, config, step_index);
    return error.StepLimitReached;
}

fn compactConversationIfNeeded(
    allocator: std.mem.Allocator,
    transport: turn.Transport,
    conversation: *std.ArrayList(u8),
    intent: []const u8,
    ctx_builder: *const context.ContextBuilder,
    config: Config,
    step_index: u32,
    compactions: *u8,
) LoopError!void {
    if (config.max_conversation_bytes == 0) return;
    if (conversation.items.len <= config.max_conversation_bytes) return;
    if (compactions.* >= config.max_conversation_compactions) return;

    const next_attempt = if (compactions.* == std.math.maxInt(u8)) compactions.* else compactions.* + 1;
    const before_bytes = conversation.items.len;
    const compact_prompt = compaction.buildResumePrompt(
        allocator,
        intent,
        ctx_builder,
        conversation.items,
        config.task_intent,
        step_index,
        compaction.recoveryOptions(next_attempt),
    ) catch return error.ProviderFailed;
    defer allocator.free(compact_prompt);

    conversation.clearRetainingCapacity();
    transport.appendUserText(allocator, conversation, compact_prompt) catch return error.ProviderFailed;
    compactions.* = next_attempt;
    emitCompaction(config, "conversation_budget", before_bytes, conversation.items.len, step_index, next_attempt);
    if (config.checkpoint_callback) |checkpoint| {
        if (!checkpoint(config.checkpoint_context, conversation.items, step_index, "", "")) return error.ProviderFailed;
    }
}

fn checkpointCompactResume(
    allocator: std.mem.Allocator,
    transport: turn.Transport,
    conversation: *std.ArrayList(u8),
    intent: []const u8,
    ctx_builder: *const context.ContextBuilder,
    config: Config,
    step_index: u32,
) LoopError!void {
    const checkpoint = config.checkpoint_callback orelse return;
    const checkpoint_attempt = if (config.max_context_recovery_attempts == std.math.maxInt(u8))
        config.max_context_recovery_attempts
    else
        config.max_context_recovery_attempts + 1;
    const before_bytes = conversation.items.len;
    const resume_prompt = compaction.buildResumePrompt(
        allocator,
        intent,
        ctx_builder,
        conversation.items,
        config.task_intent,
        step_index,
        compaction.recoveryOptions(checkpoint_attempt),
    ) catch return error.ProviderFailed;
    defer allocator.free(resume_prompt);

    conversation.clearRetainingCapacity();
    transport.appendUserText(allocator, conversation, resume_prompt) catch return error.ProviderFailed;
    emitCompaction(config, "step_limit_checkpoint", before_bytes, conversation.items.len, step_index, checkpoint_attempt);
    if (!checkpoint(config.checkpoint_context, conversation.items, step_index, "", "")) return error.ProviderFailed;
}

fn emitCompaction(
    config: Config,
    reason: []const u8,
    before_bytes: usize,
    after_bytes: usize,
    step_index: u32,
    attempt: u8,
) void {
    if (config.compaction_callback) |callback| {
        callback(config.compaction_context, reason, before_bytes, after_bytes, step_index, attempt);
    }
}

fn executeTool(
    allocator: std.mem.Allocator,
    transport: turn.Transport,
    conversation: *std.ArrayList(u8),
    call: turn.ToolCall,
    tool_ctx: tool_executor.Context,
    mcp: ?*mcp_registry.Registry,
    config: Config,
    guard: *LoopGuard,
    step_index: u32,
    append_call: bool,
) LoopError!void {
    if (!tool_registry.isToolAllowed(call.name, tool_ctx.profile, mcp)) return error.NotAllowed;
    try guard.noteToolCall(call.name, call.args_json);
    if (config.step_begin_callback) |callback| callback(config.step_begin_context, step_index, call.name, call.args_json);

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

    const summary = tool_dispatch.execute(allocator, tool_ctx, mcp, call) catch |err| {
        // Recoverable tool failures (bad path, malformed args) are fed back to the
        // model as an observation so it can correct itself instead of aborting the
        // whole run. Only truly fatal conditions propagate.
        const recovery = recoverableToolError(err) orelse return mapDispatch(err);
        const note = std.fmt.allocPrint(
            allocator,
            "Tool `{s}` failed: {s}. Check the arguments (e.g. a valid workspace-relative path) and try a different tool call, or answer with what you already know.",
            .{ call.name, recovery },
        ) catch return error.ProviderFailed;
        defer allocator.free(note);
        transport.appendToolResult(allocator, conversation, call.name, note) catch return error.ProviderFailed;
        if (config.step_callback) |callback| {
            const kind = subagent.classifyTool(call.name).label();
            callback(config.step_context, step_index, kind, note);
        }
        if (config.checkpoint_callback) |checkpoint| {
            if (!checkpoint(config.checkpoint_context, conversation.items, step_index + 1, "", "")) return error.ProviderFailed;
        }
        return;
    };
    defer allocator.free(summary);

    const bounded = tool_observation.bound(allocator, call.name, summary) catch return error.ProviderFailed;
    defer allocator.free(bounded);

    transport.appendToolResult(allocator, conversation, call.name, bounded) catch return error.ProviderFailed;

    if (config.step_callback) |callback| {
        const kind = subagent.classifyTool(call.name).label();
        callback(config.step_context, step_index, kind, bounded);
    }
    if (config.checkpoint_callback) |checkpoint| {
        if (!checkpoint(config.checkpoint_context, conversation.items, step_index + 1, "", "")) return error.ProviderFailed;
    }
}

fn mapDispatch(err: tool_dispatch.DispatchError) LoopError {
    return switch (err) {
        error.Cancelled => error.Cancelled,
        error.NotAllowed => error.NotAllowed,
        error.WorkspaceFailed, error.TaskFailed => error.WorkspaceFailed,
        error.ParseFailed => error.ProviderFailed,
        error.UnknownTool => error.ProviderFailed,
    };
}

/// Returns a short human-readable reason when the failure is something the model
/// can recover from within the loop (bad path, malformed arguments, unknown
/// tool name). Fatal conditions (cancel, capability denial) return null.
fn recoverableToolError(err: tool_dispatch.DispatchError) ?[]const u8 {
    return switch (err) {
        error.WorkspaceFailed, error.TaskFailed => "the target could not be accessed (it may not exist)",
        error.ParseFailed => "the arguments were not valid JSON for this tool",
        error.UnknownTool => "that tool is not available",
        error.NotAllowed => "the requested tool or command was not allowed; use a safer read/search/edit tool or an allowlisted command",
        error.Cancelled => null,
    };
}

test "recoverableToolError treats bad path and args as recoverable" {
    try std.testing.expect(recoverableToolError(error.WorkspaceFailed) != null);
    try std.testing.expect(recoverableToolError(error.ParseFailed) != null);
    try std.testing.expect(recoverableToolError(error.UnknownTool) != null);
    try std.testing.expect(recoverableToolError(error.NotAllowed) != null);
}

test "recoverableToolError keeps cancel fatal but lets model recover from denial" {
    try std.testing.expect(recoverableToolError(error.Cancelled) == null);
    try std.testing.expect(recoverableToolError(error.NotAllowed) != null);
}

test "LoopGuard allows duplicate tool calls" {
    var guard = LoopGuard{};
    try guard.noteToolCall("search", "{\"term\":\"x\"}");
    try guard.noteToolCall("search", "{\"term\":\"x\"}");
}

test "LoopGuard allows broad-tool repetition without stopping" {
    var guard = LoopGuard{};
    try guard.noteToolCall("search", "{\"term\":\"a\"}");
    try guard.noteToolCall("codebase_search", "{\"query\":\"b\"}");
    try guard.noteToolCall("list_tree", "{\"path\":\".\"}");
    try guard.noteToolCall("search", "{\"term\":\"c\"}");
    try guard.noteToolCall("codebase_search", "{\"query\":\"d\"}");
    try guard.noteToolCall("list_tree", "{\"path\":\"src\"}");
    try guard.noteToolCall("search", "{\"term\":\"e\"}");
    try guard.noteToolCall("codebase_search", "{\"query\":\"f\"}");
}

test "LoopGuard evidence resets stagnation counter" {
    var guard = LoopGuard{};
    try guard.noteToolCall("search", "{\"term\":\"a\"}");
    try guard.noteToolCall("read_file", "{\"path\":\"x\"}");
    try guard.noteToolCall("search", "{\"term\":\"b\"}");
    try guard.noteToolCall("codebase_search", "{\"query\":\"c\"}");
    try guard.noteToolCall("read_file", "{\"path\":\"y\"}");
}

test "run compacts and retries after context length exceeded" {
    const allocator = std.testing.allocator;

    const MockTransport = struct {
        calls: u8 = 0,
        user_appends: u8 = 0,

        fn transport(self: *@This()) turn.Transport {
            return .{
                .ptr = self,
                .complete_turn = complete,
                .append_user_text = appendUser,
                .append_tool_call = appendToolCall,
                .append_tool_result = appendToolResult,
            };
        }

        fn complete(
            ptr: *anyopaque,
            alloc: std.mem.Allocator,
            conversation_json: []const u8,
            tool_declarations_json: []const u8,
            cancel_token: ?*const kernel.cancellation.CancellationToken,
        ) turn.TransportError!turn.Completion {
            _ = conversation_json;
            _ = tool_declarations_json;
            _ = cancel_token;
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (self.calls == 1) return error.ContextLengthExceeded;
            return .{ .text = try alloc.dupe(u8, "Recovered answer.") };
        }

        fn appendUser(
            ptr: *anyopaque,
            alloc: std.mem.Allocator,
            conversation: *std.ArrayList(u8),
            text: []const u8,
        ) turn.TransportError!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.user_appends += 1;
            conversation.clearRetainingCapacity();
            try conversation.appendSlice(alloc, text);
        }

        fn appendToolCall(
            ptr: *anyopaque,
            alloc: std.mem.Allocator,
            conversation: *std.ArrayList(u8),
            call: turn.ToolCall,
        ) turn.TransportError!void {
            _ = ptr;
            _ = alloc;
            _ = conversation;
            _ = call;
        }

        fn appendToolResult(
            ptr: *anyopaque,
            alloc: std.mem.Allocator,
            conversation: *std.ArrayList(u8),
            tool_name: []const u8,
            result: []const u8,
        ) turn.TransportError!void {
            _ = ptr;
            _ = alloc;
            _ = conversation;
            _ = tool_name;
            _ = result;
        }
    };

    var builder = context.ContextBuilder.init(allocator, 4096);
    defer builder.deinit();
    try builder.addBlock(.intent, "intent", "large task");
    try builder.addBlock(.file, "src/main.zig", "pub fn main() void {}");

    var mock = MockTransport{};
    const tool_ctx: tool_executor.Context = undefined;
    var state = try run(allocator, mock.transport(), "[]", "large task", &builder, tool_ctx, null, .{
        .max_tool_steps = 3,
        .max_context_recovery_attempts = 1,
    });
    defer state.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 2), mock.calls);
    try std.testing.expectEqual(@as(u8, 2), mock.user_appends);
    try std.testing.expectEqualStrings("Recovered answer.", state.final_text.?);
}

test "step limit checkpoints compact resume state" {
    const allocator = std.testing.allocator;

    const MockTransport = struct {
        fn transport(self: *@This()) turn.Transport {
            return .{
                .ptr = self,
                .complete_turn = complete,
                .append_user_text = appendUser,
                .append_tool_call = appendToolCall,
                .append_tool_result = appendToolResult,
            };
        }

        fn complete(
            ptr: *anyopaque,
            alloc: std.mem.Allocator,
            conversation_json: []const u8,
            tool_declarations_json: []const u8,
            cancel_token: ?*const kernel.cancellation.CancellationToken,
        ) turn.TransportError!turn.Completion {
            _ = ptr;
            _ = alloc;
            _ = conversation_json;
            _ = tool_declarations_json;
            _ = cancel_token;
            return error.ProviderFailed;
        }

        fn appendUser(
            ptr: *anyopaque,
            alloc: std.mem.Allocator,
            conversation: *std.ArrayList(u8),
            text: []const u8,
        ) turn.TransportError!void {
            _ = ptr;
            conversation.clearRetainingCapacity();
            try conversation.appendSlice(alloc, text);
        }

        fn appendToolCall(
            ptr: *anyopaque,
            alloc: std.mem.Allocator,
            conversation: *std.ArrayList(u8),
            call: turn.ToolCall,
        ) turn.TransportError!void {
            _ = ptr;
            _ = alloc;
            _ = conversation;
            _ = call;
        }

        fn appendToolResult(
            ptr: *anyopaque,
            alloc: std.mem.Allocator,
            conversation: *std.ArrayList(u8),
            tool_name: []const u8,
            result: []const u8,
        ) turn.TransportError!void {
            _ = ptr;
            _ = alloc;
            _ = conversation;
            _ = tool_name;
            _ = result;
        }
    };

    const CheckpointState = struct {
        called: bool = false,
        step: u32 = 0,

        fn checkpoint(
            ctx: ?*anyopaque,
            conversation_json: []const u8,
            next_step_index: u32,
            pending_tool: []const u8,
            pending_args_json: []const u8,
        ) bool {
            _ = pending_tool;
            _ = pending_args_json;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.called = true;
            self.step = next_step_index;
            return std.mem.indexOf(u8, conversation_json, "compact checkpoint") != null and
                std.mem.indexOf(u8, conversation_json, "Retrieve fresh file contents before editing") != null;
        }
    };

    var builder = context.ContextBuilder.init(allocator, 4096);
    defer builder.deinit();
    try builder.addBlock(.intent, "intent", "implement a long feature");
    try builder.addBlock(.file, "src/main.zig", "pub fn main() void {}");

    var mock = MockTransport{};
    var conversation: std.ArrayList(u8) = .empty;
    defer conversation.deinit(allocator);
    try conversation.appendSlice(allocator,
        \\{"role":"user","content":"implement a long feature"}
        \\{"role":"tool","content":"large prior evidence"}
    );

    var checkpoint_state = CheckpointState{};
    try checkpointCompactResume(allocator, mock.transport(), &conversation, "implement a long feature", &builder, .{
        .checkpoint_callback = CheckpointState.checkpoint,
        .checkpoint_context = &checkpoint_state,
        .max_context_recovery_attempts = 3,
    }, 47);

    try std.testing.expect(checkpoint_state.called);
    try std.testing.expectEqual(@as(u32, 47), checkpoint_state.step);
    try std.testing.expect(std.mem.indexOf(u8, conversation.items, "Next step index: 47") != null);
    try std.testing.expect(std.mem.indexOf(u8, conversation.items, "large prior evidence") != null);
}

test "oversized conversation compacts before provider call" {
    const allocator = std.testing.allocator;

    const MockTransport = struct {
        user_appends: u8 = 0,

        fn transport(self: *@This()) turn.Transport {
            return .{
                .ptr = self,
                .complete_turn = complete,
                .append_user_text = appendUser,
                .append_tool_call = appendToolCall,
                .append_tool_result = appendToolResult,
            };
        }

        fn complete(
            ptr: *anyopaque,
            alloc: std.mem.Allocator,
            conversation_json: []const u8,
            tool_declarations_json: []const u8,
            cancel_token: ?*const kernel.cancellation.CancellationToken,
        ) turn.TransportError!turn.Completion {
            _ = ptr;
            _ = alloc;
            _ = conversation_json;
            _ = tool_declarations_json;
            _ = cancel_token;
            return error.ProviderFailed;
        }

        fn appendUser(
            ptr: *anyopaque,
            alloc: std.mem.Allocator,
            conversation: *std.ArrayList(u8),
            text: []const u8,
        ) turn.TransportError!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.user_appends += 1;
            conversation.clearRetainingCapacity();
            try conversation.appendSlice(alloc, text);
        }

        fn appendToolCall(
            ptr: *anyopaque,
            alloc: std.mem.Allocator,
            conversation: *std.ArrayList(u8),
            call: turn.ToolCall,
        ) turn.TransportError!void {
            _ = ptr;
            _ = alloc;
            _ = conversation;
            _ = call;
        }

        fn appendToolResult(
            ptr: *anyopaque,
            alloc: std.mem.Allocator,
            conversation: *std.ArrayList(u8),
            tool_name: []const u8,
            result: []const u8,
        ) turn.TransportError!void {
            _ = ptr;
            _ = alloc;
            _ = conversation;
            _ = tool_name;
            _ = result;
        }
    };

    var builder = context.ContextBuilder.init(allocator, 4096);
    defer builder.deinit();
    try builder.addBlock(.intent, "intent", "long task");
    try builder.addBlock(.file, "src/main.zig", "pub fn main() void {}");

    var mock = MockTransport{};
    var conversation: std.ArrayList(u8) = .empty;
    defer conversation.deinit(allocator);
    try conversation.appendNTimes(allocator, 'x', 2048);

    var compactions: u8 = 0;
    try compactConversationIfNeeded(allocator, mock.transport(), &conversation, "long task", &builder, .{
        .max_conversation_bytes = 512,
    }, 9, &compactions);

    try std.testing.expectEqual(@as(u8, 1), mock.user_appends);
    try std.testing.expectEqual(@as(u8, 1), compactions);
    try std.testing.expect(std.mem.indexOf(u8, conversation.items, "compact checkpoint") != null);
    try std.testing.expect(std.mem.indexOf(u8, conversation.items, "Next step index: 9") != null);
}
