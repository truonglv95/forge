const std = @import("std");
const workspace = @import("forge-workspace");
const kernel = @import("forge-kernel");
const provider_mod = @import("provider.zig");
const provider_factory = @import("provider_factory.zig");
const planner = @import("planner.zig");
const context_loader = @import("context_loader.zig");
const run_record = @import("run_record.zig");
const tools = @import("tools.zig");
const tool_registry = @import("tools/registry.zig");
const tool_executor = @import("tool_executor.zig");
const proposal_workflow = @import("proposal_workflow.zig");
const conversation = @import("conversation.zig");
const multimodal = @import("multimodal.zig");
const agent_loop = @import("agent/loop.zig");
const mcp_registry = @import("mcp_registry.zig");
const progress = @import("progress.zig");
const validation_hints = @import("validation_hints.zig");
const repair_loop = @import("repair_loop.zig");
const subagent = @import("subagent.zig");
const routing = @import("routing.zig");
const context_manifest = @import("context_manifest.zig");

pub const Config = struct {
    max_steps: u32 = 8,
    provider_options: provider_factory.Options,
    mode: tools.Mode = .agent,
    capability_profile: tools.CapabilityProfile = .propose,
    workspace_cwd: []const u8 = ".",
    mcp_enabled: bool = true,
    explicit_files: []const []const u8 = &.{},
    active_file: ?[]const u8 = null,
    has_selection: bool = false,
    attachments: []const context_loader.AttachmentInput = &.{},
    conversation: []const conversation.Turn = &.{},
    recent_files: []const []const u8 = &.{},
    surface: run_record.Surface = .cli,
    cancel_token: ?*const kernel.cancellation.CancellationToken = null,
    progress_writer: ?*std.Io.Writer = null,
    progress_json: bool = false,
    progress_callback: ?*const fn (?*anyopaque, progress.Phase) void = null,
    progress_context: ?*anyopaque = null,
    step_callback: ?*const fn (?*anyopaque, Step) void = null,
    step_context: ?*anyopaque = null,
    step_begin_callback: ?*const fn (?*anyopaque, StepBegin) void = null,
    step_begin_context: ?*anyopaque = null,
    turn_callback: ?*const fn (?*anyopaque, u32) void = null,
    turn_context: ?*anyopaque = null,
    edit_callback: ?*const fn (?*anyopaque, path: []const u8, start_line: usize, end_line: usize, replacement: []const u8) void = null,
    edit_context: ?*anyopaque = null,
    use_inline_edits: bool = false,
    resume_conversation_json: []const u8 = "",
    resume_next_step_index: u32 = 1,
    resume_pending_tool: []const u8 = "",
    resume_pending_tool_args: []const u8 = "",
    resume_session_id: ?[]const u8 = null,
    resume_steps: []const Step = &.{},
    approval_callback: ?agent_loop.ApprovalCallback = null,
    approval_context: ?*anyopaque = null,
    approve_every_time_tools: bool = false,
    max_repair_attempts: u8 = 0,
};

pub const Step = struct {
    index: u32,
    kind: []const u8,
    summary: []const u8,
    run_id: ?[]const u8 = null,
};

pub const StepBegin = struct {
    index: u32,
    tool_name: []const u8,
};

pub const Result = struct {
    session_id: []const u8,
    steps: []Step,
    final_run_id: ?[]const u8,
    proposal_rel: ?[]const u8,
    repair_attempts: u8 = 0,
    usage: provider_mod.TokenUsage = .{},
    response_text: ?[]const u8 = null,
};

pub const AgentError = error{
    StepLimitReached,
    ProviderFailed,
    WorkspaceFailed,
    Cancelled,
    InvalidProposal,
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
    errdefer {
        deinitSteps(allocator, steps.items);
        steps.deinit(allocator);
    }
    for (config.resume_steps) |step| {
        try appendStep(allocator, &steps, step.index, step.kind, step.summary, step.run_id, config);
    }

    const timestamp_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    const session_id = if (config.resume_session_id) |existing|
        allocator.dupe(u8, existing) catch return error.WorkspaceFailed
    else
        workspace.sessions.makeSessionId(allocator, timestamp_ms) catch return error.WorkspaceFailed;
    defer allocator.free(session_id);

    if (config.resume_session_id == null) {
        const session_index = workspace.sessions.formatIndexLine(allocator, session_id, intent, timestamp_ms) catch return error.WorkspaceFailed;
        defer allocator.free(session_index);
        workspace.sessions.appendIndex(allocator, io, root, session_index) catch return error.WorkspaceFailed;
    }

    const route = routing.plan(.{
        .mode = config.mode,
        .intent = intent,
        .has_active_file = config.active_file != null,
        .has_selection = config.has_selection,
    }, .{
        .intent = intent,
        .explicit_files = config.explicit_files,
        .active_file = config.active_file,
        .attachments = config.attachments,
        .include_project_rules = true,
        .workspace_cwd = config.workspace_cwd,
        .recent_files = config.recent_files,
    });

    var ctx_builder = context_loader.build(allocator, io, root, route.context) catch return error.WorkspaceFailed;
    defer ctx_builder.deinit();
    {
        var routing_buf: [128]u8 = undefined;
        const summary = routing.formatRoutingSummary(&routing_buf, .{
            .mode = config.mode,
            .intent = intent,
            .has_active_file = config.active_file != null,
            .has_selection = config.has_selection,
        }, route);
        ctx_builder.addBlock(.intent, "routing", summary) catch {};
    }
    emitProgress(config, .context_built);

    var tool_cache = tool_executor.ToolCache.init(allocator);
    defer tool_cache.deinit();

    var mcp = mcp_registry.Registry.load(allocator, io, root, config.workspace_cwd, config.mcp_enabled, resolveHomeDir(environ_map), environ_map) catch return error.WorkspaceFailed;
    defer mcp.deinit();
    ctx_builder.addBlock(.intent, "mcp", mcp.status_lines) catch {};
    if (mcp.instructions_text.len > 0) ctx_builder.addBlock(.rules, "mcp_instructions", mcp.instructions_text) catch {};
    if (mcp.resources_summary.len > 0) ctx_builder.addBlock(.retrieval, "mcp_resources", mcp.resources_summary) catch {};
    if (mcp.prompts_summary.len > 0) ctx_builder.addBlock(.docs, "mcp_prompts", mcp.prompts_summary) catch {};

    const tool_ctx = tool_executor.Context{
        .allocator = allocator,
        .io = io,
        .root = root,
        .cwd = config.workspace_cwd,
        .profile = config.capability_profile,
        .cancel_token = config.cancel_token,
        .environ_map = environ_map,
        .edit_callback = config.edit_callback,
        .edit_context = config.edit_context,
        .cache = &tool_cache,
    };

    var next_index: u32 = 1;

    var explore_conversation: ?[]u8 = null;
    defer if (explore_conversation) |json| allocator.free(json);
    var explore_text: ?[]u8 = null;
    defer if (explore_text) |text| allocator.free(text);
    const used_native_loop = blk: {
        const llm = provider_handle.interface();
        if (llm.supportsToolLoop()) {
            const NativeCtx = struct {
                allocator: std.mem.Allocator,
                io: std.Io,
                root: workspace.WorkspaceRoot,
                session_id: []const u8,
                intent: []const u8,
                steps: *std.ArrayList(Step),
                config: Config,
                provider_kind: []const u8,

                fn onStep(ctx: ?*anyopaque, index: u32, kind: []const u8, summary: []const u8) void {
                    const self: *@This() = @ptrCast(@alignCast(ctx.?));
                    appendStep(self.allocator, self.steps, index, kind, summary, null, self.config) catch {};
                }

                fn onCheckpoint(ctx: ?*anyopaque, conversation_json: []const u8, next_step_index: u32, pending_tool: []const u8, pending_args_json: []const u8) bool {
                    const self: *@This() = @ptrCast(@alignCast(ctx.?));
                    const body = formatCheckpointSessionJson(
                        self.allocator,
                        self.session_id,
                        self.intent,
                        self.config,
                        self.steps.items,
                        conversation_json,
                        next_step_index,
                        pending_tool,
                        pending_args_json,
                        self.provider_kind,
                        if (pending_tool.len > 0) "tool_pending" else "exploring",
                    ) catch return false;
                    defer self.allocator.free(body);
                    workspace.sessions.persistSession(self.io, self.root, self.session_id, body) catch return false;
                    return true;
                }
            };
            var native_ctx = NativeCtx{
                .allocator = allocator,
                .io = io,
                .root = root,
                .session_id = session_id,
                .intent = intent,
                .steps = &steps,
                .config = config,
                .provider_kind = llm.metadata().provider_name,
            };

            var tool_binding = llm.toolLoopBinding(io, &mcp, config.cancel_token);
            const raw_declarations = llm.toolDeclarationsJson(allocator, &mcp) catch return error.ProviderFailed;
            defer allocator.free(raw_declarations);
            const preloaded_retrieval = context_manifest.hasPreloadedRetrieval(&ctx_builder);
            const declarations = routing.filterDeclarationsForRoute(
                allocator,
                raw_declarations,
                config.capability_profile,
                route.intent,
                intent,
                preloaded_retrieval,
            ) catch return error.ProviderFailed;
            defer allocator.free(declarations);
            var loop_state = try runExploreLoop(
                allocator,
                tool_binding.transport(),
                declarations,
                intent,
                &ctx_builder,
                tool_ctx,
                &mcp,
                config,
                route.intent,
                preloaded_retrieval,
                NativeCtx.onStep,
                &native_ctx,
                NativeCtx.onCheckpoint,
                &native_ctx,
            );
            defer loop_state.deinit(allocator);
            explore_conversation = allocator.dupe(u8, loop_state.conversation_json) catch return error.WorkspaceFailed;
            if (loop_state.final_text) |text| explore_text = allocator.dupe(u8, text) catch return error.WorkspaceFailed;
            break :blk true;
        }
        break :blk false;
    };

    if (used_native_loop) {
        next_index = @as(u32, @intCast(steps.items.len)) + 1;
    } else {
        var first_match_path: ?[]const u8 = null;
        defer if (first_match_path) |path| allocator.free(path);

        var search_term_buf: [128]u8 = undefined;
        const search_term = firstToken(intent, &search_term_buf);
        if (search_term.len > 0) {
            const search_out = tool_executor.search(tool_ctx, search_term) catch |err| return mapToolError(err);
            defer allocator.free(search_out.summary);
            defer allocator.free(search_out.observation);
            first_match_path = search_out.first_match_path;
            try appendStep(allocator, &steps, next_index, "search", search_out.summary, null, config);
            next_index += 1;
        }

        if (config.max_steps >= 3 and tools.isAllowed(config.capability_profile, .list_tree)) {
            if (config.max_steps < next_index + 1) return error.StepLimitReached;
            const tree_out = tool_executor.listTree(tool_ctx, ".", 3) catch |err| return mapToolError(err);
            defer allocator.free(tree_out.summary);
            try appendStep(allocator, &steps, next_index, "list_tree", tree_out.summary, null, config);
            next_index += 1;
        }

        if (config.max_steps >= 4 and tools.isAllowed(config.capability_profile, .read_file)) {
            if (first_match_path) |rel_path| {
                if (config.max_steps < next_index + 1) return error.StepLimitReached;
                const read_out = tool_executor.readFile(tool_ctx, rel_path, null, null) catch |err| return mapToolError(err);
                defer allocator.free(read_out.summary);
                try appendStep(allocator, &steps, next_index, "read_file", read_out.summary, null, config);
                next_index += 1;
            }
        }
    }

    if (config.capability_profile == .read_only) {
        const owned_steps = steps.toOwnedSlice(allocator) catch return error.WorkspaceFailed;
        const owned_session = allocator.dupe(u8, session_id) catch return error.WorkspaceFailed;
        const owned_response = allocator.dupe(u8, explore_text orelse "Exploration complete.") catch return error.WorkspaceFailed;
        const completed_json = formatCheckpointSessionJson(
            allocator,
            session_id,
            intent,
            config,
            owned_steps,
            explore_conversation orelse "",
            next_index,
            "",
            "",
            provider_handle.interface().metadata().provider_name,
            "completed",
        ) catch return error.WorkspaceFailed;
        defer allocator.free(completed_json);
        workspace.sessions.persistSession(io, root, session_id, completed_json) catch return error.WorkspaceFailed;
        return .{
            .session_id = owned_session,
            .steps = owned_steps,
            .final_run_id = null,
            .proposal_rel = null,
            .usage = provider_handle.interface().usage(),
            .response_text = owned_response,
        };
    }

    if (config.max_steps < next_index) return error.StepLimitReached;
    if (!tools.isAllowed(config.capability_profile, .propose_edit)) return error.StepLimitReached;

    if (config.use_inline_edits) {
        const owned_steps = steps.toOwnedSlice(allocator) catch return error.WorkspaceFailed;
        const owned_session = allocator.dupe(u8, session_id) catch return error.WorkspaceFailed;

        // Return without a final proposal run
        return .{
            .session_id = owned_session,
            .steps = owned_steps,
            .final_run_id = null,
            .proposal_rel = null,
            .usage = provider_handle.interface().usage(),
        };
    }

    const llm = provider_handle.interface();
    const images = multimodal.loadImages(allocator, io, root, config.attachments) catch &[_]provider_mod.ImagePart{};
    defer if (images.len > 0) multimodal.freeImages(allocator, images);

    var planner_inst = planner.Planner.init(allocator, llm, &ctx_builder, config.conversation, images);

    var response = std.Io.Writer.Allocating.init(allocator);
    defer response.deinit();

    var cancel_src = kernel.cancellation.CancellationTokenSource.init(allocator) catch return error.ProviderFailed;
    defer cancel_src.deinit();
    var local_token = cancel_src.getToken();
    const cancel_token: *const kernel.cancellation.CancellationToken = config.cancel_token orelse &local_token;

    var final_proposal: ?[]u8 = null;
    defer if (final_proposal) |body| allocator.free(body);
    var validation_report: ?[]u8 = null;
    defer if (validation_report) |report| allocator.free(report);
    var repair_attempt: u8 = 0;
    while (true) {
        response.writer.end = 0;
        if (repair_attempt == 0) {
            emitProgress(config, .sending);
            planner_inst.plan(&response.writer, cancel_token) catch return error.ProviderFailed;
        } else {
            emitProgress(config, .repairing);
            planner_inst.planRepair(&response.writer, cancel_token, validation_report.?, final_proposal.?) catch return error.ProviderFailed;
        }
        emitProgress(config, .streaming);
        emitProgress(config, .parsing);

        const candidate = response.writer.buffer[0..response.writer.end];
        proposal_workflow.validateProposalBody(allocator, candidate) catch return error.InvalidProposal;
        const augmented = validation_hints.augmentProposalJson(allocator, candidate) catch return error.WorkspaceFailed;
        if (final_proposal) |old| allocator.free(old);
        final_proposal = augmented;

        if (config.max_repair_attempts == 0) break;
        const trial = repair_loop.trialApplyAndValidate(allocator, io, root, config.workspace_cwd, final_proposal.?) catch break;
        if (trial.passed or repair_attempt >= config.max_repair_attempts) {
            allocator.free(trial.report);
            break;
        }
        if (validation_report) |old| allocator.free(old);
        validation_report = allocator.dupe(u8, trial.report) catch {
            allocator.free(trial.report);
            return error.WorkspaceFailed;
        };
        allocator.free(trial.report);
        repair_attempt += 1;
    }

    const run_id = run_record.makeRunId(allocator, timestamp_ms + 1) catch return error.WorkspaceFailed;
    defer allocator.free(run_id);

    const augmented_body = final_proposal orelse return error.InvalidProposal;
    var proposal_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const proposal_rel = std.fmt.bufPrint(&proposal_path_buf, ".forge/proposals/{s}.json", .{run_id}) catch return error.WorkspaceFailed;

    workspace.history.ensureLayout(io, root) catch return error.WorkspaceFailed;
    workspace.atomic.replaceFile(io, root, workspace.WorkspacePath.parse(proposal_rel) catch return error.WorkspaceFailed, augmented_body) catch return error.WorkspaceFailed;

    const meta = llm.metadata();
    const record = run_record.Record{
        .run_id = run_id,
        .surface = config.surface,
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
    defer allocator.free(propose_summary);
    try appendStep(allocator, &steps, next_index, "propose", propose_summary, run_id, config);
    emitProgress(config, .proposal_ready);

    const owned_steps = steps.toOwnedSlice(allocator) catch return error.WorkspaceFailed;
    const owned_run_id = allocator.dupe(u8, run_id) catch return error.WorkspaceFailed;
    const owned_proposal = allocator.dupe(u8, proposal_rel) catch return error.WorkspaceFailed;
    const owned_session = allocator.dupe(u8, session_id) catch return error.WorkspaceFailed;

    const session_json = formatSessionJson(
        allocator,
        owned_session,
        intent,
        config,
        owned_steps,
        owned_run_id,
        owned_proposal,
        explore_conversation orelse "",
        llm.metadata().provider_name,
    ) catch return error.WorkspaceFailed;
    defer allocator.free(session_json);
    workspace.sessions.persistSession(io, root, owned_session, session_json) catch return error.WorkspaceFailed;

    return .{
        .session_id = owned_session,
        .steps = owned_steps,
        .final_run_id = owned_run_id,
        .proposal_rel = owned_proposal,
        .repair_attempts = repair_attempt,
        .usage = llm.usage(),
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
            .repair_attempts = 0,
            .usage = .{},
        };
    }

    var prior_steps = allocator.alloc(Step, doc.steps.len) catch return error.WorkspaceFailed;
    defer allocator.free(prior_steps);
    for (doc.steps, 0..) |step, index| {
        prior_steps[index] = .{
            .index = step.index,
            .kind = step.kind,
            .summary = step.summary,
            .run_id = if (step.run_id.len > 0) step.run_id else null,
        };
    }

    var resumed = config;
    if (doc.provider_kind.len > 0 and config.provider_options.kind != .auto and
        !std.mem.eql(u8, doc.provider_kind, @tagName(config.provider_options.kind)))
    {
        return error.ProviderFailed;
    }
    resumed.resume_session_id = doc.session_id;
    resumed.resume_steps = prior_steps;
    resumed.resume_conversation_json = doc.conversation_json;
    resumed.resume_next_step_index = doc.next_step_index;
    resumed.resume_pending_tool = doc.pending_tool;
    resumed.resume_pending_tool_args = doc.pending_tool_args;
    resumed.max_steps = @max(config.max_steps, doc.max_steps);
    resumed.capability_profile = leastPrivilegeProfile(config.capability_profile, parseCapabilityProfile(doc.capability_profile));
    return run(allocator, io, environ_map, root, doc.intent, resumed);
}

fn parseCapabilityProfile(value: []const u8) tools.CapabilityProfile {
    if (std.mem.eql(u8, value, "read_only")) return .read_only;
    if (std.mem.eql(u8, value, "propose_and_task")) return .propose_and_task;
    return .propose;
}

fn leastPrivilegeProfile(a: tools.CapabilityProfile, b: tools.CapabilityProfile) tools.CapabilityProfile {
    return if (@intFromEnum(a) < @intFromEnum(b)) a else b;
}

pub fn deinitResult(allocator: std.mem.Allocator, result: *Result) void {
    allocator.free(result.session_id);
    deinitSteps(allocator, result.steps);
    allocator.free(result.steps);
    if (result.final_run_id) |id| allocator.free(id);
    if (result.proposal_rel) |path| allocator.free(path);
    if (result.response_text) |text| allocator.free(text);
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
    config: Config,
) AgentError!void {
    if (config.step_callback) |callback| {
        const display_kind = subagent.classifyTool(kind).label();
        callback(config.step_context, .{
            .index = index,
            .kind = display_kind,
            .summary = summary,
            .run_id = run_id,
        });
    }
    steps.append(allocator, .{
        .index = index,
        .kind = allocator.dupe(u8, subagent.classifyTool(kind).label()) catch return error.WorkspaceFailed,
        .summary = allocator.dupe(u8, summary) catch return error.WorkspaceFailed,
        .run_id = if (run_id) |id| allocator.dupe(u8, id) catch return error.WorkspaceFailed else null,
    }) catch return error.WorkspaceFailed;
}

fn runExploreLoop(
    allocator: std.mem.Allocator,
    transport: @import("agent/turn.zig").Transport,
    declarations: []const u8,
    intent: []const u8,
    ctx_builder: *const @import("context.zig").ContextBuilder,
    tool_ctx: tool_executor.Context,
    mcp: *mcp_registry.Registry,
    config: Config,
    task_intent: routing.TaskIntent,
    preloaded_retrieval: bool,
    on_step: agent_loop.StepCallback,
    on_step_ctx: ?*anyopaque,
    on_checkpoint: agent_loop.CheckpointCallback,
    on_checkpoint_ctx: ?*anyopaque,
) AgentError!agent_loop.RunState {
    const LoopBridge = struct {
        config: Config,

        fn onTurn(ctx: ?*anyopaque, index: u32) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (self.config.turn_callback) |callback| {
                callback(self.config.turn_context, index);
            }
        }

        fn onStepBegin(ctx: ?*anyopaque, index: u32, tool_name: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (self.config.step_begin_callback) |callback| {
                callback(self.config.step_begin_context, .{ .index = index, .tool_name = tool_name });
            }
        }
    };
    var loop_bridge = LoopBridge{ .config = config };

    return agent_loop.run(allocator, transport, declarations, intent, ctx_builder, tool_ctx, mcp, .{
        .max_tool_steps = config.max_steps,
        .cancel_token = config.cancel_token,
        .turn_callback = if (config.turn_callback != null) LoopBridge.onTurn else null,
        .turn_context = &loop_bridge,
        .step_begin_callback = if (config.step_begin_callback != null) LoopBridge.onStepBegin else null,
        .step_begin_context = &loop_bridge,
        .step_callback = on_step,
        .step_context = on_step_ctx,
        .checkpoint_callback = on_checkpoint,
        .checkpoint_context = on_checkpoint_ctx,
        .initial_conversation_json = config.resume_conversation_json,
        .initial_step_index = config.resume_next_step_index,
        .pending_tool = config.resume_pending_tool,
        .pending_args_json = config.resume_pending_tool_args,
        .approval_callback = config.approval_callback,
        .approval_context = config.approval_context,
        .approve_every_time_tools = config.approve_every_time_tools,
        .task_intent = task_intent,
        .preloaded_retrieval = preloaded_retrieval,
    }) catch |err| switch (err) {
        error.Cancelled => return error.Cancelled,
        error.StepLimitReached => return error.StepLimitReached,
        else => return error.ProviderFailed,
    };
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
    if (config.progress_callback) |callback| {
        callback(config.progress_context, phase);
        return;
    }
    if (config.progress_json) {
        progress.emitJson(phase, config.progress_writer);
    } else {
        progress.emit(phase, config.progress_writer);
    }
}

fn formatCheckpointSessionJson(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    intent: []const u8,
    config: Config,
    steps: []const Step,
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
        provider_kind: []const u8,
    };
    return std.json.Stringify.valueAlloc(allocator, CheckpointDoc{
        .session_id = session_id,
        .intent = intent,
        .capability_profile = @tagName(config.capability_profile),
        .max_steps = config.max_steps,
        .steps = stored_steps,
        .execution_state = execution_state,
        .next_step_index = next_step_index,
        .pending_tool = pending_tool,
        .pending_tool_args = pending_tool_args,
        .conversation_json = conversation_json,
        .provider_kind = provider_kind,
    }, .{});
}

fn formatSessionJson(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    intent: []const u8,
    config: Config,
    steps: []Step,
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
        provider_kind: []const u8,
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
        .execution_state = "proposal_ready",
        .next_step_index = @intCast(steps.len + 1),
        .pending_tool = "",
        .pending_tool_args = "",
        .conversation_json = conversation_json,
        .provider_kind = provider_kind,
    }, .{});
}

fn resolveHomeDir(environ_map: ?*const std.process.Environ.Map) ?[]const u8 {
    if (environ_map) |map| return map.get("HOME");
    return null;
}

test "agent run uses fake tool loop when enabled" {
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
        .max_steps = 4,
        .provider_options = .{ .kind = .fake, .fake_response = fake_response, .fake_tool_loop = true },
    });
    defer deinitResult(allocator, &result);

    try std.testing.expect(result.steps.len >= 2);
    try std.testing.expect(result.final_run_id != null);
    try std.testing.expect(result.proposal_rel != null);
}

test "ask read-only mode explores and returns text without proposal" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir);
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("sample.txt"), "hello ask mode\n");

    var result = try run(allocator, io, null, root, "Explain sample.txt", .{
        .max_steps = 4,
        .capability_profile = .read_only,
        .provider_options = .{
            .kind = .fake,
            .fake_response = proposal_workflow.default_ask_response,
            .fake_tool_loop = true,
            .fake_tool_loop_short = true,
        },
    });
    defer deinitResult(allocator, &result);
    try std.testing.expect(result.final_run_id == null);
    try std.testing.expect(result.proposal_rel == null);
    try std.testing.expect(result.response_text != null);
    try std.testing.expectEqualStrings("Exploration complete.", result.response_text.?);

    var session = try workspace.sessions.loadSession(allocator, io, root, result.session_id);
    defer workspace.sessions.deinitSession(allocator, &session);
    try std.testing.expectEqualStrings("completed", session.execution_state);
    try std.testing.expectEqualStrings("read_only", session.capability_profile);
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

test "agent resumes exact transport conversation after step limit" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir);
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("sample.txt"), "hello forge search\n");

    const fake_response =
        \\{"schema_version":1,"summary":"resumed","workspace_edit":{"files":[{"path":"resumed.txt","operation":"create","edits":[{"start":0,"end":0,"replacement":"ok\\n"}]}]}}
    ;
    try std.testing.expectError(error.StepLimitReached, run(allocator, io, null, root, "search sample", .{
        .max_steps = 1,
        .provider_options = .{ .kind = .fake, .fake_response = fake_response, .fake_tool_loop = true },
    }));

    var sessions = try workspace.sessions.listEntries(allocator, io, root);
    defer sessions.deinit();
    try std.testing.expectEqual(@as(usize, 1), sessions.items.len);
    const session_id = sessions.items[0].session_id;

    var checkpoint = try workspace.sessions.loadSession(allocator, io, root, session_id);
    defer workspace.sessions.deinitSession(allocator, &checkpoint);
    try std.testing.expectEqualStrings("exploring", checkpoint.execution_state);
    try std.testing.expect(checkpoint.conversation_json.len > 0);
    try std.testing.expectEqual(@as(u32, 2), checkpoint.next_step_index);

    var result = try resumeSession(allocator, io, null, root, session_id, .{
        .max_steps = 4,
        .provider_options = .{ .kind = .fake, .fake_response = fake_response, .fake_tool_loop = true },
    });
    defer deinitResult(allocator, &result);
    try std.testing.expectEqualStrings(session_id, result.session_id);
    try std.testing.expect(result.proposal_rel != null);
    try std.testing.expect(result.steps.len >= 3);
}

test "agent recovers crash checkpoint between tool call and tool result" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir);
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("sample.txt"), "hello pending tool\n");

    const conversation_json =
        \\{"role":"user","parts":[{"text":"search sample"}]},{"role":"model","parts":[{"functionCall":{"name":"search","args":{"term":"sample"}}}]}
    ;
    const CrashCheckpoint = struct {
        schema_version: u32 = 3,
        session_id: []const u8 = "sess_crash_pending",
        intent: []const u8 = "search sample",
        capability_profile: []const u8 = "propose",
        max_steps: u32 = 4,
        run_ids: []const []const u8 = &.{},
        proposal_path: []const u8 = "",
        steps: []const workspace.sessions.SessionStep = &.{},
        execution_state: []const u8 = "tool_pending",
        next_step_index: u32 = 1,
        pending_tool: []const u8 = "search",
        pending_tool_args: []const u8 = "{\"term\":\"sample\"}",
        conversation_json: []const u8 = conversation_json,
        provider_kind: []const u8 = "fake",
    };
    const checkpoint_body = try std.json.Stringify.valueAlloc(allocator, CrashCheckpoint{}, .{});
    defer allocator.free(checkpoint_body);
    try workspace.sessions.persistSession(io, root, "sess_crash_pending", checkpoint_body);

    const fake_response =
        \\{"schema_version":1,"summary":"recovered","workspace_edit":{"files":[{"path":"recovered.txt","operation":"create","edits":[{"start":0,"end":0,"replacement":"ok\\n"}]}]}}
    ;
    var result = try resumeSession(allocator, io, null, root, "sess_crash_pending", .{
        .max_steps = 4,
        .provider_options = .{
            .kind = .fake,
            .fake_response = fake_response,
            .fake_tool_loop = true,
            .fake_tool_loop_short = true,
        },
    });
    defer deinitResult(allocator, &result);
    try std.testing.expectEqualStrings("sess_crash_pending", result.session_id);
    try std.testing.expect(result.proposal_rel != null);
    try std.testing.expect(result.steps.len >= 2);
    try std.testing.expectEqualStrings("explore", result.steps[0].kind);
}
