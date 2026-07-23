const std = @import("std");
const workspace = @import("forge-workspace");
const executor_types = @import("executor_types.zig");

const AgentToolError = executor_types.AgentToolError;
const Context = executor_types.Context;
const Outcome = executor_types.Outcome;
const checkCancel = executor_types.checkCancel;
const requireTool = executor_types.requireTool;

pub fn spawnSubagent(ctx: Context, role: []const u8, prompt: []const u8) AgentToolError!Outcome {
    try checkCancel(ctx);
    try requireTool(ctx, .spawn_subagent);

    const SubagentContext = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        root: workspace.WorkspaceRoot,
        environ_map: ?*const std.process.Environ.Map,
        role: []const u8,
        prompt: []const u8,
        stream_callback: ?*const fn (?*anyopaque, []const u8) void,
        stream_context: ?*anyopaque,
    };

    const sub_ctx = ctx.allocator.create(SubagentContext) catch {
        const summary = std.fmt.allocPrint(ctx.allocator, "Sub-agent '{s}': failed to allocate context", .{role}) catch return error.WorkspaceFailed;
        return .{ .summary = summary };
    };

    const role_owned = ctx.allocator.dupe(u8, role) catch {
        ctx.allocator.destroy(sub_ctx);
        const summary = std.fmt.allocPrint(ctx.allocator, "Sub-agent '{s}': failed to dupe role", .{role}) catch return error.WorkspaceFailed;
        return .{ .summary = summary };
    };
    const prompt_owned = ctx.allocator.dupe(u8, prompt) catch {
        ctx.allocator.free(role_owned);
        ctx.allocator.destroy(sub_ctx);
        const summary = std.fmt.allocPrint(ctx.allocator, "Sub-agent '{s}': failed to dupe prompt", .{role}) catch return error.WorkspaceFailed;
        return .{ .summary = summary };
    };

    sub_ctx.* = .{
        .allocator = ctx.allocator,
        .io = ctx.io,
        .root = ctx.root,
        .environ_map = ctx.environ_map,
        .role = role_owned,
        .prompt = prompt_owned,
        .stream_callback = ctx.stream_callback,
        .stream_context = ctx.stream_context,
    };

    const thread = std.Thread.spawn(.{}, subagentWorker, .{sub_ctx}) catch {
        ctx.allocator.free(role_owned);
        ctx.allocator.free(prompt_owned);
        ctx.allocator.destroy(sub_ctx);
        const summary = std.fmt.allocPrint(ctx.allocator, "Sub-agent '{s}': failed to spawn thread (running synchronously)", .{role}) catch return error.WorkspaceFailed;
        return .{ .summary = summary };
    };
    thread.detach();

    const summary = std.fmt.allocPrint(ctx.allocator, "Sub-agent '{s}' spawned on background thread. Prompt: {s:.120}", .{ role, prompt }) catch return error.WorkspaceFailed;
    return .{ .summary = summary };
}

fn subagentWorker(sub_ctx: anytype) void {
    defer {
        sub_ctx.allocator.free(sub_ctx.role);
        sub_ctx.allocator.free(sub_ctx.prompt);
        sub_ctx.allocator.destroy(sub_ctx);
    }

    const agent_mod = @import("../agent.zig");
    const provider_factory = @import("../provider_factory.zig");

    var provider_handle = provider_factory.create(sub_ctx.allocator, sub_ctx.io, sub_ctx.environ_map, .{
        .provider_name = "fake",
        .fake_response = "Sub-agent completed (no real provider configured).",
    }) catch {
        if (sub_ctx.stream_callback) |cb| {
            const msg = "Sub-agent failed: provider creation error";
            cb(sub_ctx.stream_context, msg);
        }
        return;
    };
    defer provider_handle.deinit(sub_ctx.allocator);

    var result = agent_mod.run(sub_ctx.allocator, sub_ctx.io, sub_ctx.environ_map, sub_ctx.root, sub_ctx.prompt, .{
        .max_steps = 3,
        .provider_options = .{
            .provider_name = "fake",
            .fake_response = "Sub-agent completed (no real provider configured).",
        },
        .mode = .ask,
        .capability_profile = .read_only,
        .max_repair_attempts = 0,
    }) catch {
        if (sub_ctx.stream_callback) |cb| {
            const msg = "Sub-agent failed: agent.run error";
            cb(sub_ctx.stream_context, msg);
        }
        return;
    };
    defer agent_mod.deinitResult(sub_ctx.allocator, &result);

    if (sub_ctx.stream_callback) |cb| {
        if (result.response_text) |text| {
            cb(sub_ctx.stream_context, text);
        } else {
            const fallback = "Sub-agent completed (no response text)";
            cb(sub_ctx.stream_context, fallback);
        }
    }
}
