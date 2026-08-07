//! Agent orchestrator — consumes a PrepareResponse (from backend agent-prepare
//! or native heuristic) and drives the agent loop with a multi-step plan
//! instead of a single intent.
//!
//! Phase B: when the backend is reachable + returns used_llm=true, the
//! orchestrator follows the backend's plan. When unavailable, it falls back
//! to the native intent_taxonomy heuristic + tool_selector.
//!
//! The orchestrator does NOT replace agent.zig's loop — it sits BEFORE the
//! loop, producing an OrchestratorPlan that the loop consumes. The loop
//! still handles tool dispatch, compaction, repair, etc.

const std = @import("std");
const routing = @import("../routing.zig");
const tools = @import("../tools.zig");
const cloud = @import("../cloud/root.zig");
const intent_taxonomy = @import("intent_taxonomy.zig");
const tool_selector = @import("tool_selector.zig");

/// A single step in the orchestrated plan. Owned by OrchestratorPlan.
pub const Step = struct {
    allocator: std.mem.Allocator,
    step_num: u32,
    goal: []u8,
    suggested_tools: [][]u8,
    context_needed: [][]u8,

    pub fn deinit(self: *Step) void {
        self.allocator.free(self.goal);
        for (self.suggested_tools) |t| self.allocator.free(t);
        self.allocator.free(self.suggested_tools);
        for (self.context_needed) |c| self.allocator.free(c);
        self.allocator.free(self.context_needed);
        self.* = undefined;
    }
};

/// The orchestrated plan: intent + capability + steps + tool selection.
/// Produced by the orchestrator from either a backend PrepareResponse or
/// a native heuristic fallback.
pub const OrchestratorPlan = struct {
    allocator: std.mem.Allocator,
    intent: intent_taxonomy.Intent,
    confidence: f32,
    /// The capability profile to use for this plan.
    profile: tools.CapabilityProfile,
    /// Multi-step plan (empty for single-step tasks).
    steps: []Step,
    /// The minimal tool set for this intent.
    selected_tools: tool_selector.ToolSelection,
    /// Recommended max_steps for the agent loop.
    max_steps: u32,
    /// Whether the plan came from the backend LLM (true) or native heuristic (false).
    used_llm: bool,

    pub fn deinit(self: *OrchestratorPlan) void {
        for (self.steps) |*s| s.deinit();
        self.allocator.free(self.steps);
        self.* = undefined;
    }
};

/// Build an OrchestratorPlan from a backend PrepareResponse.
/// Transfers ownership of the response's data into the plan.
pub fn fromPrepareResponse(
    allocator: std.mem.Allocator,
    resp: cloud.PrepareResponse,
) !OrchestratorPlan {
    // Parse the intent string into taxonomy. Fall back to heuristic if unknown.
    const intent = intent_taxonomy.parseIntent(resp.intent) orelse .edit_code;
    const profile = intent.defaultCapability();
    const selected = tool_selector.selectForIntent(intent);

    // Convert backend PlanSteps into native Steps (transfer ownership).
    const steps = try allocator.alloc(Step, resp.plan.len);
    var steps_written: usize = 0;
    errdefer {
        for (steps[0..steps_written]) |*s| s.deinit();
        allocator.free(steps);
    }
    for (resp.plan) |backend_step| {
        // Copy goal.
        const goal = try allocator.dupe(u8, backend_step.goal);
        errdefer allocator.free(goal);

        // Copy suggested_tools.
        const st = try allocator.alloc([]u8, backend_step.suggested_tools.len);
        var st_written: usize = 0;
        errdefer {
            for (st[0..st_written]) |t| allocator.free(t);
            allocator.free(st);
        }
        for (backend_step.suggested_tools) |t| {
            st[st_written] = try allocator.dupe(u8, t);
            st_written += 1;
        }

        // Copy context_needed.
        const cn = try allocator.alloc([]u8, backend_step.context_needed.len);
        var cn_written: usize = 0;
        errdefer {
            for (cn[0..cn_written]) |c| allocator.free(c);
            allocator.free(cn);
        }
        for (backend_step.context_needed) |c| {
            cn[cn_written] = try allocator.dupe(u8, c);
            cn_written += 1;
        }

        steps[steps_written] = .{
            .allocator = allocator,
            .step_num = backend_step.step,
            .goal = goal,
            .suggested_tools = st,
            .context_needed = cn,
        };
        steps_written += 1;
    }

    // Use the backend's max_steps hint if confidence is high; otherwise use
    // the taxonomy default.
    const max_steps = if (resp.confidence >= 0.7 and steps.len > 0)
        @max(intent.defaultMaxSteps(), @as(u32, @intCast(steps.len)))
    else
        intent.defaultMaxSteps();

    return OrchestratorPlan{
        .allocator = allocator,
        .intent = intent,
        .confidence = resp.confidence,
        .profile = profile,
        .steps = steps,
        .selected_tools = selected,
        .max_steps = max_steps,
        .used_llm = resp.used_llm,
    };
}

/// Build an OrchestratorPlan from native heuristic (no backend call).
/// Used when forge_cloud is not configured or the backend is unreachable.
pub fn fromHeuristic(intent_text: []const u8) !OrchestratorPlan {
    const intent = intent_taxonomy.heuristicClassify(intent_text);
    const selected = tool_selector.selectForIntent(intent);
    return OrchestratorPlan{
        .allocator = std.heap.page_allocator,
        .intent = intent,
        .confidence = 0.5, // heuristic confidence
        .profile = intent.defaultCapability(),
        .steps = &.{}, // no multi-step plan from heuristic
        .selected_tools = selected,
        .max_steps = intent.defaultMaxSteps(),
        .used_llm = false,
    };
}

/// Summarize the plan as a human-readable string (for logging/debugging).
pub fn summarize(plan: OrchestratorPlan, buf: []u8) ![]const u8 {
    var fbs = std.Io.Writer.fixed(buf);
    try fbs.print("intent={s} confidence={d:.2} profile={s} max_steps={d} used_llm={} steps={d}", .{
        plan.intent.label(),
        plan.confidence,
        @tagName(plan.profile),
        plan.max_steps,
        plan.used_llm,
        plan.steps.len,
    });
    return fbs.buffered();
}

// ─── Tests ─────────────────────────────────────────────────────────────

test "fromHeuristic produces a valid plan" {
    var plan = try fromHeuristic("rename getUser to fetchUser");
    _ = &plan;
    defer plan.deinit();
    try std.testing.expectEqual(intent_taxonomy.Intent.refactor, plan.intent);
    try std.testing.expectEqual(tools.CapabilityProfile.propose_and_task, plan.profile);
    try std.testing.expect(plan.max_steps >= 16);
    try std.testing.expect(!plan.used_llm);
    try std.testing.expectEqual(@as(usize, 0), plan.steps.len);
}

test "fromHeuristic: answer question gets read-only profile" {
    var plan = try fromHeuristic("explain what this function does");
    _ = &plan;
    defer plan.deinit();
    try std.testing.expectEqual(intent_taxonomy.Intent.answer_question, plan.intent);
    try std.testing.expectEqual(tools.CapabilityProfile.read_only, plan.profile);
}

test "fromPrepareResponse: maps intent + copies steps" {
    // Build a fake PrepareResponse.
    const resp_intent: []u8 = try std.testing.allocator.dupe(u8, "refactor");
    const resp_tools: [][]u8 = try std.testing.allocator.alloc([]u8, 2);
    resp_tools[0] = try std.testing.allocator.dupe(u8, "read_file");
    resp_tools[1] = try std.testing.allocator.dupe(u8, "search");
    const resp_ctx: [][]u8 = try std.testing.allocator.alloc([]u8, 1);
    resp_ctx[0] = try std.testing.allocator.dupe(u8, "src/main.ts");
    const resp_goal: []u8 = try std.testing.allocator.dupe(u8, "Read main.ts");

    const plan_step = cloud.PlanStep{
        .allocator = std.testing.allocator,
        .step = 1,
        .goal = resp_goal,
        .suggested_tools = resp_tools,
        .context_needed = resp_ctx,
    };

    var plan_steps = try std.testing.allocator.alloc(cloud.PlanStep, 1);
    defer std.testing.allocator.free(plan_steps);
    plan_steps[0] = plan_step;

    const resp_suggested: [][]u8 = try std.testing.allocator.alloc([]u8, 3);
    defer std.testing.allocator.free(resp_suggested);
    resp_suggested[0] = try std.testing.allocator.dupe(u8, "read_file");
    resp_suggested[1] = try std.testing.allocator.dupe(u8, "search");
    resp_suggested[2] = try std.testing.allocator.dupe(u8, "multi_edit");

    const resp = cloud.PrepareResponse{
        .allocator = std.testing.allocator,
        .intent = resp_intent,
        .confidence = 0.9,
        .plan = plan_steps,
        .suggested_tools = resp_suggested,
        .used_llm = true,
        .latency_ms = 850,
    };

    var plan = try fromPrepareResponse(std.testing.allocator, resp);
    _ = &plan;
    defer plan.deinit();

    try std.testing.expectEqual(intent_taxonomy.Intent.refactor, plan.intent);
    try std.testing.expectEqual(@as(f32, 0.9), plan.confidence);
    try std.testing.expect(plan.used_llm);
    try std.testing.expectEqual(@as(usize, 1), plan.steps.len);
    try std.testing.expectEqual(@as(u32, 1), plan.steps[0].step_num);
    try std.testing.expectEqualStrings("Read main.ts", plan.steps[0].goal);
    try std.testing.expectEqual(@as(usize, 2), plan.steps[0].suggested_tools.len);
    try std.testing.expectEqualStrings("read_file", plan.steps[0].suggested_tools[0]);
    try std.testing.expectEqualStrings("src/main.ts", plan.steps[0].context_needed[0]);

    // fromPrepareResponse COPIES resp's data (via allocator.dupe), so the
    // caller still owns the original resp arrays + their inner strings.
    // Free them all here.
    std.testing.allocator.free(resp_intent);
    // Free inner strings of resp_tools, then the array.
    for (resp_tools) |t| std.testing.allocator.free(t);
    std.testing.allocator.free(resp_tools);
    // Free inner strings of resp_ctx, then the array.
    for (resp_ctx) |c| std.testing.allocator.free(c);
    std.testing.allocator.free(resp_ctx);
    std.testing.allocator.free(resp_goal);
    // plan_steps + resp_suggested arrays freed by defer above.
    // resp_suggested's inner strings owned by us — free here.
    for (resp_suggested) |s| std.testing.allocator.free(s);
}

test "fromPrepareResponse: unknown intent falls back to edit_code" {
    const resp_intent: []u8 = try std.testing.allocator.dupe(u8, "unknown_intent_xyz");
    defer std.testing.allocator.free(resp_intent);
    const resp_suggested: [][]u8 = try std.testing.allocator.alloc([]u8, 0);
    defer std.testing.allocator.free(resp_suggested);

    const resp = cloud.PrepareResponse{
        .allocator = std.testing.allocator,
        .intent = resp_intent,
        .confidence = 0.3,
        .plan = &.{},
        .suggested_tools = resp_suggested,
        .used_llm = true,
        .latency_ms = 100,
    };

    var plan = try fromPrepareResponse(std.testing.allocator, resp);
    _ = &plan;
    defer plan.deinit();
    try std.testing.expectEqual(intent_taxonomy.Intent.edit_code, plan.intent);
}

test "summarize produces readable string" {
    var plan = try fromHeuristic("fix the bug");
    _ = &plan;
    defer plan.deinit();
    var buf: [256]u8 = undefined;
    const s = try summarize(plan, &buf);
    try std.testing.expect(std.mem.indexOf(u8, s, "intent=debug_failure") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "used_llm=false") != null);
}
