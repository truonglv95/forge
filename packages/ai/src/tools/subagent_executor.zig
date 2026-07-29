const std = @import("std");
const workspace = @import("forge-workspace");
const executor_types = @import("executor_types.zig");

const AgentToolError = executor_types.AgentToolError;
const Context = executor_types.Context;
const Outcome = executor_types.Outcome;
const checkCancel = executor_types.checkCancel;
const requireTool = executor_types.requireTool;

/// spawnSubagent — spawns a focused sub-agent for a sub-task.
///
/// SYNCHRONOUS EXECUTION (Claude Code Task tool parity):
///   - Runs agent_mod.run() synchronously (blocks until subagent completes)
///   - Returns the subagent's response text in the Outcome summary
///   - Parent agent can use the result immediately
///
/// CAPABILITY MODEL:
///   - read_only roles (planner, reviewer, custom): read-only, max 5 steps
///   - implementer role: propose capability, max 10 steps (can edit files)
///   - repair_log_reader: read-only, max 3 steps (quick log scan)
///   - repair_test_writer: propose, max 8 steps (can write test files)
///
/// This replaces the previous fire-and-forget detached thread approach
/// which made subagent results inaccessible to the parent agent.
pub fn spawnSubagent(ctx: Context, role: []const u8, prompt: []const u8) AgentToolError!Outcome {
    try checkCancel(ctx);
    try requireTool(ctx, .spawn_subagent);

    const agent_mod = @import("../agent.zig");

    // Determine capability profile and step budget based on role.
    const RoleConfig = struct {
        capability: @import("../tools.zig").CapabilityProfile,
        max_steps: u32,
        mode: @import("../tools.zig").Mode,
    };
    const role_config: RoleConfig = if (std.mem.eql(u8, role, "implementer"))
        .{ .capability = .propose, .max_steps = 10, .mode = .agent }
    else if (std.mem.eql(u8, role, "repair_test_writer"))
        .{ .capability = .propose, .max_steps = 8, .mode = .agent }
    else if (std.mem.eql(u8, role, "repair_log_reader"))
        .{ .capability = .read_only, .max_steps = 3, .mode = .ask }
    else if (std.mem.eql(u8, role, "planner"))
        .{ .capability = .read_only, .max_steps = 6, .mode = .plan }
    else if (std.mem.eql(u8, role, "reviewer"))
        .{ .capability = .read_only, .max_steps = 5, .mode = .ask }
    else // "custom" or unknown
        .{ .capability = .read_only, .max_steps = 5, .mode = .ask };

    // Build provider options — use "auto" to resolve from env vars.
    const provider_opts = @import("../provider_factory.zig").Options{
        .provider_name = "auto",
    };

    // Run the subagent SYNCHRONOUSLY (blocks until completion).
    // The result is returned to the parent agent immediately.
    var result = agent_mod.run(ctx.allocator, ctx.io, ctx.environ_map, ctx.root, prompt, .{
        .max_steps = role_config.max_steps,
        .provider_options = provider_opts,
        .mode = role_config.mode,
        .capability_profile = role_config.capability,
        .max_repair_attempts = 0,
        .workspace_cwd = ctx.cwd,
    }) catch {
        const summary = std.fmt.allocPrint(ctx.allocator, "Sub-agent '{s}' failed: agent.run error", .{role}) catch return error.WorkspaceFailed;
        return .{ .summary = summary };
    };
    defer agent_mod.deinitResult(ctx.allocator, &result);

    // Format the result for the parent agent.
    const response_text = result.response_text orelse "(sub-agent completed with no response text)";
    const summary = std.fmt.allocPrint(ctx.allocator, "Sub-agent '{s}' ({s}, {d} steps): {s}", .{ role, @tagName(role_config.capability), role_config.max_steps, response_text }) catch return error.WorkspaceFailed;

    return .{ .summary = summary };
}
