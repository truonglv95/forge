const std = @import("std");
const trace = @import("trace.zig");

/// Versioned event contract shared by headless CLI, TUI, and IDE renderers.
/// Events are transport-neutral; the current CLI implementation emits them as
/// newline-delimited JSON via `forge agent run --events ndjson`.
pub const schema_version: u32 = 1;
pub const trace_schema_version = trace.schema_version;

pub const Type = enum {
    session_started,
    context_manifest_built,
    run_started,
    llm_turn,
    tool_call,
    tool_result,
    subagent_started,
    subagent_result,
    proposal_created,
    validation_started,
    validation_result,
    final_answer,
    run_completed,
    @"error",
};

pub const ErrorCode = enum {
    step_limit_reached,
    cancelled,
    provider_failed,
    rate_limit_exceeded,
    authentication_failed,
    context_length_exceeded,
    network_error,
    workspace_failed,
    invalid_proposal,
    duplicate_loop,
    no_progress,
    budget_exceeded,
};

pub fn typeName(value: Type) []const u8 {
    return @tagName(value);
}

pub fn errorCodeName(value: ErrorCode) []const u8 {
    return @tagName(value);
}

test "agent event schema names are stable" {
    try std.testing.expectEqual(@as(u32, 1), schema_version);
    try std.testing.expectEqualStrings("tool_call", typeName(.tool_call));
    try std.testing.expectEqualStrings("subagent_started", typeName(.subagent_started));
    try std.testing.expectEqualStrings("rate_limit_exceeded", errorCodeName(.rate_limit_exceeded));
    try std.testing.expectEqualStrings("context_manifest_built", typeName(.context_manifest_built));
    try std.testing.expectEqualStrings("duplicate_loop", errorCodeName(.duplicate_loop));
}

test "agent events are appended to session log" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const abs = try std.fmt.allocPrint(allocator, "/tmp/forge-test-{s}", .{tmp.sub_path});
    defer allocator.free(abs);
    try @import("forge-workspace").global_store.setForgeHomeOverride(abs);
    defer @import("forge-workspace").global_store.clearForgeHomeOverride();
    const root = @import("forge-workspace").WorkspaceRoot.init(tmp.dir, ".");

    // Minimal task; fake provider will propose quickly.
    var result = try @import("agent.zig").run(allocator, io, null, root, "search sample", .{
        .max_steps = 4,
        .provider_options = @import("provider_factory.zig").Options{
            .provider_name = "fake",
            .fake_response = @import("proposal_workflow.zig").default_ask_response,
        },
        .workspace_cwd = ".",
        .mode = .agent,
        .capability_profile = .propose,
        .max_repair_attempts = 0,
    });
    defer @import("agent.zig").deinitResult(allocator, &result);

    const events = @import("forge-workspace").sessions.readEvents(allocator, io, result.session_id) catch {
        try std.testing.expect(false);
        return;
    };
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"type\":\"session_started\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"type\":\"context_manifest_built\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"type\":\"tool_result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"type\":\"run_completed\"") != null);
}

test "validation_result event includes task counts when repair loop runs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const abs = try std.fmt.allocPrint(allocator, "/tmp/forge-test-{s}", .{tmp.sub_path});
    defer allocator.free(abs);
    try @import("forge-workspace").global_store.setForgeHomeOverride(abs);
    defer @import("forge-workspace").global_store.clearForgeHomeOverride();
    const root = @import("forge-workspace").WorkspaceRoot.init(tmp.dir, ".");
    try @import("forge-workspace").atomic.replaceFile(io, root, try @import("forge-workspace").WorkspacePath.parse("build.zig"), ""); // enable zig tasks

    var result = try @import("agent.zig").run(allocator, io, null, root, "search sample", .{
        .max_steps = 4,
        .provider_options = @import("provider_factory.zig").Options{
            .provider_name = "fake",
            .fake_response = @import("proposal_workflow.zig").default_ask_response,
        },
        .workspace_cwd = ".",
        .mode = .agent,
        .capability_profile = .propose,
        .max_repair_attempts = 1,
    });
    defer @import("agent.zig").deinitResult(allocator, &result);

    const events = try @import("forge-workspace").sessions.readEvents(allocator, io, result.session_id);
    defer allocator.free(events);
    // We expect the JSON fields to exist when validation_result is emitted.
    if (std.mem.indexOf(u8, events, "\"type\":\"validation_result\"") != null) {
        try std.testing.expect(std.mem.indexOf(u8, events, "\"task_count\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, events, "\"failed_count\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, events, "\"hint_paths\"") != null);
    }
}

test "multi-agent planner/reviewer subagents emit events when enabled" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const abs = try std.fmt.allocPrint(allocator, "/tmp/forge-test-{s}", .{tmp.sub_path});
    defer allocator.free(abs);
    try @import("forge-workspace").global_store.setForgeHomeOverride(abs);
    defer @import("forge-workspace").global_store.clearForgeHomeOverride();
    const root = @import("forge-workspace").WorkspaceRoot.init(tmp.dir, ".");

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("FORGE_MULTI_AGENT", "1");

    var result = try @import("agent.zig").run(allocator, io, &env, root, "search sample", .{
        .max_steps = 4,
        .provider_options = @import("provider_factory.zig").Options{
            .provider_name = "fake",
            .fake_response = @import("proposal_workflow.zig").default_ask_response,
        },
        .workspace_cwd = ".",
        .mode = .agent,
        .capability_profile = .propose,
        .max_repair_attempts = 0,
    });
    defer @import("agent.zig").deinitResult(allocator, &result);

    const events = try @import("forge-workspace").sessions.readEvents(allocator, io, result.session_id);
    defer allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"type\":\"subagent_started\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"type\":\"subagent_result\"") != null);
}
