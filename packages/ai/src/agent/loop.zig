const std = @import("std");
const provider = @import("../provider.zig");
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
const workspace = @import("forge-workspace");
const tool_args = @import("../tools/args.zig");
const task_ledger = @import("../task_ledger.zig");

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
pub const Telemetry = struct {
    phase: []const u8,
    duration_ms: i64 = 0,
    bytes: usize = 0,
    items: usize = 0,
    detail: []const u8 = "",
};
pub const TelemetryCallback = *const fn (?*anyopaque, Telemetry) void;

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
    initial_task_ledger_json: []const u8 = "",
    approval_callback: ?ApprovalCallback = null,
    approval_context: ?*anyopaque = null,
    telemetry_callback: ?TelemetryCallback = null,
    telemetry_context: ?*anyopaque = null,
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
    var agent_state = task_ledger.AgentState.initFromJsonOrGoal(allocator, config.initial_task_ledger_json, intent) catch return error.ProviderFailed;
    defer agent_state.deinit(allocator);

    const prompt = loop_prompt.buildExplorePrompt(allocator, intent, ctx_builder, .{
        .task_intent = config.task_intent,
        .preloaded_retrieval = config.preloaded_retrieval,
    }) catch return error.ProviderFailed;
    defer allocator.free(prompt);

    if (config.initial_conversation_json.len > 0) {
        conversation.appendSlice(allocator, config.initial_conversation_json) catch return error.ProviderFailed;
        const state_json = agent_state.toJsonAlloc(allocator) catch return error.ProviderFailed;
        defer allocator.free(state_json);
        if (state_json.len > 0) {
            const ledger_prompt = std.fmt.allocPrint(
                allocator,
                "Task ledger checkpoint. Use this as durable task state; do not treat it as source code.\n```json\n{s}\n```",
                .{state_json},
            ) catch return error.ProviderFailed;
            defer allocator.free(ledger_prompt);
            transport.appendUserText(allocator, &conversation, ledger_prompt) catch return error.ProviderFailed;
        }
    } else {
        transport.appendUserText(allocator, &conversation, prompt) catch return error.ProviderFailed;
    }

    var step_index: u32 = config.initial_step_index;
    if (config.pending_tool.len > 0) {
        const pending_call = turn.ToolCall{
            .name = @constCast(config.pending_tool),
            .args_json = @constCast(config.pending_args_json),
        };
        try executeTool(allocator, transport, &conversation, pending_call, tool_ctx, mcp, config, &guard, &agent_state, step_index, false);
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

        try compactConversationIfNeeded(allocator, transport, &conversation, intent, ctx_builder, config, &agent_state, step_index, &conversation_compactions);

        const llm_start_ms = std.Io.Timestamp.now(tool_ctx.io, .real).toMilliseconds();
        var completion = transport.complete(allocator, conversation.items, tool_declarations_json, config.cancel_token) catch |err| {
            emitTelemetry(config, .{
                .phase = "llm_call",
                .duration_ms = millisSince(tool_ctx.io, llm_start_ms),
                .bytes = conversation.items.len,
                .items = step_index,
                .detail = @errorName(err),
            });
            switch (err) {
                error.Cancelled => return error.Cancelled,
                error.AuthenticationFailed => return error.AuthenticationFailed,
                error.RateLimitExceeded => return error.RateLimitExceeded,
                error.ContextLengthExceeded => {
                    if (context_recoveries >= config.max_context_recovery_attempts) return error.ContextLengthExceeded;
                    context_recoveries += 1;
                    const before_bytes = conversation.items.len;
                    var recovery_options = compaction.recoveryOptions(context_recoveries);
                    const state_json = agent_state.toJsonAlloc(allocator) catch return error.ProviderFailed;
                    defer allocator.free(state_json);
                    recovery_options.task_ledger_json = state_json;
                    const recovery_prompt = compaction.buildRecoveryPrompt(
                        allocator,
                        intent,
                        ctx_builder,
                        conversation.items,
                        config.task_intent,
                        recovery_options,
                    ) catch return error.ProviderFailed;
                    defer allocator.free(recovery_prompt);
                    conversation.clearRetainingCapacity();
                    transport.appendUserText(allocator, &conversation, recovery_prompt) catch return error.ProviderFailed;
                    emitCompaction(config, "provider_context_length", before_bytes, conversation.items.len, step_index, context_recoveries);
                    emitTelemetry(config, .{
                        .phase = "compact",
                        .duration_ms = 0,
                        .bytes = before_bytes -| conversation.items.len,
                        .items = step_index,
                        .detail = "provider_context_length",
                    });
                    if (config.checkpoint_callback) |checkpoint| {
                        if (!checkpoint(config.checkpoint_context, conversation.items, step_index, "", "")) return error.ProviderFailed;
                    }
                    continue;
                },
                error.NetworkError => return error.NetworkError,
                error.MalformedResponse => {
                    emitTelemetry(config, .{
                        .phase = "repair",
                        .duration_ms = 0,
                        .bytes = conversation.items.len,
                        .items = malformed_repairs + 1,
                        .detail = "malformed_response",
                    });
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
            }
        };
        emitTelemetry(config, .{
            .phase = "llm_call",
            .duration_ms = millisSince(tool_ctx.io, llm_start_ms),
            .bytes = conversation.items.len,
            .items = step_index,
            .detail = "ok",
        });
        defer completion.deinit(allocator);

        switch (completion) {
            .tool_call => |call| {
                try executeTool(allocator, transport, &conversation, call, tool_ctx, mcp, config, &guard, &agent_state, step_index, true);
                step_index += 1;
            },
            .tool_calls => |calls| {
                // Parallel tool calls: execute sequentially in MVP (thread-safe
                // provider handles are needed for true parallelism, tracked in
                // RFC-0015). Each call still increments step_index and is
                // checkpointed independently.
                for (calls) |call| {
                    try executeTool(allocator, transport, &conversation, call, tool_ctx, mcp, config, &guard, &agent_state, step_index, true);
                    step_index += 1;
                }
            },
            .text => {
                if (agent_state.finalGateIssue(allocator, completion.text) catch return error.ProviderFailed) |issue| {
                    defer allocator.free(issue);
                    emitTelemetry(config, .{ .phase = "gate", .items = step_index, .detail = "final_blocked" });
                    transport.appendUserText(allocator, &conversation, issue) catch return error.ProviderFailed;
                    continue;
                }
                agent_state.phase = .completed;
                return .{
                    .conversation_json = conversation.toOwnedSlice(allocator) catch return error.ProviderFailed,
                    .next_step_index = step_index,
                    .final_text = allocator.dupe(u8, completion.text) catch return error.ProviderFailed,
                };
            },
        }
    }
    try checkpointCompactResume(allocator, transport, &conversation, intent, ctx_builder, config, &agent_state, step_index);
    return error.StepLimitReached;
}

fn compactConversationIfNeeded(
    allocator: std.mem.Allocator,
    transport: turn.Transport,
    conversation: *std.ArrayList(u8),
    intent: []const u8,
    ctx_builder: *const context.ContextBuilder,
    config: Config,
    agent_state: *const task_ledger.AgentState,
    step_index: u32,
    compactions: *u8,
) LoopError!void {
    if (config.max_conversation_bytes == 0) return;
    if (conversation.items.len <= config.max_conversation_bytes) return;
    if (compactions.* >= config.max_conversation_compactions) return;

    const next_attempt = if (compactions.* == std.math.maxInt(u8)) compactions.* else compactions.* + 1;
    const before_bytes = conversation.items.len;
    var compact_options = compaction.recoveryOptions(next_attempt);
    const state_json = agent_state.toJsonAlloc(allocator) catch return error.ProviderFailed;
    defer allocator.free(state_json);
    compact_options.task_ledger_json = state_json;
    const compact_prompt = compaction.buildResumePrompt(
        allocator,
        intent,
        ctx_builder,
        conversation.items,
        config.task_intent,
        step_index,
        compact_options,
    ) catch return error.ProviderFailed;
    defer allocator.free(compact_prompt);

    conversation.clearRetainingCapacity();
    transport.appendUserText(allocator, conversation, compact_prompt) catch return error.ProviderFailed;
    compactions.* = next_attempt;
    emitCompaction(config, "conversation_budget", before_bytes, conversation.items.len, step_index, next_attempt);
    emitTelemetry(config, .{
        .phase = "compact",
        .duration_ms = 0,
        .bytes = before_bytes -| conversation.items.len,
        .items = step_index,
        .detail = "conversation_budget",
    });
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
    agent_state: *const task_ledger.AgentState,
    step_index: u32,
) LoopError!void {
    const checkpoint = config.checkpoint_callback orelse return;
    const checkpoint_attempt = if (config.max_context_recovery_attempts == std.math.maxInt(u8))
        config.max_context_recovery_attempts
    else
        config.max_context_recovery_attempts + 1;
    const before_bytes = conversation.items.len;
    var resume_options = compaction.recoveryOptions(checkpoint_attempt);
    const state_json = agent_state.toJsonAlloc(allocator) catch return error.ProviderFailed;
    defer allocator.free(state_json);
    resume_options.task_ledger_json = state_json;
    const resume_prompt = compaction.buildResumePrompt(
        allocator,
        intent,
        ctx_builder,
        conversation.items,
        config.task_intent,
        step_index,
        resume_options,
    ) catch return error.ProviderFailed;
    defer allocator.free(resume_prompt);

    conversation.clearRetainingCapacity();
    transport.appendUserText(allocator, conversation, resume_prompt) catch return error.ProviderFailed;
    emitCompaction(config, "step_limit_checkpoint", before_bytes, conversation.items.len, step_index, checkpoint_attempt);
    emitTelemetry(config, .{
        .phase = "checkpoint",
        .duration_ms = 0,
        .bytes = conversation.items.len,
        .items = step_index,
        .detail = "step_limit_checkpoint",
    });
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

fn emitTelemetry(config: Config, event: Telemetry) void {
    if (config.telemetry_callback) |callback| {
        callback(config.telemetry_context, event);
    }
}

fn millisSince(io: std.Io, start_ms: i64) i64 {
    const end_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    return if (end_ms >= start_ms) end_ms - start_ms else 0;
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
    agent_state: *task_ledger.AgentState,
    step_index: u32,
    append_call: bool,
) LoopError!void {
    const repaired_args = repairToolArgsJson(allocator, call.name, call.args_json) catch null;
    defer if (repaired_args) |json| allocator.free(json);
    const effective_call = turn.ToolCall{
        .name = call.name,
        .args_json = repaired_args orelse call.args_json,
    };
    if (repaired_args != null) {
        emitTelemetry(config, .{
            .phase = "tool_arg_repair",
            .duration_ms = 0,
            .bytes = call.args_json.len,
            .items = step_index,
            .detail = call.name,
        });
    }

    if (!tool_registry.isToolAllowed(effective_call.name, tool_ctx.profile, mcp)) return error.NotAllowed;
    try guard.noteToolCall(effective_call.name, effective_call.args_json);
    if (config.step_begin_callback) |callback| callback(config.step_begin_context, step_index, effective_call.name, effective_call.args_json);

    if (append_call) transport.appendToolCall(allocator, conversation, effective_call) catch return error.ProviderFailed;
    if (config.checkpoint_callback) |checkpoint| {
        if (!checkpoint(config.checkpoint_context, conversation.items, step_index, effective_call.name, effective_call.args_json)) return error.ProviderFailed;
    }

    if (std.mem.eql(u8, effective_call.name, "replace_file_content") or std.mem.eql(u8, effective_call.name, "multi_edit")) {
        const maybe_message = missingWriteEvidenceMessage(allocator, tool_ctx, agent_state.*, effective_call.name, effective_call.args_json) catch null;
        if (maybe_message != null) {
            const message = maybe_message.?;
            defer allocator.free(message);
            emitTelemetry(config, .{ .phase = "gate", .items = step_index, .detail = "missing_write_evidence" });
            transport.appendToolResult(allocator, conversation, effective_call.name, message, &.{}) catch return error.ProviderFailed;
            if (config.step_callback) |callback| callback(config.step_context, step_index, subagent.classifyTool(effective_call.name).label(), message);
            if (config.checkpoint_callback) |checkpoint| {
                if (!checkpoint(config.checkpoint_context, conversation.items, step_index + 1, "", "")) return error.ProviderFailed;
            }
            return;
        }
    }

    // Use policyForMcp when MCP tools are available so that read-only MCP
    // tools (annotations.readOnly=true) get low/automatic policy instead
    // of the default high/every_time.
    const policy = blk: {
        if (mcp) |reg| {
            if (reg.hasTool(effective_call.name)) {
                if (reg.findTool(effective_call.name)) |tool| {
                    break :blk tool_registry.policyForMcp(effective_call.name, tool.annotations_json);
                }
            }
        }
        break :blk tool_registry.policyFor(effective_call.name);
    };
    if (policy.approval == .every_time or policy.approval == .review) {
        if (config.approval_callback) |approve| {
            if (!approve(config.approval_context, effective_call.name, effective_call.args_json, policy)) return error.NotAllowed;
        } else if (policy.approval == .every_time and !config.approve_every_time_tools) {
            return error.NotAllowed;
        } else if (policy.approval == .review) {
            return error.NotAllowed;
        }
    }

    const tool_start_ms = std.Io.Timestamp.now(tool_ctx.io, .real).toMilliseconds();
    var exec_result = tool_dispatch.execute(allocator, tool_ctx, mcp, effective_call) catch |err| {
        // Recoverable tool failures (bad path, malformed args) are fed back to the
        // model as an observation so it can correct itself instead of aborting the
        // whole run. Only truly fatal conditions propagate.
        const recovery = recoverableToolError(err) orelse return mapDispatch(err);
        emitTelemetry(config, .{
            .phase = "tool_arg_repair",
            .duration_ms = millisSince(tool_ctx.io, tool_start_ms),
            .bytes = effective_call.args_json.len,
            .items = step_index,
            .detail = effective_call.name,
        });
        const note = std.fmt.allocPrint(
            allocator,
            "Tool `{s}` failed: {s}. Check the arguments (e.g. a valid workspace-relative path) and try a different tool call, or answer with what you already know.",
            .{ effective_call.name, recovery },
        ) catch return error.ProviderFailed;
        defer allocator.free(note);
        transport.appendToolResult(allocator, conversation, effective_call.name, note, &.{}) catch return error.ProviderFailed;
        if (config.step_callback) |callback| {
            const kind = subagent.classifyTool(effective_call.name).label();
            callback(config.step_context, step_index, kind, note);
        }
        if (config.checkpoint_callback) |checkpoint| {
            if (!checkpoint(config.checkpoint_context, conversation.items, step_index + 1, "", "")) return error.ProviderFailed;
        }
        return;
    };
    defer exec_result.deinit(allocator);

    emitTelemetry(config, .{
        .phase = "tool",
        .duration_ms = millisSince(tool_ctx.io, tool_start_ms),
        .bytes = exec_result.text.len,
        .items = step_index,
        .detail = effective_call.name,
    });

    const bounded = tool_observation.bound(allocator, effective_call.name, exec_result.text) catch return error.ProviderFailed;
    defer allocator.free(bounded);

    transport.appendToolResult(allocator, conversation, effective_call.name, bounded, exec_result.images) catch return error.ProviderFailed;
    agent_state.recordToolResult(allocator, step_index, effective_call.name, bounded) catch return error.ProviderFailed;

    if (config.step_callback) |callback| {
        const kind = subagent.classifyTool(effective_call.name).label();
        callback(config.step_context, step_index, kind, bounded);
    }
    if (config.checkpoint_callback) |checkpoint| {
        if (!checkpoint(config.checkpoint_context, conversation.items, step_index + 1, "", "")) return error.ProviderFailed;
    }
}

fn repairToolArgsJson(allocator: std.mem.Allocator, tool_name: []const u8, args_json: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, args_json, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
        return repairRawStringArgs(allocator, tool_name, trimmed);
    };
    defer parsed.deinit();

    switch (parsed.value) {
        .string => |value| return repairRawStringArgs(allocator, tool_name, value),
        .object => |object| {
            if (std.mem.eql(u8, tool_name, "read_file") or
                std.mem.eql(u8, tool_name, "list_tree") or
                std.mem.eql(u8, tool_name, "replace_file_content"))
            {
                if (object.get("path") == null) {
                    if (firstStringField(object, &.{ "file", "filepath", "target", "filename" })) |path| {
                        return try std.json.Stringify.valueAlloc(allocator, .{ .path = path }, .{});
                    }
                }
            }
            if (std.mem.eql(u8, tool_name, "search")) {
                if (object.get("pattern") == null) {
                    if (firstStringField(object, &.{ "query", "term", "text" })) |pattern| {
                        return try std.json.Stringify.valueAlloc(allocator, .{ .pattern = pattern }, .{});
                    }
                }
            }
            if (std.mem.eql(u8, tool_name, "codebase_search")) {
                if (object.get("query") == null) {
                    if (firstStringField(object, &.{ "pattern", "term", "text" })) |query| {
                        return try std.json.Stringify.valueAlloc(allocator, .{ .query = query }, .{});
                    }
                }
            }
            if (std.mem.eql(u8, tool_name, "run_command")) {
                if (object.get("command") == null) {
                    if (firstStringField(object, &.{ "cmd", "shell", "text" })) |command| {
                        return try std.json.Stringify.valueAlloc(allocator, .{ .command = command }, .{});
                    }
                }
            }
        },
        else => {},
    }
    return null;
}

fn repairRawStringArgs(allocator: std.mem.Allocator, tool_name: []const u8, value: []const u8) !?[]u8 {
    if (std.mem.eql(u8, tool_name, "read_file") or
        std.mem.eql(u8, tool_name, "list_tree"))
    {
        return try std.json.Stringify.valueAlloc(allocator, .{ .path = value }, .{});
    }
    if (std.mem.eql(u8, tool_name, "search")) {
        return try std.json.Stringify.valueAlloc(allocator, .{ .pattern = value }, .{});
    }
    if (std.mem.eql(u8, tool_name, "codebase_search")) {
        return try std.json.Stringify.valueAlloc(allocator, .{ .query = value }, .{});
    }
    if (std.mem.eql(u8, tool_name, "run_command")) {
        return try std.json.Stringify.valueAlloc(allocator, .{ .command = value }, .{});
    }
    return null;
}

fn firstStringField(object: std.json.ObjectMap, keys: []const []const u8) ?[]const u8 {
    for (keys) |key| {
        const value = object.get(key) orelse continue;
        if (value == .string) return value.string;
    }
    return null;
}

fn missingWriteEvidenceMessage(
    allocator: std.mem.Allocator,
    tool_ctx: tool_executor.Context,
    agent_state: task_ledger.AgentState,
    tool_name: []const u8,
    args_json: []const u8,
) !?[]const u8 {
    if (std.mem.eql(u8, tool_name, "multi_edit")) {
        const edit_args = tool_args.parseMultiEditArgs(allocator, args_json) catch return null;
        defer tool_args.freeMultiEditArgs(allocator, edit_args);
        for (edit_args.files) |file| {
            const issue = try missingPathEvidenceMessage(allocator, tool_ctx, agent_state, file.path, "multi_edit");
            if (issue) |text| return text;
        }
        return null;
    }

    const edit_args = tool_args.parseReplaceFileContentArgs(allocator, args_json) catch return null;
    defer {
        allocator.free(edit_args.path);
        for (edit_args.edits) |edit| {
            allocator.free(edit.search);
            allocator.free(edit.replace);
        }
        allocator.free(edit_args.edits);
    }
    return try missingPathEvidenceMessage(allocator, tool_ctx, agent_state, edit_args.path, "replace_file_content");
}

fn missingPathEvidenceMessage(
    allocator: std.mem.Allocator,
    tool_ctx: tool_executor.Context,
    agent_state: task_ledger.AgentState,
    path: []const u8,
    tool_name: []const u8,
) !?[]const u8 {
    const wp = workspace.WorkspacePath.parse(path) catch return null;
    var snap = workspace.FileSnapshot.read(allocator, tool_ctx.io, tool_ctx.root, wp) catch return null;
    defer snap.deinit();
    if (agent_state.hasFreshFileEvidence(path, snap.hash)) return null;
    return try std.fmt.allocPrint(
        allocator,
        "Tool `{s}` blocked: missing fresh read_file evidence for `{s}` hash={x}. Call read_file on `{s}` before editing, then retry with the exact block to replace.",
        .{ tool_name, path, snap.hash, path },
    );
}

fn conversationHasReadEvidence(
    allocator: std.mem.Allocator,
    conversation_json: []const u8,
    path: []const u8,
    hash: u64,
) bool {
    const needle = std.fmt.allocPrint(allocator, "File `{s}` hash={x}", .{ path, hash }) catch return false;
    defer allocator.free(needle);
    return std.mem.indexOf(u8, conversation_json, needle) != null or escapedContains(conversation_json, needle);
}

fn escapedContains(haystack: []const u8, needle: []const u8) bool {
    var index: usize = 0;
    var ni: usize = 0;
    while (index < haystack.len and ni < needle.len) : (index += 1) {
        const c = haystack[index];
        if (c == '\\' and index + 1 < haystack.len) {
            const next = haystack[index + 1];
            const actual: u8 = switch (next) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '"' => '"',
                '\\' => '\\',
                else => next,
            };
            if (actual == needle[ni]) {
                ni += 1;
                index += 1;
                continue;
            }
        }
        if (c == needle[ni]) {
            ni += 1;
        } else {
            ni = 0;
            if (c == needle[0]) ni = 1;
        }
    }
    return ni == needle.len;
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

test "repairToolArgsJson normalizes common schema aliases" {
    const allocator = std.testing.allocator;

    const read_fixed = (try repairToolArgsJson(allocator, "read_file", "{\"file\":\"src/main.zig\"}")).?;
    defer allocator.free(read_fixed);
    try std.testing.expect(std.mem.indexOf(u8, read_fixed, "\"path\":\"src/main.zig\"") != null);

    const search_fixed = (try repairToolArgsJson(allocator, "search", "{\"query\":\"Agent\"}")).?;
    defer allocator.free(search_fixed);
    try std.testing.expect(std.mem.indexOf(u8, search_fixed, "\"pattern\":\"Agent\"") != null);

    const raw_fixed = (try repairToolArgsJson(allocator, "codebase_search", "agent loop")).?;
    defer allocator.free(raw_fixed);
    try std.testing.expect(std.mem.indexOf(u8, raw_fixed, "\"query\":\"agent loop\"") != null);
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

test "conversationHasReadEvidence matches raw and escaped tool output" {
    const allocator = std.testing.allocator;
    try std.testing.expect(conversationHasReadEvidence(
        allocator,
        "File `src/main.zig` hash=2a lines=1-3",
        "src/main.zig",
        0x2a,
    ));
    try std.testing.expect(conversationHasReadEvidence(
        allocator,
        "{\"output\":\"File `src/main.zig` hash=2a bytes=4 lines=1-1\\n\"}",
        "src/main.zig",
        0x2a,
    ));
    try std.testing.expect(!conversationHasReadEvidence(
        allocator,
        "{\"output\":\"File `src/main.zig` hash=2b bytes=4 lines=1-1\\n\"}",
        "src/main.zig",
        0x2a,
    ));
}

test "missingWriteEvidenceMessage blocks edits until fresh read evidence exists" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");
    try workspace.atomic.createDirPath(io, root, "src");
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("src/main.zig"), "const value = 1;\n");
    const tool_ctx = tool_executor.Context{
        .allocator = allocator,
        .io = io,
        .root = root,
        .cwd = ".",
        .profile = .propose,
    };
    const args =
        \\{"path":"src/main.zig","edits":[{"search":"const value = 1;","replace":"const value = 2;"}]}
    ;

    var agent_state = try task_ledger.AgentState.init(allocator, "edit file");
    defer agent_state.deinit(allocator);

    const blocked = try missingWriteEvidenceMessage(allocator, tool_ctx, agent_state, "replace_file_content", args);
    try std.testing.expect(blocked != null);
    defer allocator.free(blocked.?);
    try std.testing.expect(std.mem.indexOf(u8, blocked.?, "missing fresh read_file evidence") != null);

    var snap = try workspace.FileSnapshot.read(allocator, io, root, try workspace.WorkspacePath.parse("src/main.zig"));
    defer snap.deinit();
    const evidence = try std.fmt.allocPrint(allocator, "File `src/main.zig` hash={x} bytes={d} lines=1-1\n", .{ snap.hash, snap.content.len });
    defer allocator.free(evidence);
    try agent_state.recordToolResult(allocator, 1, "read_file", evidence);
    const allowed = try missingWriteEvidenceMessage(allocator, tool_ctx, agent_state, "replace_file_content", args);
    try std.testing.expect(allowed == null);
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
            images: []const provider.ImagePart,
        ) turn.TransportError!void {
            _ = ptr;
            _ = alloc;
            _ = conversation;
            _ = tool_name;
            _ = result;
            _ = images;
        }
    };

    var builder = context.ContextBuilder.init(allocator, 4096);
    defer builder.deinit();
    try builder.addBlock(.intent, "intent", "large task");
    try builder.addBlock(.file, "src/main.zig", "pub fn main() void {}");

    var mock = MockTransport{};
    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const tool_ctx = tool_executor.Context{
        .allocator = allocator,
        .io = std.testing.io,
        .root = workspace.WorkspaceRoot.init(tmp.dir, "."),
        .cwd = ".",
        .profile = .read_only,
    };
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
            images: []const provider.ImagePart,
        ) turn.TransportError!void {
            _ = ptr;
            _ = alloc;
            _ = conversation;
            _ = tool_name;
            _ = result;
            _ = images;
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
    var agent_state = try task_ledger.AgentState.init(allocator, "implement a long feature");
    defer agent_state.deinit(allocator);
    try checkpointCompactResume(allocator, mock.transport(), &conversation, "implement a long feature", &builder, .{
        .checkpoint_callback = CheckpointState.checkpoint,
        .checkpoint_context = &checkpoint_state,
        .max_context_recovery_attempts = 3,
    }, &agent_state, 47);

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
            images: []const provider.ImagePart,
        ) turn.TransportError!void {
            _ = ptr;
            _ = alloc;
            _ = conversation;
            _ = tool_name;
            _ = result;
            _ = images;
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
    var agent_state = try task_ledger.AgentState.init(allocator, "long task");
    defer agent_state.deinit(allocator);
    try compactConversationIfNeeded(allocator, mock.transport(), &conversation, "long task", &builder, .{
        .max_conversation_bytes = 512,
    }, &agent_state, 9, &compactions);

    try std.testing.expectEqual(@as(u8, 1), mock.user_appends);
    try std.testing.expectEqual(@as(u8, 1), compactions);
    try std.testing.expect(std.mem.indexOf(u8, conversation.items, "compact checkpoint") != null);
    try std.testing.expect(std.mem.indexOf(u8, conversation.items, "Next step index: 9") != null);
}
