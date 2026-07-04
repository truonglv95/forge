const std = @import("std");
const workspace = @import("forge-workspace");
const kernel = @import("forge-kernel");
const provider_factory = @import("provider_factory.zig");
const planner = @import("planner.zig");
const context_loader = @import("context_loader.zig");
const run_record = @import("run_record.zig");
const tools = @import("tools.zig");
const tool_executor = @import("tool_executor.zig");
const progress = @import("progress.zig");

pub const Config = struct {
    max_steps: u32 = 8,
    provider_options: provider_factory.Options,
    capability_profile: tools.CapabilityProfile = .propose,
    workspace_cwd: []const u8 = ".",
    cancel_token: ?*const kernel.cancellation.CancellationToken = null,
    progress_writer: ?*std.Io.Writer = null,
    progress_json: bool = false,
};

pub const Step = struct {
    index: u32,
    kind: []const u8,
    summary: []const u8,
    run_id: ?[]const u8 = null,
};

pub const Result = struct {
    session_id: []const u8,
    steps: []Step,
    final_run_id: ?[]const u8,
    proposal_rel: ?[]const u8,
};

pub const AgentError = error{
    StepLimitReached,
    ProviderFailed,
    WorkspaceFailed,
    Cancelled,
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    root: workspace.WorkspaceRoot,
    intent: []const u8,
    config: Config,
) AgentError!Result {
    var provider_handle = provider_factory.create(allocator, io, environ_map, config.provider_options) catch {
        return error.ProviderFailed;
    };
    defer provider_handle.deinit();

    var steps: std.ArrayList(Step) = .empty;
    errdefer deinitSteps(allocator, steps.items);

    const timestamp_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    const session_id = workspace.sessions.makeSessionId(allocator, timestamp_ms) catch return error.WorkspaceFailed;
    errdefer allocator.free(session_id);

    var ctx_builder = context_loader.build(allocator, io, root, .{ .intent = intent, .explicit_files = &.{} }) catch return error.WorkspaceFailed;
    defer ctx_builder.deinit();
    emitProgress(config, .context_built);

    const tool_ctx = tool_executor.Context{
        .allocator = allocator,
        .io = io,
        .root = root,
        .cwd = config.workspace_cwd,
        .profile = config.capability_profile,
        .cancel_token = config.cancel_token,
    };

    var next_index: u32 = 1;
    var first_match_path: ?[]const u8 = null;
    errdefer if (first_match_path) |path| allocator.free(path);

    var search_term_buf: [128]u8 = undefined;
    const search_term = firstToken(intent, &search_term_buf);
    if (search_term.len > 0) {
        const search_out = tool_executor.search(tool_ctx, search_term) catch |err| return mapToolError(err);
        defer allocator.free(search_out.summary);
        first_match_path = search_out.first_match_path;
        try appendStep(allocator, &steps, next_index, "search", search_out.summary, null);
        next_index += 1;
    }

    if (config.max_steps >= 3 and tools.isAllowed(config.capability_profile, .list_tree)) {
        if (config.max_steps < next_index + 1) return error.StepLimitReached;
        const tree_out = tool_executor.listTree(tool_ctx) catch |err| return mapToolError(err);
        defer allocator.free(tree_out.summary);
        try appendStep(allocator, &steps, next_index, "list_tree", tree_out.summary, null);
        next_index += 1;
    }

    if (config.max_steps >= 4 and tools.isAllowed(config.capability_profile, .read_file)) {
        if (first_match_path) |rel_path| {
            if (config.max_steps < next_index + 1) return error.StepLimitReached;
            const read_out = tool_executor.readFile(tool_ctx, rel_path) catch |err| return mapToolError(err);
            defer allocator.free(read_out.summary);
            try appendStep(allocator, &steps, next_index, "read_file", read_out.summary, null);
            next_index += 1;
        }
    }

    if (config.max_steps < next_index) return error.StepLimitReached;
    if (!tools.isAllowed(config.capability_profile, .propose_edit)) return error.StepLimitReached;

    const provider = provider_handle.interface();
    var planner_inst = planner.Planner.init(allocator, provider, &ctx_builder);

    var response = std.Io.Writer.Allocating.init(allocator);
    defer response.deinit();

    var cancel_src = kernel.cancellation.CancellationTokenSource.init(allocator) catch return error.ProviderFailed;
    defer cancel_src.deinit();
    var local_token = cancel_src.getToken();
    const cancel_token: *const kernel.cancellation.CancellationToken = config.cancel_token orelse &local_token;

    emitProgress(config, .sending);
    planner_inst.plan(&response.writer, cancel_token) catch return error.ProviderFailed;
    emitProgress(config, .streaming);
    emitProgress(config, .parsing);

    const run_id = run_record.makeRunId(allocator, timestamp_ms + 1) catch return error.WorkspaceFailed;
    errdefer allocator.free(run_id);

    const proposal_body = response.writer.buffer[0..response.writer.end];
    var proposal_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const proposal_rel = std.fmt.bufPrint(&proposal_path_buf, ".forge/proposals/{s}.json", .{run_id}) catch return error.WorkspaceFailed;

    workspace.history.ensureLayout(io, root) catch return error.WorkspaceFailed;
    workspace.atomic.replaceFile(io, root, workspace.WorkspacePath.parse(proposal_rel) catch return error.WorkspaceFailed, proposal_body) catch return error.WorkspaceFailed;

    const meta = provider.metadata();
    const record = run_record.Record{
        .run_id = run_id,
        .surface = .cli,
        .intent = intent,
        .state = .proposed,
        .proposal_path = proposal_rel,
        .provider_id = meta.provider_name,
        .model_id = meta.model_name,
        .timestamp_ms = timestamp_ms + 1,
    };

    const json_body = run_record.formatJson(allocator, record) catch return error.WorkspaceFailed;
    defer allocator.free(json_body);
    workspace.runs.persistRun(io, root, run_id, json_body) catch return error.WorkspaceFailed;

    const index_line = run_record.formatIndexLine(allocator, record) catch return error.WorkspaceFailed;
    defer allocator.free(index_line);
    workspace.runs.appendIndex(allocator, io, root, index_line) catch return error.WorkspaceFailed;

    const propose_summary = std.fmt.allocPrint(allocator, "proposal at {s}", .{proposal_rel}) catch return error.WorkspaceFailed;
    try appendStep(allocator, &steps, next_index, "propose", propose_summary, run_id);
    emitProgress(config, .proposal_ready);

    const owned_steps = steps.toOwnedSlice(allocator) catch return error.WorkspaceFailed;
    const owned_run_id = allocator.dupe(u8, run_id) catch return error.WorkspaceFailed;
    const owned_proposal = allocator.dupe(u8, proposal_rel) catch return error.WorkspaceFailed;
    const owned_session = allocator.dupe(u8, session_id) catch return error.WorkspaceFailed;

    const session_json = formatSessionJson(allocator, owned_session, intent, config, owned_steps, owned_run_id, owned_proposal) catch return error.WorkspaceFailed;
    defer allocator.free(session_json);
    workspace.sessions.persistSession(io, root, owned_session, session_json) catch return error.WorkspaceFailed;

    const session_index = workspace.sessions.formatIndexLine(allocator, owned_session, intent, timestamp_ms) catch return error.WorkspaceFailed;
    defer allocator.free(session_index);
    workspace.sessions.appendIndex(allocator, io, root, session_index) catch return error.WorkspaceFailed;

    return .{
        .session_id = owned_session,
        .steps = owned_steps,
        .final_run_id = owned_run_id,
        .proposal_rel = owned_proposal,
    };
}

pub fn resumeSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    root: workspace.WorkspaceRoot,
    session_id: []const u8,
    config: Config,
) AgentError!Result {
    var doc = workspace.sessions.loadSession(allocator, io, root, session_id) catch |err| switch (err) {
        error.SessionNotFound => return error.WorkspaceFailed,
        else => return error.WorkspaceFailed,
    };
    defer workspace.sessions.deinitSession(allocator, &doc);

    if (doc.proposal_path.len > 0 and doc.run_ids.len > 0) {
        var owned_steps = allocator.alloc(Step, doc.steps.len) catch return error.WorkspaceFailed;
        errdefer {
            deinitSteps(allocator, owned_steps);
            allocator.free(owned_steps);
        }
        for (doc.steps, 0..) |step, index| {
            owned_steps[index] = .{
                .index = step.index,
                .kind = allocator.dupe(u8, step.kind) catch return error.WorkspaceFailed,
                .summary = allocator.dupe(u8, step.summary) catch return error.WorkspaceFailed,
                .run_id = if (step.run_id.len > 0)
                    allocator.dupe(u8, step.run_id) catch return error.WorkspaceFailed
                else
                    null,
            };
        }

        const owned_session = allocator.dupe(u8, doc.session_id) catch return error.WorkspaceFailed;
        const owned_run_id = allocator.dupe(u8, doc.run_ids[doc.run_ids.len - 1]) catch return error.WorkspaceFailed;
        const owned_proposal = allocator.dupe(u8, doc.proposal_path) catch return error.WorkspaceFailed;

        return .{
            .session_id = owned_session,
            .steps = owned_steps,
            .final_run_id = owned_run_id,
            .proposal_rel = owned_proposal,
        };
    }

    return run(allocator, io, environ_map, root, doc.intent, config);
}

pub fn deinitResult(allocator: std.mem.Allocator, result: *Result) void {
    allocator.free(result.session_id);
    deinitSteps(allocator, result.steps);
    allocator.free(result.steps);
    if (result.final_run_id) |id| allocator.free(id);
    if (result.proposal_rel) |path| allocator.free(path);
    result.* = undefined;
}

fn deinitSteps(allocator: std.mem.Allocator, steps: []Step) void {
    for (steps) |step| {
        allocator.free(step.kind);
        allocator.free(step.summary);
        if (step.run_id) |id| allocator.free(id);
    }
}

fn firstToken(intent: []const u8, buffer: []u8) []const u8 {
    var end: usize = 0;
    while (end < intent.len and !std.ascii.isWhitespace(intent[end])) : (end += 1) {}
    const len = @min(end, buffer.len);
    @memcpy(buffer[0..len], intent[0..len]);
    return buffer[0..len];
}

fn appendStep(
    allocator: std.mem.Allocator,
    steps: *std.ArrayList(Step),
    index: u32,
    kind: []const u8,
    summary: []const u8,
    run_id: ?[]const u8,
) AgentError!void {
    steps.append(allocator, .{
        .index = index,
        .kind = allocator.dupe(u8, kind) catch return error.WorkspaceFailed,
        .summary = allocator.dupe(u8, summary) catch return error.WorkspaceFailed,
        .run_id = if (run_id) |id| allocator.dupe(u8, id) catch return error.WorkspaceFailed else null,
    }) catch return error.WorkspaceFailed;
}

fn mapToolError(err: tool_executor.AgentToolError) AgentError {
    return switch (err) {
        error.Cancelled => error.Cancelled,
        error.NotAllowed => error.StepLimitReached,
        error.WorkspaceFailed => error.WorkspaceFailed,
        error.TaskFailed => error.WorkspaceFailed,
    };
}

fn emitProgress(config: Config, phase: progress.Phase) void {
    if (config.progress_json) {
        progress.emitJson(phase, config.progress_writer);
    } else {
        progress.emit(phase, config.progress_writer);
    }
}

fn formatSessionJson(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    intent: []const u8,
    config: Config,
    steps: []Step,
    run_id: []const u8,
    proposal_rel: []const u8,
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
        schema_version: u32 = 1,
        session_id: []const u8,
        intent: []const u8,
        capability_profile: []const u8,
        max_steps: u32,
        run_ids: []const []const u8,
        proposal_path: []const u8,
        tool_calls: []ToolCall,
        steps: []SessionStep,
    };

    const run_ids = try allocator.alloc([]const u8, 1);
    defer allocator.free(run_ids);
    run_ids[0] = run_id;

    return std.json.Stringify.valueAlloc(allocator, SessionDoc{
        .session_id = session_id,
        .intent = intent,
        .capability_profile = @tagName(config.capability_profile),
        .max_steps = config.max_steps,
        .run_ids = run_ids,
        .proposal_path = proposal_rel,
        .tool_calls = tool_items,
        .steps = step_items,
    }, .{});
}

test "agent run produces search and propose steps" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir);
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("sample.txt"), "hello forge search\n");

    const fake_response =
        \\{"schema_version":1,"summary":"agent note","workspace_edit":{"files":[{"path":"agent.txt","operation":"create","edits":[{"start":0,"end":0,"replacement":"from agent\n"}]}]}}
    ;

    var result = try run(allocator, io, null, root, "search sample", .{
        .max_steps = 2,
        .provider_options = .{ .kind = .fake, .fake_response = fake_response },
    });
    defer deinitResult(allocator, &result);

    try std.testing.expectEqual(@as(usize, 2), result.steps.len);
    try std.testing.expect(result.final_run_id != null);
    try std.testing.expect(result.proposal_rel != null);
}
