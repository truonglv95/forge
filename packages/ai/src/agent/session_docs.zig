const std = @import("std");
const agent_compaction = @import("compaction.zig");
const task_ledger = @import("../task_ledger.zig");

pub fn formatCheckpointSessionJson(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    intent: []const u8,
    config: anytype,
    steps: anytype,
    conversation_json: []const u8,
    next_step_index: u32,
    pending_tool: []const u8,
    pending_tool_args: []const u8,
    provider_kind: []const u8,
    execution_state: []const u8,
) ![]u8 {
    const StoredStep = struct {
        index: u32,
        kind: []const u8,
        summary: []const u8,
        run_id: []const u8,
    };
    var stored_steps = try allocator.alloc(StoredStep, steps.len);
    defer allocator.free(stored_steps);
    for (steps, 0..) |step, index| {
        stored_steps[index] = .{
            .index = step.index,
            .kind = step.kind,
            .summary = step.summary,
            .run_id = step.run_id orelse "",
        };
    }

    const CheckpointDoc = struct {
        schema_version: u32 = 3,
        session_id: []const u8,
        intent: []const u8,
        workspace_path: []const u8,
        capability_profile: []const u8,
        max_steps: u32,
        run_ids: []const []const u8 = &.{},
        proposal_path: []const u8 = "",
        steps: []StoredStep,
        execution_state: []const u8,
        next_step_index: u32,
        pending_tool: []const u8,
        pending_tool_args: []const u8,
        conversation_json: []const u8,
        compact_summary: []const u8,
        task_ledger_json: []const u8,
        provider_kind: []const u8,
    };
    const compact_summary = try buildCompactSummary(allocator, intent, steps, null, conversation_json);
    defer allocator.free(compact_summary);
    const task_ledger_json = try buildTaskLedgerJson(allocator, intent, steps, phaseFromExecutionState(execution_state));
    defer allocator.free(task_ledger_json);
    return std.json.Stringify.valueAlloc(allocator, CheckpointDoc{
        .session_id = session_id,
        .intent = intent,
        .workspace_path = config.workspace_cwd,
        .capability_profile = @tagName(config.capability_profile),
        .max_steps = config.max_steps,
        .steps = stored_steps,
        .execution_state = execution_state,
        .next_step_index = next_step_index,
        .pending_tool = pending_tool,
        .pending_tool_args = pending_tool_args,
        .conversation_json = conversation_json,
        .compact_summary = compact_summary,
        .task_ledger_json = task_ledger_json,
        .provider_kind = provider_kind,
    }, .{});
}

pub fn formatSessionJson(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    intent: []const u8,
    config: anytype,
    steps: anytype,
    run_id: []const u8,
    proposal_rel: []const u8,
    conversation_json: []const u8,
    provider_kind: []const u8,
) ![]u8 {
    const SessionStep = struct {
        index: u32,
        kind: []const u8,
        summary: []const u8,
        run_id: []const u8,
    };

    const ToolCall = struct {
        index: u32,
        tool: []const u8,
        summary: []const u8,
    };

    var step_items = try allocator.alloc(SessionStep, steps.len);
    defer allocator.free(step_items);
    var tool_items = try allocator.alloc(ToolCall, steps.len);
    defer allocator.free(tool_items);
    for (steps, 0..) |step, index| {
        step_items[index] = .{
            .index = step.index,
            .kind = step.kind,
            .summary = step.summary,
            .run_id = step.run_id orelse "",
        };
        tool_items[index] = .{
            .index = step.index,
            .tool = step.kind,
            .summary = step.summary,
        };
    }

    const SessionDoc = struct {
        schema_version: u32 = 3,
        session_id: []const u8,
        intent: []const u8,
        workspace_path: []const u8,
        capability_profile: []const u8,
        max_steps: u32,
        run_ids: []const []const u8,
        proposal_path: []const u8,
        tool_calls: []ToolCall,
        steps: []SessionStep,
        execution_state: []const u8,
        next_step_index: u32,
        pending_tool: []const u8,
        pending_tool_args: []const u8,
        conversation_json: []const u8,
        compact_summary: []const u8,
        task_ledger_json: []const u8,
        provider_kind: []const u8,
    };

    const run_ids = try allocator.alloc([]const u8, 1);
    defer allocator.free(run_ids);
    run_ids[0] = run_id;
    const compact_summary = try buildCompactSummary(allocator, intent, steps, null, conversation_json);
    defer allocator.free(compact_summary);
    const task_ledger_json = try buildTaskLedgerJson(allocator, intent, steps, .summarizing);
    defer allocator.free(task_ledger_json);

    return std.json.Stringify.valueAlloc(allocator, SessionDoc{
        .session_id = session_id,
        .intent = intent,
        .workspace_path = config.workspace_cwd,
        .capability_profile = @tagName(config.capability_profile),
        .max_steps = config.max_steps,
        .run_ids = run_ids,
        .proposal_path = proposal_rel,
        .tool_calls = tool_items,
        .steps = step_items,
        .execution_state = "proposal_ready",
        .next_step_index = @intCast(steps.len + 1),
        .pending_tool = "",
        .pending_tool_args = "",
        .conversation_json = conversation_json,
        .compact_summary = compact_summary,
        .task_ledger_json = task_ledger_json,
        .provider_kind = provider_kind,
    }, .{});
}

pub fn buildCompactSummary(
    allocator: std.mem.Allocator,
    intent: []const u8,
    steps: anytype,
    final_text: ?[]const u8,
    conversation_json: []const u8,
) ![]u8 {
    var items = try allocator.alloc(agent_compaction.SummaryStep, steps.len);
    defer allocator.free(items);
    for (steps, 0..) |step, index| {
        items[index] = .{
            .index = step.index,
            .kind = step.kind,
            .summary = step.summary,
        };
    }
    return agent_compaction.buildSessionSummary(allocator, intent, items, final_text, conversation_json);
}

pub fn buildTaskLedgerJson(
    allocator: std.mem.Allocator,
    intent: []const u8,
    steps: anytype,
    phase: task_ledger.Phase,
) ![]u8 {
    var items = try allocator.alloc(task_ledger.StepInput, steps.len);
    defer allocator.free(items);
    for (steps, 0..) |step, index| {
        items[index] = .{
            .index = step.index,
            .kind = step.kind,
            .summary = step.summary,
        };
    }
    var snapshot = try task_ledger.fromSteps(allocator, intent, items, phase);
    defer snapshot.deinit(allocator);
    return task_ledger.toJsonAlloc(allocator, snapshot);
}

pub fn validateProposalEvidenceForSteps(
    allocator: std.mem.Allocator,
    proposal_body: []const u8,
    steps: anytype,
) !?[]const u8 {
    var items = try allocator.alloc(task_ledger.StepInput, steps.len);
    defer allocator.free(items);
    for (steps, 0..) |step, index| {
        items[index] = .{
            .index = step.index,
            .kind = step.kind,
            .summary = step.summary,
        };
    }
    return task_ledger.validateProposalEvidence(allocator, proposal_body, items);
}

fn phaseFromExecutionState(state: []const u8) task_ledger.Phase {
    if (std.mem.eql(u8, state, "completed")) return .completed;
    if (std.mem.eql(u8, state, "failed")) return .blocked;
    if (std.mem.eql(u8, state, "proposal_ready")) return .summarizing;
    if (std.mem.eql(u8, state, "tool_pending")) return .gathering;
    return .gathering;
}
