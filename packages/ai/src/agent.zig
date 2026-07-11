const std = @import("std");
const workspace = @import("forge-workspace");
const kernel = @import("forge-kernel");
const provider_mod = @import("provider.zig");
const provider_factory = @import("provider_factory.zig");
const planner = @import("planner.zig");
const context = @import("context.zig");
const context_loader = @import("context_loader.zig");
const codebase_search = @import("codebase_search.zig");
const run_record = @import("run_record.zig");
const tools = @import("tools.zig");
const tool_registry = @import("tools/registry.zig");
const tool_executor = @import("tool_executor.zig");
const proposal_workflow = @import("proposal_workflow.zig");
const conversation = @import("conversation.zig");
const multimodal = @import("multimodal.zig");
const context_phase = @import("agent/context_phase.zig");
const tool_phase = @import("agent/tool_phase.zig");
const agent_compaction = @import("agent/compaction.zig");
const agent_loop = @import("agent/loop.zig");
const mcp_registry = @import("mcp_registry.zig");
const progress = @import("progress.zig");
const validation_hints = @import("validation_hints.zig");
const repair_loop = @import("repair_loop.zig");
const proposal_normalize = @import("proposal_normalize.zig");
const proposal_precondition = @import("proposal_precondition.zig");
const subagent = @import("subagent.zig");
const routing = @import("routing.zig");
const route_resolver = @import("route_resolver.zig");
const context_manifest = @import("context_manifest.zig");
const context_budget = @import("context_budget.zig");
const agent_event = @import("agent_event.zig");

pub const Config = struct {
    max_steps: u32 = 128,
    context_max_bytes: usize = 8 * 1024 * 1024,
    embedding: codebase_search.EmbeddingOptions = .{},
    provider_options: provider_factory.Options,
    mode: tools.Mode = .agent,
    capability_profile: tools.CapabilityProfile = .propose,
    /// When true, the classified intent decides the capability profile
    /// (question/exploration stays read-only, edit/debug unlocks proposals).
    /// Set false when the caller explicitly pinned a capability.
    auto_capability: bool = false,
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
    edit_callback: ?*const fn (?*anyopaque, edit: workspace.edit.WorkspaceEdit) void = null,
    edit_context: ?*anyopaque = null,
    lsp_request_callback: ?*const fn (?*anyopaque, allocator: std.mem.Allocator, method: []const u8, params_json: []const u8) ?[]const u8 = null,
    lsp_context: ?*anyopaque = null,
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
    max_repair_attempts: u8 = 2,
    max_context_recovery_attempts: u8 = 2,
    context_budget_tier: context_budget.BudgetTier = .full,
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
    args_json: []const u8 = "",
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

fn conversationBytes(turns: []const conversation.Turn) usize {
    var total: usize = 0;
    for (turns) |turn| total += turn.content.len;
    return total;
}

fn autoBudgetTier(config: Config, provider_context_window: usize) context_budget.BudgetTier {
    if (config.context_budget_tier != .full) return config.context_budget_tier;
    const convo_bytes = conversationBytes(config.conversation);
    const safe_bytes = context_budget.safePromptBytesForWindow(provider_context_window);
    if (safe_bytes <= 512 * 1024) return .minimal;
    if (convo_bytes > safe_bytes / 3) return .minimal;
    if (convo_bytes > safe_bytes / 6 or config.resume_conversation_json.len > safe_bytes / 5) return .balanced;
    return .full;
}

pub const AgentError = error{
    StepLimitReached,
    ProviderFailed,
    AuthenticationFailed,
    RateLimitExceeded,
    ContextLengthExceeded,
    NetworkError,
    WorkspaceFailed,
    Cancelled,
    InvalidProposal,
    DuplicateLoop,
    NoProgress,
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    root: workspace.WorkspaceRoot,
    intent: []const u8,
    config: Config,
) AgentError!Result {
    var provider_handle = provider_factory.create(allocator, io, environ_map, config.provider_options) catch |err| {
        std.debug.print("Provider factory create failed: {any}\n", .{err});
        return error.ProviderFailed;
    };
    defer provider_handle.deinit(allocator);

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

    var event_logger = EventLogger.init(allocator, io, session_id);
    defer event_logger.deinit();

    var effective_config = config;
    var event_ctx = EventCtx{
        .logger = &event_logger,
        .step_begin_callback = config.step_begin_callback,
        .step_begin_context = config.step_begin_context,
        .step_callback = config.step_callback,
        .step_context = config.step_context,
    };
    effective_config.step_begin_callback = EventCtx.onStepBegin;
    effective_config.step_begin_context = &event_ctx;
    effective_config.step_callback = EventCtx.onStep;
    effective_config.step_context = &event_ctx;

    if (config.resume_session_id == null) {
        const session_index = workspace.sessions.formatIndexLine(allocator, session_id, intent, timestamp_ms, effective_config.workspace_cwd) catch return error.WorkspaceFailed;
        defer allocator.free(session_index);
        workspace.sessions.appendIndex(allocator, io, effective_config.workspace_cwd, session_index) catch return error.WorkspaceFailed;
    }

    event_logger.sessionStarted(effective_config, intent) catch {};

    const route_input = routing.RouteInput{
        .mode = effective_config.mode,
        .intent = intent,
        .has_active_file = effective_config.active_file != null,
        .has_selection = effective_config.has_selection,
    };
    const model_context_bytes = context_budget.safePromptBytesForWindow(provider_handle.metadata().context_window);
    const context_max_bytes = @min(effective_config.context_max_bytes, model_context_bytes);
    effective_config.context_budget_tier = autoBudgetTier(effective_config, provider_handle.metadata().context_window);
    const load_opts = context_loader.LoadOptions{
        .intent = intent,
        .explicit_files = effective_config.explicit_files,
        .active_file = effective_config.active_file,
        .attachments = effective_config.attachments,
        .include_project_rules = true,
        .workspace_cwd = effective_config.workspace_cwd,
        .recent_files = effective_config.recent_files,
        .max_bytes = context_max_bytes,
        .embedding = effective_config.embedding,
    };

    var resolved_context = context_phase.build(allocator, io, root, .{
        .route = route_input,
        .load = load_opts,
        .provider = if (effective_config.auto_capability and config.resume_session_id == null) provider_handle else null,
        .cancel_token = effective_config.cancel_token,
        .resolver = .{ .use_llm = effective_config.auto_capability and config.resume_session_id == null },
        .budget_tier = effective_config.context_budget_tier,
    }) catch return error.WorkspaceFailed;
    defer resolved_context.deinit();
    const resolved_route = resolved_context.route;
    const route = resolved_route.route;

    // Let the classified intent pick the least-privilege capability unless the
    // caller pinned one explicitly. On resume we keep the persisted profile.
    if (effective_config.auto_capability and config.resume_session_id == null) {
        effective_config.capability_profile = route.capability_profile;
    }

    var ctx_builder = &resolved_context.builder;
    emitProgress(effective_config, .context_built);
    event_logger.contextManifestBuilt(ctx_builder) catch {};

    var tool_cache = tool_executor.ToolCache.init(allocator);
    defer tool_cache.deinit();

    var mcp = mcp_registry.Registry.load(allocator, io, root, effective_config.workspace_cwd, effective_config.mcp_enabled, resolveHomeDir(environ_map), environ_map) catch return error.WorkspaceFailed;
    defer mcp.deinit();
    ctx_builder.addBlock(.intent, "mcp", mcp.status_lines) catch {};
    if (mcp.instructions_text.len > 0) ctx_builder.addBlock(.rules, "mcp_instructions", mcp.instructions_text) catch {};
    if (mcp.resources_summary.len > 0) ctx_builder.addBlock(.retrieval, "mcp_resources", mcp.resources_summary) catch {};
    if (mcp.prompts_summary.len > 0) ctx_builder.addBlock(.docs, "mcp_prompts", mcp.prompts_summary) catch {};

    const tool_ctx = tool_executor.Context{
        .allocator = allocator,
        .io = io,
        .root = root,
        .cwd = effective_config.workspace_cwd,
        .profile = effective_config.capability_profile,
        .cancel_token = effective_config.cancel_token,
        .environ_map = environ_map,
        .edit_callback = effective_config.edit_callback,
        .edit_context = effective_config.edit_context,
        .lsp_request_callback = effective_config.lsp_request_callback,
        .lsp_context = effective_config.lsp_context,
        .cache = &tool_cache,
    };

    var next_index: u32 = 1;

    var explore_conversation: ?[]u8 = null;
    defer if (explore_conversation) |json| allocator.free(json);
    var explore_text: ?[]u8 = null;
    defer if (explore_text) |text| allocator.free(text);
    const used_native_loop = blk: {
        const llm = provider_handle;
        const NativeCtx = struct {
            allocator: std.mem.Allocator,
            io: std.Io,
            workspace_path: []const u8,
            session_id: []const u8,
            intent: []const u8,
            steps: *std.ArrayList(Step),
            config: Config,
            provider_kind: []const u8,

            fn onTurn(ctx: ?*anyopaque, index: u32) void {
                const self: *@This() = @ptrCast(@alignCast(ctx.?));
                if (self.config.turn_callback) |callback| {
                    callback(self.config.turn_context, index);
                }
            }

            fn onStepBegin(ctx: ?*anyopaque, index: u32, tool_name: []const u8, args_json: []const u8) void {
                const self: *@This() = @ptrCast(@alignCast(ctx.?));
                if (self.config.step_begin_callback) |callback| {
                    callback(self.config.step_begin_context, .{ .index = index, .tool_name = tool_name, .args_json = args_json });
                }
            }

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
                workspace.sessions.persistSession(self.io, self.workspace_path, self.session_id, body) catch return false;
                return true;
            }
        };
        var native_ctx = NativeCtx{
            .allocator = allocator,
            .io = io,
            .workspace_path = effective_config.workspace_cwd,
            .session_id = session_id,
            .intent = intent,
            .steps = &steps,
            .config = effective_config,
            .provider_kind = llm.metadata().provider_name,
        };

        if (tool_phase.runNative(allocator, .{
            .io = io,
            .llm = llm,
            .mcp = &mcp,
            .intent = intent,
            .ctx_builder = ctx_builder,
            .tool_ctx = tool_ctx,
            .profile = effective_config.capability_profile,
            .task_intent = route.intent,
            .max_steps = effective_config.max_steps,
            .cancel_token = effective_config.cancel_token,
            .turn_callback = if (effective_config.turn_callback != null) NativeCtx.onTurn else null,
            .turn_context = &native_ctx,
            .step_begin_callback = if (effective_config.step_begin_callback != null) NativeCtx.onStepBegin else null,
            .step_begin_context = &native_ctx,
            .step_callback = NativeCtx.onStep,
            .step_context = &native_ctx,
            .checkpoint_callback = NativeCtx.onCheckpoint,
            .checkpoint_context = &native_ctx,
            .initial_conversation_json = effective_config.resume_conversation_json,
            .initial_step_index = effective_config.resume_next_step_index,
            .pending_tool = effective_config.resume_pending_tool,
            .pending_args_json = effective_config.resume_pending_tool_args,
            .approval_callback = effective_config.approval_callback,
            .approval_context = effective_config.approval_context,
            .approve_every_time_tools = effective_config.approve_every_time_tools,
            .max_context_recovery_attempts = effective_config.max_context_recovery_attempts,
        })) |maybe_loop_state| {
            var loop_state = maybe_loop_state orelse break :blk false;
            defer loop_state.deinit(allocator);
            explore_conversation = allocator.dupe(u8, loop_state.conversation_json) catch return error.WorkspaceFailed;
            if (loop_state.final_text) |text| explore_text = allocator.dupe(u8, text) catch return error.WorkspaceFailed;
            break :blk true;
        } else |err| switch (err) {
            error.Cancelled => return error.Cancelled,
            error.AuthenticationFailed => return error.AuthenticationFailed,
            error.RateLimitExceeded => return error.RateLimitExceeded,
            error.ContextLengthExceeded => return error.ContextLengthExceeded,
            error.NetworkError => return error.NetworkError,
            error.StepLimitReached => return error.StepLimitReached,
            error.DuplicateLoop => return error.DuplicateLoop,
            error.NoProgress => return error.NoProgress,
            else => return error.ProviderFailed,
        }
    };

    if (used_native_loop) {
        next_index = @as(u32, @intCast(steps.items.len)) + 1;
    } else {
        var first_match_path: ?[]const u8 = null;
        defer if (first_match_path) |path| allocator.free(path);

        var search_term_buf: [128]u8 = undefined;
        const search_term = firstToken(intent, &search_term_buf);
        if (search_term.len > 0) {
            const search_out = tool_executor.search(tool_ctx, .{
                .pattern = search_term,
                .path = ".",
            }) catch |err| return mapToolError(err);
            defer allocator.free(search_out.summary);
            defer allocator.free(search_out.observation);
            first_match_path = search_out.first_match_path;
            try appendStep(allocator, &steps, next_index, "search", search_out.summary, null, effective_config);
            next_index += 1;
        }

        if (effective_config.max_steps >= 3 and tools.isAllowed(effective_config.capability_profile, .list_tree)) {
            if (effective_config.max_steps < next_index + 1) return error.StepLimitReached;
            const tree_out = tool_executor.listTree(tool_ctx, ".", 3) catch |err| return mapToolError(err);
            defer allocator.free(tree_out.summary);
            try appendStep(allocator, &steps, next_index, "list_tree", tree_out.summary, null, effective_config);
            next_index += 1;
        }

        if (effective_config.max_steps >= 4 and tools.isAllowed(effective_config.capability_profile, .read_file)) {
            if (first_match_path) |rel_path| {
                if (effective_config.max_steps < next_index + 1) return error.StepLimitReached;
                const read_out = tool_executor.readFile(tool_ctx, rel_path, null, null) catch |err| return mapToolError(err);
                defer allocator.free(read_out.summary);
                try appendStep(allocator, &steps, next_index, "read_file", read_out.summary, null, effective_config);
                next_index += 1;
            }
        }
    }

    if (effective_config.capability_profile == .read_only) {
        const owned_steps = steps.toOwnedSlice(allocator) catch return error.WorkspaceFailed;
        const owned_session = allocator.dupe(u8, session_id) catch return error.WorkspaceFailed;
        const owned_response = allocator.dupe(u8, explore_text orelse "Exploration complete.") catch return error.WorkspaceFailed;
        const completed_json = formatCheckpointSessionJson(
            allocator,
            session_id,
            intent,
            effective_config,
            owned_steps,
            explore_conversation orelse "",
            next_index,
            "",
            "",
            provider_handle.metadata().provider_name,
            "completed",
        ) catch return error.WorkspaceFailed;
        defer allocator.free(completed_json);
        workspace.sessions.persistSession(io, effective_config.workspace_cwd, session_id, completed_json) catch return error.WorkspaceFailed;
        event_logger.finalAnswer(owned_response) catch {};
        event_logger.runCompleted(.{ .steps = owned_steps, .proposal_rel = null, .response_text = owned_response, .repair_attempts = 0, .usage = provider_handle.usage() }) catch {};
        return .{
            .session_id = owned_session,
            .steps = owned_steps,
            .final_run_id = null,
            .proposal_rel = null,
            .usage = provider_handle.usage(),
            .response_text = owned_response,
        };
    }

    if (effective_config.use_inline_edits) {
        const owned_steps = steps.toOwnedSlice(allocator) catch return error.WorkspaceFailed;
        const owned_session = allocator.dupe(u8, session_id) catch return error.WorkspaceFailed;
        const owned_response = allocator.dupe(u8, explore_text orelse "Edited files directly.") catch return error.WorkspaceFailed;

        event_logger.finalAnswer(owned_response) catch {};
        event_logger.runCompleted(.{ .steps = owned_steps, .proposal_rel = null, .response_text = owned_response, .repair_attempts = 0, .usage = provider_handle.usage() }) catch {};
        return .{
            .session_id = owned_session,
            .steps = owned_steps,
            .final_run_id = null,
            .proposal_rel = null,
            .usage = provider_handle.usage(),
            .response_text = owned_response,
        };
    }

    if (effective_config.max_steps < next_index) return error.StepLimitReached;
    if (!tools.isAllowed(effective_config.capability_profile, .propose_edit)) return error.StepLimitReached;

    const llm = provider_handle;
    const images = multimodal.loadImages(allocator, io, root, config.attachments) catch &[_]provider_mod.ImagePart{};
    defer if (images.len > 0) multimodal.freeImages(allocator, images);

    var planner_inst = planner.Planner.init(allocator, llm, ctx_builder, effective_config.conversation, images);

    var response = std.Io.Writer.Allocating.init(allocator);
    defer response.deinit();

    var cancel_src = kernel.cancellation.CancellationTokenSource.init(allocator) catch return error.ProviderFailed;
    defer cancel_src.deinit();
    var local_token = cancel_src.getToken();
    const cancel_token: *const kernel.cancellation.CancellationToken = effective_config.cancel_token orelse &local_token;

    var final_proposal: ?[]u8 = null;
    defer if (final_proposal) |body| allocator.free(body);
    var validation_report: ?[]u8 = null;
    defer if (validation_report) |report| allocator.free(report);
    if (maybeRunPlannerSubagent(
        allocator,
        io,
        environ_map,
        &planner_inst,
        cancel_token,
        ctx_builder,
        &event_logger,
    )) |plan_text_opt| {
        if (plan_text_opt) |plan_text| {
            defer allocator.free(plan_text);
            ctx_builder.addBlock(.retrieval, "subagent:plan", plan_text) catch {};
        }
    } else |_| {}
    var repair_attempt: u8 = 0;
    var use_repair_prompt = false;
    var json_repair_attempts: u8 = 0;
    while (true) {
        response.writer.end = 0;
        if (!use_repair_prompt) {
            emitProgress(effective_config, .sending);
            planner_inst.plan(&response.writer, cancel_token) catch return error.ProviderFailed;
        } else {
            emitProgress(effective_config, .repairing);
            planner_inst.planRepair(
                &response.writer,
                cancel_token,
                validation_report orelse "proposal JSON parse/validation failed",
                final_proposal orelse "",
            ) catch return error.ProviderFailed;
        }
        emitProgress(effective_config, .streaming);
        emitProgress(effective_config, .parsing);

        const candidate = response.writer.buffer[0..response.writer.end];
        const normalized = proposal_normalize.normalize(allocator, candidate) catch {
            if (json_repair_attempts < 2) {
                json_repair_attempts += 1;
                use_repair_prompt = true;
                if (validation_report) |old| allocator.free(old);
                validation_report = std.fmt.allocPrint(
                    allocator,
                    "proposal JSON normalization failed. Output ONLY a raw JSON object for schema_version 1.\n\nModel output (truncated):\n{s}",
                    .{clipText(candidate, 1500)},
                ) catch null;
                if (final_proposal) |old| allocator.free(old);
                final_proposal = allocator.dupe(u8, candidate) catch return error.InvalidProposal;
                continue;
            }
            return error.InvalidProposal;
        };
        defer allocator.free(normalized);

        const prepared = proposal_precondition.fillMissingExpectedHashes(allocator, io, root, normalized) catch normalized;
        defer if (prepared.ptr != normalized.ptr) allocator.free(prepared);

        proposal_workflow.validateProposalBody(allocator, prepared) catch {
            if (json_repair_attempts < 2) {
                json_repair_attempts += 1;
                use_repair_prompt = true;
                if (validation_report) |old| allocator.free(old);
                validation_report = std.fmt.allocPrint(
                    allocator,
                    "proposal JSON validation failed. For modify/delete include expected_hash from context, or rely on file snapshots. Output ONLY valid WorkspaceEdit JSON (schema_version 1). No markdown fences or commentary.\n\nModel output (truncated):\n{s}",
                    .{clipText(prepared, 1500)},
                ) catch null;
                if (final_proposal) |old| allocator.free(old);
                final_proposal = allocator.dupe(u8, prepared) catch return error.InvalidProposal;
                continue;
            }
            return error.InvalidProposal;
        };
        use_repair_prompt = false;

        const augmented = validation_hints.augmentProposalJson(allocator, prepared) catch return error.WorkspaceFailed;
        if (final_proposal) |old| allocator.free(old);
        final_proposal = augmented;

        if (config.max_repair_attempts == 0) break;
        if (maybeRunReviewerSubagent(
            allocator,
            io,
            environ_map,
            llm,
            &mcp,
            effective_config,
            cancel_token,
            augmented,
            &event_logger,
        )) |review_text_opt| {
            if (review_text_opt) |review_text| {
                defer allocator.free(review_text);
            }
            // Feed review findings into the subsequent repair prompt via validation_report.
            if (validation_report) |old| allocator.free(old);
            validation_report = std.fmt.allocPrint(allocator, "review:\n{s}\n", .{review_text_opt orelse ""}) catch null;
        } else |_| {}
        event_logger.validationStarted(repair_attempt + 1) catch {};
        const trial = repair_loop.trialApplyAndValidate(allocator, io, root, config.workspace_cwd, final_proposal.?) catch break;
        event_logger.validationResult(repair_attempt + 1, trial.passed, trial.task_count, trial.failed_count, trial.hint_paths, trial.report) catch {};
        if (trial.passed or repair_attempt >= config.max_repair_attempts) {
            if (trial.hint_paths.len > 0) {
                for (trial.hint_paths) |p| allocator.free(p);
                allocator.free(trial.hint_paths);
            }
            allocator.free(trial.report);
            break;
        }
        if (validation_report) |old| allocator.free(old);
        var evidence: ?[]const u8 = null;
        defer if (evidence) |e| allocator.free(e);
        if (trial.hint_paths.len > 0 and tools.isAllowed(effective_config.capability_profile, .read_file)) {
            if (effective_config.max_steps >= next_index + 1) {
                if (tool_executor.readFile(tool_ctx, trial.hint_paths[0], null, null)) |read_out| {
                    evidence = read_out.summary;
                    try appendStep(allocator, &steps, next_index, "read_file", evidence.?, null, effective_config);
                    next_index += 1;
                } else |_| {}
            }
        }

        var prompt_report: []const u8 = trial.report;
        defer if (prompt_report.ptr != trial.report.ptr) allocator.free(prompt_report);
        if (evidence) |ev| {
            prompt_report = std.fmt.allocPrint(allocator, "evidence (current workspace):\n{s}\n\n{s}", .{ ev, trial.report }) catch trial.report;
        }

        const augmented_report = maybeAugmentValidationReportWithSubagents(
            allocator,
            io,
            environ_map,
            llm,
            &mcp,
            tool_ctx,
            &event_logger,
            effective_config,
            route.intent,
            prompt_report,
        ) catch null;
        defer if (augmented_report) |rep| allocator.free(rep);
        validation_report = allocator.dupe(u8, augmented_report orelse trial.report) catch {
            if (trial.hint_paths.len > 0) {
                for (trial.hint_paths) |p| allocator.free(p);
                allocator.free(trial.hint_paths);
            }
            allocator.free(trial.report);
            return error.WorkspaceFailed;
        };
        if (trial.hint_paths.len > 0) {
            for (trial.hint_paths) |p| allocator.free(p);
            allocator.free(trial.hint_paths);
        }
        allocator.free(trial.report);
        use_repair_prompt = true;
        repair_attempt += 1;
    }

    const run_id = run_record.makeRunId(allocator, timestamp_ms + 1) catch return error.WorkspaceFailed;
    defer allocator.free(run_id);

    const augmented_body = final_proposal orelse return error.InvalidProposal;
    // Store proposal in session dir: ~/.forge/sessions/<hash>/proposals/<run_id>.json
    const session_dir_ag = workspace.global_store.getSessionDir(allocator, io, root) catch return error.WorkspaceFailed;
    defer allocator.free(session_dir_ag);
    var prop_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const prop_dir_abs = std.fmt.bufPrint(&prop_dir_buf, "{s}/proposals", .{session_dir_ag}) catch return error.WorkspaceFailed;
    workspace.global_store.mkdirAllAbsolute(prop_dir_abs) catch {};
    var proposal_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const proposal_abs = std.fmt.bufPrint(&proposal_path_buf, "{s}/proposals/{s}.json", .{ session_dir_ag, run_id }) catch return error.WorkspaceFailed;

    workspace.history.ensureLayout(allocator, io, root) catch return error.WorkspaceFailed;
    workspace.global_store.replaceAbsoluteFile(io, proposal_abs, augmented_body) catch return error.WorkspaceFailed;

    const meta = llm.metadata();
    const record = run_record.Record{
        .run_id = run_id,
        .surface = config.surface,
        .intent = intent,
        .state = .proposed,
        .proposal_path = proposal_abs,
        .provider_id = meta.provider_name,
        .model_id = meta.model_name,
        .timestamp_ms = timestamp_ms + 1,
    };

    const json_body = run_record.formatJson(allocator, record) catch return error.WorkspaceFailed;
    defer allocator.free(json_body);
    workspace.runs.persistRun(allocator, io, root, run_id, json_body) catch return error.WorkspaceFailed;

    const index_line = run_record.formatIndexLine(allocator, record) catch return error.WorkspaceFailed;
    defer allocator.free(index_line);
    workspace.runs.appendIndex(allocator, io, root, index_line) catch return error.WorkspaceFailed;

    const propose_summary = std.fmt.allocPrint(allocator, "proposal at {s}", .{proposal_abs}) catch return error.WorkspaceFailed;
    defer allocator.free(propose_summary);
    try appendStep(allocator, &steps, next_index, "propose", propose_summary, run_id, effective_config);
    emitProgress(effective_config, .proposal_ready);

    const owned_steps = steps.toOwnedSlice(allocator) catch return error.WorkspaceFailed;
    const owned_run_id = allocator.dupe(u8, run_id) catch return error.WorkspaceFailed;
    const owned_proposal = allocator.dupe(u8, proposal_abs) catch return error.WorkspaceFailed;
    const owned_session = allocator.dupe(u8, session_id) catch return error.WorkspaceFailed;

    const session_json = formatSessionJson(
        allocator,
        owned_session,
        intent,
        effective_config,
        owned_steps,
        owned_run_id,
        owned_proposal,
        explore_conversation orelse "",
        llm.metadata().provider_name,
    ) catch return error.WorkspaceFailed;
    defer allocator.free(session_json);
    workspace.sessions.persistSession(io, effective_config.workspace_cwd, owned_session, session_json) catch return error.WorkspaceFailed;

    event_logger.proposalCreated(owned_proposal) catch {};
    event_logger.runCompleted(.{
        .steps = owned_steps,
        .proposal_rel = owned_proposal,
        .response_text = null,
        .repair_attempts = repair_attempt,
        .usage = llm.usage(),
    }) catch {};

    return .{
        .session_id = owned_session,
        .steps = owned_steps,
        .final_run_id = owned_run_id,
        .proposal_rel = owned_proposal,
        .repair_attempts = repair_attempt,
        .usage = llm.usage(),
    };
}

fn maybeAugmentValidationReportWithSubagents(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    llm: anytype,
    mcp: *mcp_registry.Registry,
    tool_ctx: tool_executor.Context,
    event_logger: *EventLogger,
    config: Config,
    task_intent: routing.TaskIntent,
    report: []const u8,
) !?[]u8 {
    // Default-off. Enable with FORGE_SUBAGENTS=1, and only for debug_failure intent.
    if (task_intent != .debug_failure) return null;
    const enabled = blk: {
        const map = environ_map orelse break :blk false;
        const value = map.get("FORGE_SUBAGENTS") orelse break :blk false;
        break :blk std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "yes");
    };
    if (!enabled) return null;

    const specs = subagent.repairSpecs();
    if (specs.len == 0) return null;

    const clipped_report = if (report.len > 4096) report[0..4096] else report;

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try out.writer.writeAll(clipped_report);

    var binding = llm.toolLoopBinding(io, mcp, config.cancel_token);
    const raw_declarations = llm.toolDeclarationsJson(allocator, mcp) catch return null;
    defer allocator.free(raw_declarations);

    const preloaded_retrieval = false;
    var spec_index: usize = 0;
    while (spec_index < specs.len) : (spec_index += 1) {
        const spec = specs[spec_index];
        event_logger.subagentStarted(spec.role.label(), spec.label) catch {};
        const sub_intent = std.fmt.allocPrint(allocator, "{s}\n\n# Validation report\n{s}\n", .{ spec.prompt, clipped_report }) catch continue;
        defer allocator.free(sub_intent);

        const sub_route = route_resolver.resolve(
            allocator,
            .{
                .mode = .agent,
                .intent = sub_intent,
                .has_active_file = config.active_file != null,
                .has_selection = config.has_selection,
            },
            .{
                .intent = sub_intent,
                .explicit_files = config.explicit_files,
                .active_file = config.active_file,
                .attachments = &.{},
                .include_project_rules = true,
                .workspace_cwd = config.workspace_cwd,
                .recent_files = &.{},
                .max_bytes = spec.max_bytes,
            },
            llm,
            config.cancel_token,
            .{},
        ).route;
        var sub_ctx_builder = context_loader.build(allocator, io, tool_ctx.root, sub_route.context) catch continue;
        defer sub_ctx_builder.deinit();

        const declarations = routing.filterDeclarationsForRoute(
            allocator,
            raw_declarations,
            .read_only,
            sub_route.intent,
            sub_intent,
            preloaded_retrieval,
        ) catch continue;
        defer allocator.free(declarations);

        var sub_tool_ctx = tool_ctx;
        sub_tool_ctx.profile = .read_only;

        const Noop = struct {
            fn onStep(_: ?*anyopaque, _: u32, _: []const u8, _: []const u8) void {}
            fn onCheckpoint(_: ?*anyopaque, _: []const u8, _: u32, _: []const u8, _: []const u8) bool {
                return false;
            }
        };
        var loop_state = tool_phase.runTransport(
            allocator,
            binding.transport(),
            declarations,
            sub_intent,
            &sub_ctx_builder,
            sub_tool_ctx,
            mcp,
            .{
                .max_tool_steps = spec.max_steps,
                .cancel_token = config.cancel_token,
                .step_callback = Noop.onStep,
                .step_context = null,
                .checkpoint_callback = Noop.onCheckpoint,
                .checkpoint_context = null,
                .task_intent = .debug_failure,
                .preloaded_retrieval = preloaded_retrieval,
            },
        ) catch continue;
        defer loop_state.deinit(allocator);

        if (loop_state.final_text) |text| {
            event_logger.subagentResult(spec.role.label(), spec.label, text) catch {};
            try out.writer.print("\n\n# {s}\n{s}\n", .{ spec.label, text });
        }
    }

    return try allocator.dupe(u8, out.writer.buffered());
}

fn multiAgentEnabled(environ_map: ?*const std.process.Environ.Map) bool {
    const map = environ_map orelse return false;
    const value = map.get("FORGE_MULTI_AGENT") orelse return false;
    return std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "yes");
}

fn maybeRunPlannerSubagent(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    planner_inst: *planner.Planner,
    cancel_token: *const kernel.cancellation.CancellationToken,
    ctx_builder: *const context.ContextBuilder,
    event_logger: *EventLogger,
) !?[]u8 {
    _ = io;
    _ = ctx_builder;
    if (!multiAgentEnabled(environ_map)) return null;
    const spec = subagent.plannerSpec();
    event_logger.subagentStarted(spec.role.label(), spec.label) catch {};
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    planner_inst.planMarkdown(&out.writer, cancel_token) catch return null;
    const text = out.writer.buffered();
    event_logger.subagentResult(spec.role.label(), spec.label, text) catch {};
    return try allocator.dupe(u8, text);
}

fn maybeRunReviewerSubagent(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    llm: provider_mod.Provider,
    mcp: *mcp_registry.Registry,
    config: Config,
    cancel_token: *const kernel.cancellation.CancellationToken,
    proposal_json: []const u8,
    event_logger: *EventLogger,
) !?[]u8 {
    _ = mcp;
    _ = config;
    if (!multiAgentEnabled(environ_map)) return null;
    const spec = subagent.reviewerSpec();
    event_logger.subagentStarted(spec.role.label(), spec.label) catch {};

    var prompt = std.Io.Writer.Allocating.init(allocator);
    defer prompt.deinit();
    try prompt.writer.print("{s}\n\n--- PROPOSAL JSON ---\n{s}\n", .{ spec.prompt, proposal_json });

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    llm.ask(allocator, prompt.writer.buffered(), &.{}, &out.writer, cancel_token) catch return null;
    const text = out.writer.buffered();
    event_logger.subagentResult(spec.role.label(), spec.label, text) catch {};
    _ = io;
    return try allocator.dupe(u8, text);
}

pub fn resumeSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    root: workspace.WorkspaceRoot,
    session_id: []const u8,
    config: Config,
) AgentError!Result {
    var doc = workspace.sessions.loadSession(allocator, io, session_id) catch |err| switch (err) {
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
    if (doc.provider_kind.len > 0 and !std.mem.eql(u8, config.provider_options.provider_name, "auto") and
        !std.mem.eql(u8, doc.provider_kind, config.provider_options.provider_name))
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

fn mapToolError(err: tool_executor.AgentToolError) AgentError {
    return switch (err) {
        error.Cancelled => error.Cancelled,
        error.NotAllowed => error.StepLimitReached,
        error.WorkspaceFailed => error.WorkspaceFailed,
        error.TaskFailed => error.WorkspaceFailed,
    };
}

const EventLogger = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    session_id: []const u8,

    fn init(allocator: std.mem.Allocator, io: std.Io, session_id: []const u8) EventLogger {
        return .{ .allocator = allocator, .io = io, .session_id = session_id };
    }

    fn deinit(_: *EventLogger) void {}

    fn appendJson(self: *EventLogger, json: []const u8) !void {
        try workspace.sessions.appendEvent(self.allocator, self.io, self.session_id, json);
    }

    fn sessionStarted(self: *EventLogger, config: Config, intent: []const u8) !void {
        const Json = struct {
            schema_version: u32 = agent_event.schema_version,
            type: []const u8 = agent_event.typeName(.session_started),
            intent: []const u8,
            mode: []const u8,
            capability: []const u8,
            max_steps: u32,
        };
        const json = try std.json.Stringify.valueAlloc(self.allocator, Json{
            .intent = intent,
            .mode = @tagName(config.mode),
            .capability = @tagName(config.capability_profile),
            .max_steps = config.max_steps,
        }, .{});
        defer self.allocator.free(json);
        try self.appendJson(json);
    }

    fn contextManifestBuilt(self: *EventLogger, builder: *const context.ContextBuilder) !void {
        var has_import_neighbors = false;
        for (builder.blocks.items) |block| {
            if (block.block_type == .imports) {
                has_import_neighbors = true;
                break;
            }
        }
        const Json = struct {
            schema_version: u32 = agent_event.schema_version,
            type: []const u8 = agent_event.typeName(.context_manifest_built),
            budget_bytes: usize,
            used_bytes: usize,
            blocks: usize,
            has_import_neighbors: bool,
        };
        const json = try std.json.Stringify.valueAlloc(self.allocator, Json{
            .budget_bytes = builder.max_bytes,
            .used_bytes = builder.used_bytes,
            .blocks = builder.blocks.items.len,
            .has_import_neighbors = has_import_neighbors,
        }, .{});
        defer self.allocator.free(json);
        try self.appendJson(json);
    }

    fn toolCall(self: *EventLogger, step: u32, tool: []const u8, args_json: []const u8) !void {
        const Json = struct {
            schema_version: u32 = agent_event.schema_version,
            type: []const u8 = agent_event.typeName(.tool_call),
            step: u32,
            tool: []const u8,
            reason: []const u8,
            args_preview: []const u8,
            args_json: []const u8,
        };
        const preview = argsPreview(args_json);
        const reason = toolReason(tool);
        const json = try std.json.Stringify.valueAlloc(self.allocator, Json{
            .step = step,
            .tool = tool,
            .reason = reason,
            .args_preview = preview,
            .args_json = args_json,
        }, .{});
        defer self.allocator.free(json);
        try self.appendJson(json);
    }

    fn toolResult(self: *EventLogger, step: u32, kind: []const u8, summary: []const u8, run_id: ?[]const u8) !void {
        const Json = struct {
            schema_version: u32 = agent_event.schema_version,
            type: []const u8 = agent_event.typeName(.tool_result),
            step: u32,
            kind: []const u8,
            summary: []const u8,
            run_id: []const u8,
        };
        const json = try std.json.Stringify.valueAlloc(self.allocator, Json{
            .step = step,
            .kind = kind,
            .summary = summary,
            .run_id = run_id orelse "",
        }, .{});
        defer self.allocator.free(json);
        try self.appendJson(json);
    }

    fn proposalCreated(self: *EventLogger, proposal_path: []const u8) !void {
        const Json = struct {
            schema_version: u32 = agent_event.schema_version,
            type: []const u8 = agent_event.typeName(.proposal_created),
            proposal_path: []const u8,
        };
        const json = try std.json.Stringify.valueAlloc(self.allocator, Json{ .proposal_path = proposal_path }, .{});
        defer self.allocator.free(json);
        try self.appendJson(json);
    }

    fn validationStarted(self: *EventLogger, attempt: u8) !void {
        const Json = struct {
            schema_version: u32 = agent_event.schema_version,
            type: []const u8 = agent_event.typeName(.validation_started),
            attempt: u8,
        };
        const json = try std.json.Stringify.valueAlloc(self.allocator, Json{ .attempt = attempt }, .{});
        defer self.allocator.free(json);
        try self.appendJson(json);
    }

    fn validationResult(self: *EventLogger, attempt: u8, passed: bool, task_count: u32, failed_count: u32, hint_paths: []const []const u8, report: []const u8) !void {
        const Json = struct {
            schema_version: u32 = agent_event.schema_version,
            type: []const u8 = agent_event.typeName(.validation_result),
            attempt: u8,
            passed: bool,
            task_count: u32,
            failed_count: u32,
            hint_paths: []const []const u8,
            report: []const u8,
        };
        const json = try std.json.Stringify.valueAlloc(self.allocator, Json{
            .attempt = attempt,
            .passed = passed,
            .task_count = task_count,
            .failed_count = failed_count,
            .hint_paths = hint_paths,
            .report = if (report.len > 2048) report[0..2048] else report,
        }, .{});
        defer self.allocator.free(json);
        try self.appendJson(json);
    }

    fn subagentStarted(self: *EventLogger, role: []const u8, label: []const u8) !void {
        const Json = struct {
            schema_version: u32 = agent_event.schema_version,
            type: []const u8 = agent_event.typeName(.subagent_started),
            role: []const u8,
            label: []const u8,
        };
        const json = try std.json.Stringify.valueAlloc(self.allocator, Json{
            .role = role,
            .label = label,
        }, .{});
        defer self.allocator.free(json);
        try self.appendJson(json);
    }

    fn subagentResult(self: *EventLogger, role: []const u8, label: []const u8, text: []const u8) !void {
        const Json = struct {
            schema_version: u32 = agent_event.schema_version,
            type: []const u8 = agent_event.typeName(.subagent_result),
            role: []const u8,
            label: []const u8,
            text_preview: []const u8,
        };
        const json = try std.json.Stringify.valueAlloc(self.allocator, Json{
            .role = role,
            .label = label,
            .text_preview = if (text.len > 2048) text[0..2048] else text,
        }, .{});
        defer self.allocator.free(json);
        try self.appendJson(json);
    }

    fn finalAnswer(self: *EventLogger, text: []const u8) !void {
        const Json = struct {
            schema_version: u32 = agent_event.schema_version,
            type: []const u8 = agent_event.typeName(.final_answer),
            text: []const u8,
        };
        const json = try std.json.Stringify.valueAlloc(self.allocator, Json{ .text = text }, .{});
        defer self.allocator.free(json);
        try self.appendJson(json);
    }

    fn runCompleted(self: *EventLogger, payload: struct {
        steps: []const Step,
        proposal_rel: ?[]const u8,
        response_text: ?[]const u8,
        repair_attempts: u8,
        usage: provider_mod.TokenUsage,
    }) !void {
        const Json = struct {
            schema_version: u32 = agent_event.schema_version,
            type: []const u8 = agent_event.typeName(.run_completed),
            steps: usize,
            repair_attempts: u8,
            proposal_path: []const u8,
            response_text: []const u8,
            reported_tokens: provider_mod.TokenUsage,
        };
        const json = try std.json.Stringify.valueAlloc(self.allocator, Json{
            .steps = payload.steps.len,
            .repair_attempts = payload.repair_attempts,
            .proposal_path = payload.proposal_rel orelse "",
            .response_text = payload.response_text orelse "",
            .reported_tokens = payload.usage,
        }, .{});
        defer self.allocator.free(json);
        try self.appendJson(json);
    }
};

fn toolReason(tool: []const u8) []const u8 {
    if (std.mem.eql(u8, tool, "read_file")) return "Gather line-level evidence from a specific file.";
    if (std.mem.eql(u8, tool, "codebase_search")) return "Semantic retrieval to find relevant symbols/files.";
    if (std.mem.eql(u8, tool, "search")) return "Keyword search to locate relevant lines quickly.";
    if (std.mem.eql(u8, tool, "list_tree")) return "Inspect workspace structure to find likely files.";
    if (std.mem.eql(u8, tool, "run_command")) return "Run a command to validate or gather runtime evidence.";
    if (std.mem.eql(u8, tool, "apply_proposal")) return "Apply a proposed change via transaction.";
    return "Execute a tool to gather missing evidence.";
}

fn argsPreview(args_json: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, args_json, &std.ascii.whitespace);
    return if (trimmed.len > 160) trimmed[0..160] else trimmed;
}

fn clipText(text: []const u8, max: usize) []const u8 {
    return if (text.len > max) text[0..max] else text;
}

const EventCtx = struct {
    logger: *EventLogger,
    step_begin_callback: ?*const fn (?*anyopaque, StepBegin) void,
    step_begin_context: ?*anyopaque,
    step_callback: ?*const fn (?*anyopaque, Step) void,
    step_context: ?*anyopaque,

    fn onStepBegin(ctx: ?*anyopaque, step: StepBegin) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        if (self.step_begin_callback) |callback| {
            callback(self.step_begin_context, step);
        }
        self.logger.toolCall(step.index, step.tool_name, step.args_json) catch {};
    }

    fn onStep(ctx: ?*anyopaque, step: Step) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        if (self.step_callback) |callback| {
            callback(self.step_context, step);
        }
        self.logger.toolResult(step.index, step.kind, step.summary, step.run_id) catch {};
    }
};

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
        provider_kind: []const u8,
    };
    const compact_summary = try buildCompactSummary(allocator, intent, steps, null, conversation_json);
    defer allocator.free(compact_summary);
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
        provider_kind: []const u8,
    };

    const run_ids = try allocator.alloc([]const u8, 1);
    defer allocator.free(run_ids);
    run_ids[0] = run_id;
    const compact_summary = try buildCompactSummary(allocator, intent, steps, null, conversation_json);
    defer allocator.free(compact_summary);

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
        .provider_kind = provider_kind,
    }, .{});
}

fn buildCompactSummary(
    allocator: std.mem.Allocator,
    intent: []const u8,
    steps: []const Step,
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

fn resolveHomeDir(environ_map: ?*const std.process.Environ.Map) ?[]const u8 {
    if (environ_map) |map| return map.get("HOME");
    return null;
}

fn initAgentTestHome(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]const u8 {
    const path = try std.fmt.allocPrint(allocator, "/tmp/forge-test-{s}", .{tmp.sub_path});
    try workspace.global_store.setForgeHomeOverride(path);
    return path;
}

test "agent run uses fake tool loop when enabled" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const forge_home = try initAgentTestHome(allocator, &tmp);
    defer allocator.free(forge_home);
    defer workspace.global_store.clearForgeHomeOverride();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("sample.txt"), "hello forge search\n");

    const fake_response =
        \\{"schema_version":1,"summary":"agent note","workspace_edit":{"files":[{"path":"agent.txt","operation":"create","edits":[{"start":0,"end":0,"replacement":"from agent\n"}]}]}}
    ;

    var result = try run(allocator, io, null, root, "search sample", .{
        .max_steps = 4,
        .provider_options = .{ .provider_name = "fake", .fake_response = fake_response, .fake_tool_loop = true },
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
    const forge_home = try initAgentTestHome(allocator, &tmp);
    defer allocator.free(forge_home);
    defer workspace.global_store.clearForgeHomeOverride();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("sample.txt"), "hello ask mode\n");

    var result = try run(allocator, io, null, root, "Explain sample.txt", .{
        .max_steps = 4,
        .capability_profile = .read_only,
        .provider_options = .{
            .provider_name = "fake",
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

    var session = try workspace.sessions.loadSession(allocator, io, result.session_id);
    defer workspace.sessions.deinitSession(allocator, &session);
    try std.testing.expectEqualStrings("completed", session.execution_state);
    try std.testing.expectEqualStrings("read_only", session.capability_profile);
}

test "agent run produces search and propose steps" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const forge_home = try initAgentTestHome(allocator, &tmp);
    defer allocator.free(forge_home);
    defer workspace.global_store.clearForgeHomeOverride();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("sample.txt"), "hello forge search\n");

    const fake_response =
        \\{"schema_version":1,"summary":"agent note","workspace_edit":{"files":[{"path":"agent.txt","operation":"create","edits":[{"start":0,"end":0,"replacement":"from agent\n"}]}]}}
    ;

    var result = try run(allocator, io, null, root, "search sample", .{
        .max_steps = 2,
        .provider_options = .{ .provider_name = "fake", .fake_response = fake_response },
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
    const forge_home = try initAgentTestHome(allocator, &tmp);
    defer allocator.free(forge_home);
    defer workspace.global_store.clearForgeHomeOverride();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("sample.txt"), "hello forge search\n");

    const fake_response =
        \\{"schema_version":1,"summary":"resumed","workspace_edit":{"files":[{"path":"resumed.txt","operation":"create","edits":[{"start":0,"end":0,"replacement":"ok\\n"}]}]}}
    ;
    try std.testing.expectError(error.StepLimitReached, run(allocator, io, null, root, "search sample", .{
        .max_steps = 1,
        .provider_options = .{ .provider_name = "fake", .fake_response = fake_response, .fake_tool_loop = true },
    }));

    var sessions = try workspace.sessions.listEntries(allocator, io, ".");
    defer sessions.deinit();
    try std.testing.expectEqual(@as(usize, 1), sessions.items.len);
    const session_id = sessions.items[0].session_id;

    var checkpoint = try workspace.sessions.loadSession(allocator, io, session_id);
    defer workspace.sessions.deinitSession(allocator, &checkpoint);
    try std.testing.expectEqualStrings("exploring", checkpoint.execution_state);
    try std.testing.expect(checkpoint.conversation_json.len > 0);
    try std.testing.expectEqual(@as(u32, 2), checkpoint.next_step_index);

    var result = try resumeSession(allocator, io, null, root, session_id, .{
        .max_steps = 4,
        .provider_options = .{ .provider_name = "fake", .fake_response = fake_response, .fake_tool_loop = true },
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
    const forge_home = try initAgentTestHome(allocator, &tmp);
    defer allocator.free(forge_home);
    defer workspace.global_store.clearForgeHomeOverride();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");
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
    try workspace.sessions.persistSession(io, ".", "sess_crash_pending", checkpoint_body);

    const fake_response =
        \\{"schema_version":1,"summary":"recovered","workspace_edit":{"files":[{"path":"recovered.txt","operation":"create","edits":[{"start":0,"end":0,"replacement":"ok\\n"}]}]}}
    ;
    var result = try resumeSession(allocator, io, null, root, "sess_crash_pending", .{
        .max_steps = 4,
        .provider_options = .{
            .provider_name = "fake",
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
