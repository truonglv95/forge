const std = @import("std");
const ai = @import("forge-ai");
const workspace = @import("forge-workspace");
const kernel = @import("forge-kernel");
const session_mod = @import("session.zig");
const review_store = @import("review_store.zig");
const agent_ui_queue = @import("../workbench/agent_ui_queue.zig");

pub const ChatRole = enum { user, agent };

pub const Host = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    ai_provider: []const u8,
    ai_model: ?[]const u8,
    ai_ollama_url: ?[]const u8,
    ai_openrouter_url: ?[]const u8,
    ai_embedding_provider: ?[]const u8,
    ai_embedding_model: ?[]const u8,
    ai_embedding_url: ?[]const u8,
    ai_mcp_enabled: bool,
    ai_enable_hyde: bool,
    workspace_root: workspace.WorkspaceRoot,
    workspace_path: []const u8,
    agent: *session_mod.Session,
    agent_cancel_slot: *?*kernel.cancellation.CancellationTokenSource,
    context: ?*anyopaque,
    append_chat: *const fn (?*anyopaque, ChatRole, []const u8) void,
    set_status: *const fn (?*anyopaque, []const u8) void,
    enqueue_ui: *const fn (?*anyopaque, agent_ui_queue.Op) void,
    refresh_explorer: *const fn (?*anyopaque) void,
    open_file: *const fn (?*anyopaque, []const u8) void,
    snapshot_conversation: *const fn (?*anyopaque, std.mem.Allocator) []const ai.conversation.Turn,
    free_conversation_snapshot: *const fn (?*anyopaque, std.mem.Allocator, []const ai.conversation.Turn) void,
    snapshot_recent_files: *const fn (?*anyopaque, std.mem.Allocator) []const []const u8,
    free_recent_files_snapshot: *const fn (?*anyopaque, std.mem.Allocator, []const []const u8) void,
    snapshot_context_supplement: *const fn (?*anyopaque, std.mem.Allocator) ai.context_supplement.Supplement,
    free_context_supplement: *const fn (?*anyopaque, std.mem.Allocator, ai.context_supplement.Supplement) void,
    snapshot_editor_selection: *const fn (?*anyopaque, std.mem.Allocator) ?[]const u8,
    snapshot_editor_context: *const fn (?*anyopaque, std.mem.Allocator) ?[]const u8,
    lsp_request: *const fn (?*anyopaque, allocator: std.mem.Allocator, method: []const u8, params_json: []const u8) ?[]const u8,

    pub fn embeddingOptions(self: *const Host) ai.codebase_search.EmbeddingOptions {
        return .{
            .provider = ai.codebase_search.EmbeddingProvider.parse(self.ai_embedding_provider),
            .model = self.ai_embedding_model,
            .url = self.ai_embedding_url orelse self.ai_ollama_url,
        };
    }
};

pub const default_ask_response = ai.proposal_workflow.default_ask_response;
pub const default_plan_response = ai.proposal_workflow.default_plan_response;
pub const default_plan_markdown = ai.proposal_workflow.default_plan_markdown;

pub const AgentError = error{
    AgentBusy,
    NoProposal,
    ProviderFailed,
    Cancelled,
    MissingProviderCredentials,
    StepLimitReached,
    InvalidProposal,
    NoAcceptedHunks,
    NoCheckpoint,
    WorkspaceFailed,
    DuplicateLoop,
    NoProgress,
} || ai.provider.ProviderError;

pub fn refreshContextPreview(host: *const Host, intent: ?[]const u8, active_file: ?[]const u8) AgentError!void {
    const scope = host.agent.effectiveScope(active_file);
    const attachments = collectAttachmentInputs(host) catch return error.ProviderFailed;
    defer freeAttachmentInputs(host.allocator, attachments);

    var builder = try buildContext(host, intent, scope, active_file, attachments, true);
    defer builder.deinit();

    var manifest_items: std.ArrayList(ai.context_loader.ManifestItem) = .empty;
    defer ai.context_loader.freeManifestItems(host.allocator, &manifest_items);
    ai.context_loader.collectManifest(host.allocator, &builder, &manifest_items) catch return error.ProviderFailed;

    var entries: std.ArrayList(session_mod.ContextEntry) = .empty;
    for (manifest_items.items) |item| {
        const status: session_mod.ContextEntryStatus = switch (item.status) {
            .included => .included,
            .truncated => .truncated,
            .rejected => .rejected,
        };
        entries.append(host.allocator, .{
            .kind = (host.allocator.dupe(u8, @tagName(item.kind)) catch return error.ProviderFailed),
            .name = (host.allocator.dupe(u8, item.name) catch return error.ProviderFailed),
            .status = status,
            .bytes = item.bytes,
            .reason = if (item.reason) |text| (host.allocator.dupe(u8, text) catch return error.ProviderFailed) else null,
        }) catch return error.ProviderFailed;
    }

    host.agent.replaceContextManifest(builder.used_bytes, builder.max_bytes, entries);
}

pub fn spawnGenerate(host: *const Host, intent: []const u8, scope_files: []const []const u8, active_file: ?[]const u8) AgentError!void {
    if (host.agent.worker_running) return error.AgentBusy;

    const conversation = host.snapshot_conversation(host.context, host.allocator);
    const ctx = host.allocator.create(GenerateContext) catch {
        host.free_conversation_snapshot(host.context, host.allocator, conversation);
        return error.ProviderFailed;
    };

    const intent_owned = host.allocator.dupe(u8, intent) catch {
        host.free_conversation_snapshot(host.context, host.allocator, conversation);
        host.allocator.destroy(ctx);
        return error.ProviderFailed;
    };
    const scope_owned = dupeStringSlice(host.allocator, scope_files) catch {
        host.allocator.free(intent_owned);
        host.free_conversation_snapshot(host.context, host.allocator, conversation);
        host.allocator.destroy(ctx);
        return error.ProviderFailed;
    };
    const active_owned: ?[]const u8 = if (active_file) |path| host.allocator.dupe(u8, path) catch null else null;

    ctx.* = .{
        .host = host.*,
        .intent = intent_owned,
        .scope_files = scope_owned,
        .active_file = active_owned,
        .conversation = conversation,
        .cancel_source = kernel.cancellation.CancellationTokenSource.init(host.allocator) catch {
            if (active_owned) |path| host.allocator.free(path);
            freeStringSlice(host.allocator, scope_owned);
            host.allocator.free(intent_owned);
            host.free_conversation_snapshot(host.context, host.allocator, conversation);
            host.allocator.destroy(ctx);
            return error.ProviderFailed;
        },
    };

    host.agent.resetForNewRun();
    if (resolveProviderLabel(host)) |provider_label| {
        defer host.allocator.free(provider_label);
        host.agent.setProviderLabel(provider_label) catch {};
        var start_buf: [160]u8 = undefined;
        const start_status = std.fmt.bufPrint(&start_buf, "Starting ({s}) — building context...", .{provider_label}) catch "Building context...";
        host.agent.setPhase(.building_context, start_status) catch {};
        host.set_status(host.context, start_status);
    } else |_| {
        host.agent.setProviderLabel("unknown") catch {};
        host.agent.setPhase(.building_context, "Building context...") catch {};
        host.set_status(host.context, "Building context...");
    }
    host.agent.lock();
    host.agent.worker_running = true;
    if (host.agent.intent) |old| host.allocator.free(old);
    host.agent.intent = host.allocator.dupe(u8, intent) catch "";
    if (host.agent.run_active_file) |old| host.allocator.free(old);
    host.agent.run_active_file = if (active_file) |path| host.allocator.dupe(u8, path) catch null else null;
    host.agent.unlock();

    const thread = std.Thread.spawn(.{}, generateWorker, .{ctx}) catch {
        ctx.deinit();
        return error.ProviderFailed;
    };
    thread.detach();
}

pub fn scanResumableSession(host: *const Host) void {
    if (host.agent.worker_running) return;
    const interrupted_opt = workspace.sessions.findLatestResumable(host.allocator, host.io, host.workspace_path) catch return;
    if (interrupted_opt) |value| {
        var owned = value;
        defer workspace.sessions.deinitResumable(host.allocator, &owned);
        host.agent.setResumeOffer(.continue_run, owned.session_id, owned.intent, owned.execution_state, null) catch {};
        return;
    }
    const proposal_opt = workspace.sessions.findLatestProposalReady(host.allocator, host.io, host.workspace_path) catch return;
    if (proposal_opt) |value| {
        var owned = value;
        defer workspace.sessions.deinitProposalReady(host.allocator, &owned);
        host.agent.setResumeOffer(.review_proposal, owned.session_id, owned.intent, "proposal_ready", owned.proposal_path) catch {};
    }
}

pub fn dismissResumeOffer(host: *const Host) void {
    host.agent.clearResumeOffer();
}

pub fn openStoredProposal(host: *const Host, session_id: []const u8) AgentError!void {
    var doc = workspace.sessions.loadSession(host.allocator, host.io, session_id) catch return error.ProviderFailed;
    defer workspace.sessions.deinitSession(host.allocator, &doc);
    if (!workspace.sessions.isProposalReadyExecutionState(doc.execution_state)) return error.InvalidProposal;
    if (doc.proposal_path.len == 0) return error.NoProposal;

    host.agent.clearResumeOffer();

    const run_id = if (doc.run_ids.len > 0) doc.run_ids[doc.run_ids.len - 1] else "";

    host.agent.lock();
    if (host.agent.run_id) |old| host.allocator.free(old);
    host.agent.run_id = host.allocator.dupe(u8, run_id) catch {
        host.agent.unlock();
        return error.ProviderFailed;
    };
    if (host.agent.proposal_rel) |old| host.allocator.free(old);
    host.agent.proposal_rel = host.allocator.dupe(u8, doc.proposal_path) catch {
        host.agent.unlock();
        return error.ProviderFailed;
    };
    if (host.agent.intent) |old| host.allocator.free(old);
    host.agent.intent = host.allocator.dupe(u8, doc.intent) catch {
        host.agent.unlock();
        return error.ProviderFailed;
    };
    host.agent.unlock();

    loadProposalPreview(host, doc.proposal_path) catch return error.ProviderFailed;
    host.agent.setPhase(.proposal_ready, "Proposal ready for review") catch return error.ProviderFailed;
    host.set_status(host.context, "Proposal ready for review");
}

pub fn spawnResumeSession(host: *const Host, session_id: []const u8) AgentError!void {
    if (host.agent.worker_running) return error.AgentBusy;

    var doc = workspace.sessions.loadSession(host.allocator, host.io, session_id) catch return error.ProviderFailed;
    defer workspace.sessions.deinitSession(host.allocator, &doc);
    if (!workspace.sessions.isResumableExecutionState(doc.execution_state)) return error.InvalidProposal;

    const capability: ai.tools.CapabilityProfile = blk: {
        if (std.mem.eql(u8, doc.capability_profile, "read_only")) break :blk .read_only;
        if (std.mem.eql(u8, doc.capability_profile, "propose_and_task")) break :blk .propose_and_task;
        break :blk .propose;
    };

    const ctx = host.allocator.create(ResumeContext) catch return error.ProviderFailed;
    const session_owned = host.allocator.dupe(u8, session_id) catch {
        host.allocator.destroy(ctx);
        return error.ProviderFailed;
    };
    const intent_owned = host.allocator.dupe(u8, doc.intent) catch {
        host.allocator.free(session_owned);
        host.allocator.destroy(ctx);
        return error.ProviderFailed;
    };

    ctx.* = .{
        .host = host.*,
        .session_id = session_owned,
        .intent = intent_owned,
        .capability_profile = capability,
        .cancel_source = kernel.cancellation.CancellationTokenSource.init(host.allocator) catch {
            host.allocator.free(intent_owned);
            host.allocator.free(session_owned);
            host.allocator.destroy(ctx);
            return error.ProviderFailed;
        },
    };

    host.agent.clearResumeOffer();
    host.agent.resetForNewRun();
    host.agent.setPhase(.building_context, "Resuming interrupted agent run...") catch {};
    host.set_status(host.context, "Resuming interrupted agent run...");
    host.agent.lock();
    host.agent.worker_running = true;
    if (host.agent.intent) |old| host.allocator.free(old);
    host.agent.intent = host.allocator.dupe(u8, doc.intent) catch "";
    host.agent.unlock();

    const thread = std.Thread.spawn(.{}, resumeWorker, .{ctx}) catch {
        ctx.deinit();
        return error.ProviderFailed;
    };
    thread.detach();
}

pub fn cancel(host: *const Host) void {
    if (host.agent_cancel_slot.*) |source| source.cancel();
    host.agent.resolveToolApproval(false);
}

pub fn applyCurrentProposal(host: *const Host) AgentError!u64 {
    host.agent.setPhase(.applying, "Applying proposal...") catch {};

    var proposal_owned = false;
    var proposal_ptr: *const workspace.OwnedProposal = undefined;
    var loaded_proposal: workspace.OwnedProposal = undefined;
    const proposal_rel = host.agent.proposal_rel orelse "";

    if (host.agent.ephemeral_proposal) |*ephemeral| {
        proposal_ptr = ephemeral;
    } else {
        if (host.agent.proposal_rel) |rel| {
            loaded_proposal = workspace.OwnedProposal.readPath(host.allocator, host.io, host.workspace_root, rel) catch return error.ProviderFailed;
            proposal_owned = true;
            proposal_ptr = &loaded_proposal;
        } else {
            return error.NoProposal;
        }
    }
    defer if (proposal_owned) loaded_proposal.deinit();

    var filtered = host.agent.review.buildAcceptedEdit(host.allocator, proposal_ptr) catch |err| switch (err) {
        error.NoAcceptedHunks => return error.NoAcceptedHunks,
        else => return error.ProviderFailed,
    };
    defer filtered.deinit(host.allocator);

    const workspace_edit = filtered.workspaceEdit();
    workspace_edit.validate() catch return error.ProviderFailed;

    const checkpoint_id = workspace.checkpoint.createFromEdits(host.allocator, host.io, host.workspace_root, filtered.files, .{
        .run_id = host.agent.run_id,
        .label = "pre-apply",
    }) catch return error.ProviderFailed;

    const tx_id = workspace.execution.applyApproved(
        host.allocator,
        host.io,
        host.workspace_root,
        workspace_edit,
        proposal_rel,
    ) catch return error.ProviderFailed;
    workspace.checkpoint.linkTransaction(host.io, host.workspace_root, checkpoint_id, tx_id) catch {};

    host.agent.setPhase(.verifying, "Verifying applied changes...") catch {};
    const validation = ai.validation_runner.runTasks(host.allocator, host.io, host.workspace_path, proposal_ptr.metadata.validation_tasks) catch return error.ProviderFailed;
    defer ai.validation_runner.freeResults(host.allocator, validation);
    var validation_failed = false;
    for (validation) |item| {
        if (!item.skipped and item.exit_code != 0) validation_failed = true;
    }

    if (host.agent.run_id) |run_id| {
        workspace.runs.updateRunState(
            host.allocator,
            host.io,
            host.workspace_root,
            run_id,
            if (validation_failed) "validation_failed" else "done",
            tx_id,
        ) catch {};
    }

    host.agent.lock();
    host.agent.clearValidationResultsUnlocked();
    for (validation) |item| {
        const task_copy = host.allocator.dupe(u8, item.task) catch continue;
        const output_copy = host.allocator.dupe(u8, item.output) catch {
            host.allocator.free(task_copy);
            continue;
        };
        host.agent.validation_results.append(host.allocator, .{
            .task = task_copy,
            .exit_code = item.exit_code,
            .output = output_copy,
            .skipped = item.skipped,
        }) catch {
            host.allocator.free(task_copy);
            host.allocator.free(output_copy);
        };
    }
    host.agent.last_transaction_id = tx_id;
    host.agent.last_checkpoint_id = checkpoint_id;
    host.agent.show_review = false;
    host.agent.phase = if (validation_failed) .failed else .done;
    if (host.agent.status_line.len > 0) host.allocator.free(host.agent.status_line);
    host.agent.status_line = host.allocator.dupe(
        u8,
        if (validation_failed) "Applied, but validation failed — inspect output or rollback" else "Applied and verified successfully",
    ) catch "";
    host.agent.post_apply_visible = true;
    host.agent.unlock();

    host.refresh_explorer(host.context);
    for (filtered.files) |file| {
        host.open_file(host.context, file.path);
    }

    refreshRunHistory(host) catch {};

    return tx_id;
}

pub fn rejectCurrentProposal(host: *const Host) void {
    if (host.agent.run_id) |run_id| {
        workspace.runs.updateRunState(host.allocator, host.io, host.workspace_root, run_id, "cancelled", null) catch {};
    }

    host.agent.lock();
    host.agent.show_review = false;
    host.agent.review.clear(host.allocator);
    host.agent.phase = .idle;
    if (host.agent.status_line.len > 0) host.allocator.free(host.agent.status_line);
    host.agent.status_line = host.allocator.dupe(u8, "Proposal rejected") catch "";
    host.agent.unlock();

    refreshRunHistory(host) catch {};
}

pub fn approveSpecAndGenerate(host: *const Host) AgentError!void {
    const run_id = host.agent.spec_run_id orelse return error.NoProposal;
    ai.spec_writer.approve(host.allocator, host.io, host.workspace_root, run_id) catch return error.ProviderFailed;
    const intent = host.agent.intent orelse return error.NoProposal;

    host.agent.lock();
    host.agent.spec_pending = false;
    if (host.agent.proposal_only_run_id) |old| host.allocator.free(old);
    host.agent.proposal_only_run_id = host.allocator.dupe(u8, run_id) catch {
        host.agent.unlock();
        return error.ProviderFailed;
    };
    host.agent.unlock();

    const scope = host.agent.effectiveScope(host.agent.run_active_file);
    try spawnGenerate(host, intent, scope, host.agent.run_active_file);
}

pub fn rollbackLastCheckpoint(host: *const Host) AgentError!void {
    const checkpoint_id = host.agent.last_checkpoint_id orelse return error.NoCheckpoint;
    workspace.checkpoint.restore(host.allocator, host.io, host.workspace_root, checkpoint_id) catch return error.ProviderFailed;

    host.agent.lock();
    host.agent.phase = .done;
    host.agent.post_apply_visible = false;
    if (host.agent.status_line.len > 0) host.allocator.free(host.agent.status_line);
    host.agent.status_line = host.allocator.dupe(u8, "Checkpoint restored") catch "";
    host.agent.last_checkpoint_id = null;
    host.agent.unlock();

    host.refresh_explorer(host.context);
}

pub fn applyManifestText(host: *const Host, manifest_text: []const u8) !void {
    host.agent.lock();
    defer host.agent.unlock();
    clearLines(host.allocator, &host.agent.context_lines);
    var line_it = std.mem.splitScalar(u8, manifest_text, '\n');
    while (line_it.next()) |line| {
        if (line.len == 0) continue;
        try host.agent.context_lines.append(host.allocator, try host.allocator.dupe(u8, line));
    }
}

pub fn loadProposalPreview(host: *const Host, proposal_rel: []const u8) !void {
    var proposal = try workspace.OwnedProposal.readPath(host.allocator, host.io, host.workspace_root, proposal_rel);
    defer proposal.deinit();

    const edit = proposal.workspaceEdit();
    try edit.validate();

    host.agent.lock();
    defer host.agent.unlock();

    host.agent.review.clear(host.allocator);
    try host.agent.review.buildFromProposal(host.allocator, host.io, host.workspace_root, &proposal);

    clearLines(host.allocator, &host.agent.diff_lines);
    for (host.agent.review.hunks) |hunk| {
        for (hunk.diff_lines) |line| {
            try host.agent.diff_lines.append(host.allocator, try host.allocator.dupe(u8, line));
        }
    }

    if (proposal.metadata.summary) |summary| {
        if (host.agent.summary) |old| host.allocator.free(old);
        host.agent.summary = try host.allocator.dupe(u8, summary);
        try host.agent.context_lines.append(host.allocator, try std.fmt.allocPrint(host.allocator, "Summary: {s}", .{summary}));
    }

    for (proposal.metadata.assumptions) |item| {
        try host.agent.context_lines.append(host.allocator, try std.fmt.allocPrint(host.allocator, "Assumption: {s}", .{item}));
    }
    for (proposal.metadata.validation_tasks) |item| {
        try host.agent.context_lines.append(host.allocator, try std.fmt.allocPrint(host.allocator, "Validate: {s}", .{item}));
    }

    // Validation belongs after the accepted edit is applied. Running it here
    // would only verify the pre-proposal workspace and could produce a false green.
    host.agent.clearValidationResultsUnlocked();

    try host.agent.context_lines.append(host.allocator, try std.fmt.allocPrint(host.allocator, "Proposal: {s}", .{proposal_rel}));

    host.agent.show_review = true;
    host.agent.phase = .reviewing;
    host.agent.review_scroll_y = 0;
    host.agent.post_apply_visible = false;

    if (host.agent.run_id) |run_id| {
        workspace.runs.updateRunState(host.allocator, host.io, host.workspace_root, run_id, "reviewing", null) catch {};
    }

    if (proposal.files.len > 0) {
        host.open_file(host.context, proposal.files[0].path);
    }
}

pub fn refreshRunHistory(host: *const Host) !void {
    var list = try workspace.runs.listEntries(host.allocator, host.io, host.workspace_root);
    defer list.deinit();

    host.agent.lock();
    defer host.agent.unlock();

    for (host.agent.run_history.items) |entry| {
        host.allocator.free(entry.run_id);
        host.allocator.free(entry.state);
    }
    host.agent.run_history.clearRetainingCapacity();

    for (list.items) |entry| {
        try host.agent.run_history.append(host.allocator, .{
            .run_id = try host.allocator.dupe(u8, entry.run_id),
            .state = try host.allocator.dupe(u8, entry.state),
            .timestamp_ms = entry.timestamp_ms,
        });
    }
    if (host.agent.selected_run_index >= host.agent.run_history.items.len) {
        host.agent.selected_run_index = if (host.agent.run_history.items.len > 0) host.agent.run_history.items.len - 1 else 0;
    }
}

const GenerateContext = struct {
    host: Host,
    intent: []const u8,
    scope_files: []const []const u8,
    active_file: ?[]const u8,
    conversation: []const ai.conversation.Turn,
    cancel_source: kernel.cancellation.CancellationTokenSource,

    fn deinit(self: *GenerateContext) void {
        self.host.allocator.free(self.intent);
        freeStringSlice(self.host.allocator, self.scope_files);
        if (self.active_file) |path| self.host.allocator.free(path);
        self.host.free_conversation_snapshot(self.host.context, self.host.allocator, self.conversation);
        self.cancel_source.deinit();
        self.host.allocator.destroy(self);
    }
};

const ResumeContext = struct {
    host: Host,
    session_id: []const u8,
    intent: []const u8,
    capability_profile: ai.tools.CapabilityProfile,
    cancel_source: kernel.cancellation.CancellationTokenSource,

    fn deinit(self: *ResumeContext) void {
        self.host.allocator.free(self.session_id);
        self.host.allocator.free(self.intent);
        self.cancel_source.deinit();
        self.host.allocator.destroy(self);
    }
};

fn providerOptions(host: *const Host, fake_response: []const u8, fake_plan: ?[]const u8, for_agent: bool) ai.provider_factory.Options {
    const name = if (host.ai_provider.len > 0) host.ai_provider else "auto";
    const base_url = if (std.mem.eql(u8, name, "openrouter")) host.ai_openrouter_url else host.ai_ollama_url;
    return .{
        .provider_name = name,
        .model = host.ai_model,
        .base_url = base_url,
        .fake_response = fake_response,
        .fake_plan_response = fake_plan,
        .fake_tool_loop = for_agent,
        .stream_callback = streamBridge,
        .stream_context = @ptrCast(@constCast(host)),
        .thinking_callback = thinkingBridge,
        .thinking_context = @ptrCast(@constCast(host)),
    };
}

fn generateWorker(ctx: *GenerateContext) void {
    defer ctx.deinit();

    ctx.host.agent_cancel_slot.* = &ctx.cancel_source;
    defer ctx.host.agent_cancel_slot.* = null;

    const mode = ctx.host.agent.mode;
    const fake_response = switch (mode) {
        .ask => default_ask_response,
        .plan => default_plan_response,
        .agent => default_ask_response,
    };
    const fake_plan = if (mode == .plan) default_plan_markdown else null;

    const run_fn = switch (mode) {
        .ask => agentRunInner(ctx, providerOptions(&ctx.host, fake_response, null, true), .read_only),
        .agent => agentRunInner(ctx, providerOptions(&ctx.host, fake_response, null, true), .propose_and_task),
        .plan => generateInner(ctx, providerOptions(&ctx.host, fake_response, fake_plan, false)),
    };

    run_fn catch |err| {
        const msg = agentFailureMessage(err);
        const owned = ctx.host.allocator.dupe(u8, msg) catch return;
        ctx.host.enqueue_ui(ctx.host.context, .{
            .run_failed = .{
                .phase = if (err == error.Cancelled) .cancelled else .failed,
                .message = owned,
            },
        });
    };
}

fn resumeWorker(ctx: *ResumeContext) void {
    defer ctx.deinit();

    ctx.host.agent_cancel_slot.* = &ctx.cancel_source;
    defer ctx.host.agent_cancel_slot.* = null;

    const host = &ctx.host;
    const cancel_token = ctx.cancel_source.getToken();
    const provider_options = providerOptions(host, default_ask_response, null, ctx.capability_profile == .propose_and_task);

    const attachments = collectAttachmentInputs(host) catch {
        enqueueRunFailed(host, error.ProviderFailed);
        return;
    };
    defer freeAttachmentInputs(host.allocator, attachments);
    const recent_files = collectRecentFiles(host) catch &.{};
    defer if (recent_files.len > 0) host.free_recent_files_snapshot(host.context, host.allocator, recent_files);

    var result = ai.agent.resumeSession(
        host.allocator,
        host.io,
        host.environ_map,
        host.workspace_root,
        ctx.session_id,
        .{
            .max_steps = 128,
            .provider_options = provider_options,
            .mode = if (ctx.capability_profile == .read_only) .ask else .agent,
            .capability_profile = ctx.capability_profile,
            .surface = .ide,
            .cancel_token = &cancel_token,
            .progress_callback = phaseBridge,
            .progress_context = host,
            .step_callback = stepBridge,
            .step_context = host,
            .step_begin_callback = stepBeginBridge,
            .step_begin_context = host,
            .turn_callback = turnBridge,
            .turn_context = host,
            .approval_callback = approvalBridge,
            .approval_context = host,
            .edit_callback = editBridge,
            .edit_context = host,
            .lsp_request_callback = lspBridge,
            .lsp_context = host,
            .editor_context_callback = editorContextBridge,
            .editor_context = host,
            .use_inline_edits = ctx.capability_profile != .read_only,
            .workspace_cwd = host.workspace_path,
            .mcp_enabled = host.ai_mcp_enabled,
            .recent_files = recent_files,
            .embedding = host.embeddingOptions(),
            .max_repair_attempts = if (ctx.capability_profile == .read_only or std.mem.eql(u8, provider_options.provider_name, "fake")) 0 else 2,
        },
    ) catch |err| {
        enqueueRunFailed(host, err);
        return;
    };
    defer ai.agent.deinitResult(host.allocator, &result);

    const run_id = result.final_run_id orelse "inline_run";
    const proposal_rel = result.proposal_rel orelse "";

    const manifest_owned = buildManifestText(host, ctx.intent, &.{}, null, attachments) catch {
        enqueueRunFailed(host, error.ProviderFailed);
        return;
    };
    errdefer host.allocator.free(manifest_owned);

    var chat_buf: [512]u8 = undefined;
    const chat_line = result.response_text orelse (std.fmt.bufPrint(&chat_buf, "Agent resumed", .{}) catch "Agent resumed");
    const chat_owned = host.allocator.dupe(u8, chat_line) catch {
        enqueueRunFailed(host, error.ProviderFailed);
        return;
    };
    errdefer host.allocator.free(chat_owned);

    enqueueRunFinished(host, run_id, proposal_rel, chat_owned, manifest_owned, null) catch {
        enqueueRunFailed(host, error.ProviderFailed);
    };
}

fn enqueueRunFailed(host: *const Host, err: anyerror) void {
    const msg = agentFailureMessage(err);
    const owned = host.allocator.dupe(u8, msg) catch return;
    host.enqueue_ui(host.context, .{
        .run_failed = .{
            .phase = if (err == error.Cancelled) .cancelled else .failed,
            .message = owned,
        },
    });
}

pub fn agentFailureMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.Cancelled => "Cancelled",
        error.ProviderFailed => "Provider initialization failed. Please check your API key (e.g. export OPENROUTER_API_KEY or GEMINI_API_KEY) and model configuration.",
        error.AuthenticationFailed => ai.provider.Provider.errorMessage(error.AuthenticationFailed),
        error.RateLimitExceeded => ai.provider.Provider.errorMessage(error.RateLimitExceeded),
        error.ContextLengthExceeded => "Agent compacted context but the provider still rejected it. Resume the saved session, reduce attachments, or switch to a larger-context model.",
        error.NetworkError => ai.provider.Provider.errorMessage(error.NetworkError),
        error.MalformedResponse => ai.provider.Provider.errorMessage(error.MalformedResponse),
        error.ProviderInternalError => ai.provider.Provider.errorMessage(error.ProviderInternalError),
        error.InvalidProposal => "Invalid proposal — model response could not be parsed or validated",
        error.StepLimitReached => "Agent reached step limit; compact checkpoint saved. Resume the session to continue from the compact state.",
        error.WorkspaceFailed => "Agent tool failed to access the workspace",
        error.DuplicateLoop => "Agent stopped because the model repeated the same tool call",
        error.NoProgress => "Agent stopped because it kept gathering broad context without making progress",
        else => {
            std.debug.print("UNHANDLED AGENT ERROR: {any}\n", .{err});
            return "Agent failed";
        },
    };
}

fn resolvePlanPhase(host: *const Host) ai.proposal_workflow.PlanPhase {
    if (host.agent.mode != .plan) return .full;
    if (host.agent.proposal_only_run_id != null) return .proposal_only;
    return .plan_only;
}

fn continueRunId(host: *const Host, plan_phase: ai.proposal_workflow.PlanPhase) ?[]const u8 {
    if (plan_phase != .proposal_only) return null;
    return host.agent.proposal_only_run_id orelse host.agent.spec_run_id;
}

fn generateInner(ctx: *GenerateContext, provider_options: ai.provider_factory.Options) AgentError!void {
    const host = &ctx.host;
    const cancel_token = ctx.cancel_source.getToken();

    const attachments = collectAttachmentInputs(host) catch return error.ProviderFailed;
    defer freeAttachmentInputs(host.allocator, attachments);
    const recent_files = collectRecentFiles(host) catch &.{};
    defer if (recent_files.len > 0) host.free_recent_files_snapshot(host.context, host.allocator, recent_files);

    const plan_phase = resolvePlanPhase(host);
    const continue_id = continueRunId(host, plan_phase);

    var result = ai.proposal_workflow.generateAndPersist(
        host.allocator,
        host.io,
        host.environ_map,
        host.workspace_root,
        ctx.intent,
        ctx.scope_files,
        provider_options,
        .{
            .surface = .ide,
            .mode = switch (host.agent.mode) {
                .ask, .agent => .ask,
                .plan => .plan,
            },
            .plan_phase = if (host.agent.mode == .plan) plan_phase else .full,
            .continue_run_id = continue_id,
            .cancel_token = &cancel_token,
            .progress_callback = phaseBridge,
            .progress_context = host,
            .stream_callback = streamBridge,
            .stream_context = host,
            .thinking_callback = thinkingBridge,
            .thinking_context = host,
            .active_file = ctx.active_file,
            .attachments = attachments,
            .conversation = ctx.conversation,
            .workspace_cwd = host.workspace_path,
            .recent_files = recent_files,
            .embedding = host.embeddingOptions(),
            .enable_repair_loop = plan_phase != .plan_only and !std.mem.eql(u8, provider_options.provider_name, "fake"),
            .max_repair_attempts = if (std.mem.eql(u8, provider_options.provider_name, "fake")) 0 else 2,
        },
    ) catch |err| switch (err) {
        ai.proposal_workflow.WorkflowError.Cancelled => return error.Cancelled,
        ai.proposal_workflow.WorkflowError.MissingProviderCredentials => return error.MissingProviderCredentials,
        ai.proposal_workflow.WorkflowError.InvalidProposal => return error.InvalidProposal,
        else => |e| return e,
    };
    defer ai.proposal_workflow.deinitResult(host.allocator, &result);

    host.agent.lock();
    if (host.agent.proposal_only_run_id) |rid| {
        host.allocator.free(rid);
        host.agent.proposal_only_run_id = null;
    }
    host.agent.unlock();

    const manifest_owned = try buildManifestText(host, ctx.intent, ctx.scope_files, ctx.active_file, attachments);
    errdefer host.allocator.free(manifest_owned);

    const plan_owned = if (result.plan_body) |plan| host.allocator.dupe(u8, plan) catch return error.ProviderFailed else null;
    errdefer if (plan_owned) |text| host.allocator.free(text);

    var chat_buf: [512]u8 = undefined;
    const chat_line = if (plan_phase == .plan_only)
        std.fmt.bufPrint(&chat_buf, "Spec ready at .forge/specs/{s}/ — Approve spec to generate proposal", .{result.run_id}) catch "Plan ready"
    else if (plan_owned != null)
        std.fmt.bufPrint(&chat_buf, "Plan ready — proposal: {s}", .{result.proposal_rel}) catch "Proposal ready"
    else
        std.fmt.bufPrint(&chat_buf, "Proposal ready: {s}", .{result.proposal_rel}) catch "Proposal ready";
    const chat_owned = host.allocator.dupe(u8, chat_line) catch return error.ProviderFailed;
    errdefer host.allocator.free(chat_owned);

    if (plan_phase == .plan_only) {
        host.agent.lock();
        if (host.agent.spec_run_id) |old| host.allocator.free(old);
        host.agent.spec_run_id = host.allocator.dupe(u8, result.run_id) catch {
            host.agent.unlock();
            return error.ProviderFailed;
        };
        host.agent.spec_pending = true;
        host.agent.unlock();
    }

    try enqueueRunFinished(host, result.run_id, result.proposal_rel, chat_owned, manifest_owned, plan_owned);
}

fn agentRunInner(ctx: *GenerateContext, provider_options: ai.provider_factory.Options, capability_profile: ai.tools.CapabilityProfile) AgentError!void {
    const host = &ctx.host;
    const cancel_token = ctx.cancel_source.getToken();

    const attachments = collectAttachmentInputs(host) catch return error.ProviderFailed;
    defer freeAttachmentInputs(host.allocator, attachments);
    const recent_files = collectRecentFiles(host) catch &.{};
    defer if (recent_files.len > 0) host.free_recent_files_snapshot(host.context, host.allocator, recent_files);

    const selection_text = host.snapshot_editor_selection(host.context, host.allocator);
    defer if (selection_text) |text| host.allocator.free(text);
    const has_selection = selection_text != null and selection_text.?.len > 0;

    var effective_attachments = attachments;
    var selection_attachment: ?ai.context_loader.AttachmentInput = null;
    if (has_selection) {
        selection_attachment = .{
            .kind = .text_snippet,
            .label = host.allocator.dupe(u8, "editor_selection") catch return error.ProviderFailed,
            .text = host.allocator.dupe(u8, selection_text.?) catch return error.ProviderFailed,
            .stored_path = null,
        };
        const merged = host.allocator.alloc(ai.context_loader.AttachmentInput, attachments.len + 1) catch return error.ProviderFailed;
        errdefer host.allocator.free(merged);
        @memcpy(merged[0..attachments.len], attachments);
        merged[attachments.len] = selection_attachment.?;
        effective_attachments = merged;
    }
    defer {
        if (has_selection) {
            host.allocator.free(effective_attachments);
            if (selection_attachment) |attachment| {
                host.allocator.free(attachment.label);
                if (attachment.text) |text| host.allocator.free(text);
            }
        }
    }

    var result = ai.agent.run(
        host.allocator,
        host.io,
        host.environ_map,
        host.workspace_root,
        ctx.intent,
        .{
            .max_steps = 128,
            .provider_options = provider_options,
            .mode = @enumFromInt(@intFromEnum(host.agent.mode)),
            .capability_profile = capability_profile,
            .explicit_files = ctx.scope_files,
            .active_file = ctx.active_file,
            .has_selection = has_selection,
            .attachments = effective_attachments,
            .conversation = ctx.conversation,
            .surface = .ide,
            .cancel_token = &cancel_token,
            .progress_callback = phaseBridge,
            .progress_context = host,
            .step_callback = stepBridge,
            .step_context = host,
            .step_begin_callback = stepBeginBridge,
            .step_begin_context = host,
            .turn_callback = turnBridge,
            .turn_context = host,
            .approval_callback = approvalBridge,
            .approval_context = host,
            .edit_callback = editBridge,
            .edit_context = host,
            .lsp_request_callback = lspBridge,
            .lsp_context = host,
            .editor_context_callback = editorContextBridge,
            .editor_context = host,
            .use_inline_edits = capability_profile != .read_only,
            .workspace_cwd = host.workspace_path,
            .mcp_enabled = host.ai_mcp_enabled,
            .recent_files = recent_files,
            .embedding = host.embeddingOptions(),
            .enable_hyde = host.ai_enable_hyde,
            .max_repair_attempts = if (capability_profile == .read_only or std.mem.eql(u8, provider_options.provider_name, "fake")) 0 else 2,
        },
    ) catch |err| switch (err) {
        error.Cancelled => return error.Cancelled,
        error.ProviderFailed => return error.ProviderFailed,
        error.AuthenticationFailed => return error.AuthenticationFailed,
        error.RateLimitExceeded => return error.RateLimitExceeded,
        error.ContextLengthExceeded => return error.ContextLengthExceeded,
        error.NetworkError => return error.NetworkError,
        error.WorkspaceFailed => return error.WorkspaceFailed,
        error.DuplicateLoop => return error.DuplicateLoop,
        error.NoProgress => return error.NoProgress,
        error.InvalidProposal => return error.InvalidProposal,
        error.StepLimitReached => return error.StepLimitReached,
    };
    defer ai.agent.deinitResult(host.allocator, &result);

    const run_id = result.final_run_id orelse "inline_run";
    const proposal_rel = result.proposal_rel orelse "";

    const manifest_owned = try buildManifestText(host, ctx.intent, ctx.scope_files, ctx.active_file, attachments);
    errdefer host.allocator.free(manifest_owned);

    var chat_buf: [512]u8 = undefined;
    const chat_line = result.response_text orelse (std.fmt.bufPrint(&chat_buf, "Agent finished", .{}) catch "Agent finished");
    const chat_owned = host.allocator.dupe(u8, chat_line) catch return error.ProviderFailed;
    errdefer host.allocator.free(chat_owned);

    try enqueueRunFinished(host, run_id, proposal_rel, chat_owned, manifest_owned, null);
}

fn buildManifestText(
    host: *const Host,
    intent: []const u8,
    scope_files: []const []const u8,
    active_file: ?[]const u8,
    attachments: []const ai.context_loader.AttachmentInput,
) AgentError![]u8 {
    var builder = try buildContext(host, intent, scope_files, active_file, attachments, false);
    defer builder.deinit();

    var manifest_writer = std.Io.Writer.Allocating.init(host.allocator);
    defer manifest_writer.deinit();
    ai.context_loader.renderManifestHuman(&builder, &manifest_writer.writer) catch return error.ProviderFailed;
    return host.allocator.dupe(u8, manifest_writer.writer.buffer[0..manifest_writer.writer.end]) catch error.ProviderFailed;
}

fn enqueueRunFinished(
    host: *const Host,
    run_id: []const u8,
    proposal_rel: []const u8,
    chat_owned: []const u8,
    manifest_owned: []const u8,
    plan_owned: ?[]const u8,
) AgentError!void {
    // `chat_owned`, `manifest_owned`, and `plan_owned` transfer ownership to the UI queue.
    const run_id_owned = host.allocator.dupe(u8, run_id) catch return error.ProviderFailed;
    errdefer host.allocator.free(run_id_owned);
    const proposal_rel_owned = host.allocator.dupe(u8, proposal_rel) catch return error.ProviderFailed;
    errdefer host.allocator.free(proposal_rel_owned);

    host.enqueue_ui(host.context, .{
        .run_finished = .{
            .run_id = run_id_owned,
            .proposal_rel = proposal_rel_owned,
            .chat_text = chat_owned,
            .manifest_text = manifest_owned,
            .plan_text = plan_owned,
        },
    });
}

fn phaseBridge(context: ?*anyopaque, phase: ai.progress.Phase) void {
    const host: *Host = @ptrCast(@alignCast(context.?));
    // Context manifest is built on the worker thread; refreshing it here would
    // block the UI thread during flushAgentUi and stall tool approval/steps.
    const mapped: session_mod.Phase = switch (phase) {
        .context_built => .building_context,
        .planning => .building_context,
        .plan_ready => .streaming,
        .sending => .sending,
        .streaming => .streaming,
        .parsing => .parsing,
        .repairing => .parsing,
        .proposal_ready => .proposal_ready,
    };
    const label = switch (phase) {
        .context_built => "Building context...",
        .planning => "Planning implementation...",
        .plan_ready => "Plan ready — generating proposal...",
        .sending => "Sending to provider...",
        .streaming => "Streaming response...",
        .parsing => "Parsing proposal...",
        .repairing => "Repairing proposal (validation failed)...",
        .proposal_ready => "Proposal ready for review",
    };
    const owned = host.allocator.dupe(u8, label) catch return;
    host.enqueue_ui(host.context, .{ .set_phase = .{ .phase = mapped, .label = owned } });
    host.enqueue_ui(host.context, .{ .set_status = host.allocator.dupe(u8, label) catch return });
}

fn resolveProviderLabel(host: *const Host) ![]const u8 {
    const name = if (host.ai_provider.len > 0) host.ai_provider else "auto";
    if (std.mem.eql(u8, name, "ollama")) {
        if (host.ai_model) |model| {
            return try std.fmt.allocPrint(host.allocator, "ollama/{s}", .{model});
        }
        return try host.allocator.dupe(u8, "ollama");
    }
    if (std.mem.eql(u8, name, "gemini")) {
        if (host.ai_model) |model| {
            return try std.fmt.allocPrint(host.allocator, "gemini/{s}", .{model});
        }
        return try host.allocator.dupe(u8, "gemini");
    }
    if (std.mem.eql(u8, name, "openrouter")) {
        if (host.ai_model) |model| {
            return try std.fmt.allocPrint(host.allocator, "openrouter/{s}", .{model});
        }
        return try host.allocator.dupe(u8, "openrouter");
    }
    if (std.mem.eql(u8, name, "fake")) return try host.allocator.dupe(u8, "fake");
    return try host.allocator.dupe(u8, "auto");
}

fn ensureStreamingPhase(host: *Host) void {
    host.agent.lock();
    const already = host.agent.stream_live;
    if (!already) host.agent.stream_live = true;
    host.agent.unlock();
    if (already) return;
    const owned = host.allocator.dupe(u8, "Streaming response...") catch return;
    host.enqueue_ui(host.context, .{
        .set_phase = .{ .phase = .streaming, .label = owned },
    });
}

fn enqueueStreamChunk(host: *Host, chunk: []const u8, kind: enum { thought, text }) void {
    if (chunk.len == 0) return;
    ensureStreamingPhase(host);
    const owned = host.allocator.dupe(u8, chunk) catch return;
    const op: agent_ui_queue.Op = switch (kind) {
        .thought => .{ .append_thinking = owned },
        .text => .{ .append_stream = owned },
    };
    host.enqueue_ui(host.context, op);
}

fn stepBridge(context: ?*anyopaque, step: ai.agent.Step) void {
    const host: *Host = @ptrCast(@alignCast(context.?));
    const kind_owned = host.allocator.dupe(u8, step.kind) catch return;
    const summary_owned = host.allocator.dupe(u8, step.summary) catch {
        host.allocator.free(kind_owned);
        return;
    };
    host.enqueue_ui(host.context, .{
        .append_step = .{
            .index = step.index,
            .kind = kind_owned,
            .summary = summary_owned,
        },
    });
}

fn stepBeginBridge(context: ?*anyopaque, begin: ai.agent.StepBegin) void {
    const host: *Host = @ptrCast(@alignCast(context.?));
    const kind = ai.subagent.classifyTool(begin.tool_name).label();
    const kind_owned = host.allocator.dupe(u8, kind) catch return;
    var label_owned = host.allocator.dupe(u8, ai.subagent.toolActionLabel(begin.tool_name)) catch {
        host.allocator.free(kind_owned);
        return;
    };

    var content_owned: ?[]const u8 = null;
    if (begin.args_json.len > 0) {
        var parsed = std.json.parseFromSlice(std.json.Value, host.allocator, begin.args_json, .{}) catch null;
        if (parsed != null) {
            defer parsed.?.deinit();
            const root = parsed.?.value;
            if (root == .object) {
                if (std.mem.eql(u8, begin.tool_name, "replace_file_content") or std.mem.eql(u8, begin.tool_name, "multi_replace_file_content") or std.mem.eql(u8, begin.tool_name, "write_to_file") or std.mem.eql(u8, begin.tool_name, "write_file")) {
                    const target = root.object.get("path") orelse root.object.get("TargetFile");
                    if (target) |target_value| if (target_value == .string) {
                        const next_label = std.fmt.allocPrint(host.allocator, "Write `{s}`", .{target_value.string}) catch {
                            host.allocator.free(kind_owned);
                            host.allocator.free(label_owned);
                            return;
                        };
                        host.allocator.free(label_owned);
                        label_owned = next_label;
                        content_owned = allocWritePreview(host.allocator, root, target_value.string) catch null;
                    };
                } else if (std.mem.eql(u8, begin.tool_name, "run_command")) {
                    const command = root.object.get("command") orelse root.object.get("CommandLine");
                    if (command) |command_value| if (command_value == .string) {
                        const next_label = std.fmt.allocPrint(host.allocator, "Run `{s}`", .{command_value.string}) catch {
                            host.allocator.free(kind_owned);
                            host.allocator.free(label_owned);
                            return;
                        };
                        host.allocator.free(label_owned);
                        label_owned = next_label;
                        content_owned = std.fmt.allocPrint(host.allocator, "```bash\n{s}\n```", .{command_value.string}) catch null;
                    };
                } else if (std.mem.eql(u8, begin.tool_name, "read_file")) {
                    if (root.object.get("path")) |path_val| {
                        if (path_val == .string) {
                            host.allocator.free(label_owned);
                            const start_line = jsonInt(root.object.get("start_line"));
                            const end_line = jsonInt(root.object.get("end_line"));
                            label_owned = if (start_line != null or end_line != null)
                                std.fmt.allocPrint(
                                    host.allocator,
                                    "Read `{s}` lines {d}-{d}",
                                    .{
                                        path_val.string,
                                        start_line orelse 1,
                                        end_line orelse ((start_line orelse 1) + 399),
                                    },
                                ) catch return
                            else
                                std.fmt.allocPrint(host.allocator, "Read `{s}` lines 1-400", .{path_val.string}) catch return;
                        }
                    }
                } else if (std.mem.eql(u8, begin.tool_name, "list_tree")) {
                    if (root.object.get("path")) |path_val| {
                        if (path_val == .string) {
                            host.allocator.free(label_owned);
                            label_owned = std.fmt.allocPrint(host.allocator, "List `{s}`", .{path_val.string}) catch return;
                        }
                    }
                } else {
                    content_owned = std.fmt.allocPrint(host.allocator, "```json\n{s}\n```", .{begin.args_json}) catch null;
                }
            }
        }
    }

    host.enqueue_ui(host.context, .{
        .begin_step = .{
            .index = begin.index,
            .kind = kind_owned,
            .label = label_owned,
            .content = content_owned,
        },
    });
}

fn jsonInt(value: ?std.json.Value) ?i64 {
    const v = value orelse return null;
    return switch (v) {
        .integer => |n| n,
        .float => |n| @intFromFloat(n),
        else => null,
    };
}

fn jsonStringValue(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    return if (v == .string) v.string else null;
}

fn utf8PrefixLen(text: []const u8, max_len: usize) usize {
    var len = @min(text.len, max_len);
    while (len < text.len and len > 0 and (text[len] & 0xc0) == 0x80) : (len -= 1) {}
    return len;
}

fn allocWritePreview(allocator: std.mem.Allocator, root: std.json.Value, path: []const u8) ![]u8 {
    const ext_idx = std.mem.lastIndexOfScalar(u8, path, '.');
    const ext = if (ext_idx) |i| path[i + 1 ..] else "";
    if (root != .object) return try std.fmt.allocPrint(allocator, "```{s}\n{s}\n```", .{ ext, path });

    var content: []const u8 = "";
    if (jsonStringValue(root.object.get("replacement"))) |text| {
        content = text;
    } else if (jsonStringValue(root.object.get("ReplacementContent"))) |text| {
        content = text;
    } else if (jsonStringValue(root.object.get("CodeContent"))) |text| {
        content = text;
    } else if (root.object.get("ReplacementChunks")) |chunks| {
        if (chunks == .array and chunks.array.items.len > 0) {
            const first = chunks.array.items[0];
            if (first == .object) {
                if (jsonStringValue(first.object.get("ReplacementContent"))) |text| {
                    content = text;
                }
            }
        }
    } else if (jsonStringValue(root.object.get("Replacement"))) |text| {
        content = text;
    }

    if (std.mem.startsWith(u8, content, "```")) {
        const first_nl = std.mem.indexOfScalar(u8, content, '\n');
        if (first_nl) |nl| {
            content = content[nl + 1 ..];
        }
    }
    content = std.mem.trimEnd(u8, content, " \n\r\t");
    if (std.mem.endsWith(u8, content, "```")) {
        content = content[0 .. content.len - 3];
    }
    content = std.mem.trimEnd(u8, content, " \n\r\t");

    const preview_len = utf8PrefixLen(content, 2400);
    const suffix = if (preview_len < content.len) "\n... truncated ..." else "";
    return try std.fmt.allocPrint(
        allocator,
        "```{s}\n{s}{s}\n```",
        .{ ext, content[0..preview_len], suffix },
    );
}

fn turnBridge(context: ?*anyopaque, index: u32) void {
    const host: *Host = @ptrCast(@alignCast(context.?));
    var buf: [96]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "Step {d}: calling model...", .{index}) catch return;
    const owned = host.allocator.dupe(u8, label) catch return;
    host.enqueue_ui(host.context, .{ .set_status = owned });
}

fn approvalBridge(context: ?*anyopaque, tool_name: []const u8, args_json: []const u8, policy: ai.tool_registry.Policy) bool {
    const host: *Host = @ptrCast(@alignCast(context.?));
    if (policy.approval == .automatic) return true;
    host.agent.lock();
    const agent_mode = host.agent.mode == .agent;
    host.agent.unlock();
    // In agent mode, review-gated edit tools only record proposals — auto-approve
    // so the explore loop can continue without freezing the UI thread.
    if (agent_mode and policy.approval == .review) return true;
    // In agent mode, auto-run observation tools (search, read_file, remember, …).
    // Only high-risk execution tools (run_command) still require explicit approval.
    if (agent_mode and policy.approval == .every_time and policy.risk != .high) return true;
    return host.agent.requestToolApproval(tool_name, args_json, @tagName(policy.risk), policy.approval);
}

fn editBridge(context: ?*anyopaque, edit: workspace.edit.WorkspaceEdit) void {
    const host: *Host = @ptrCast(@alignCast(context.?));
    const cloned_edit = edit.clone(host.allocator) catch return;
    host.enqueue_ui(host.context, .{
        .propose_edit = cloned_edit,
    });
}

fn lspBridge(context: ?*anyopaque, allocator: std.mem.Allocator, method: []const u8, params_json: []const u8) ?[]const u8 {
    const host: *Host = @ptrCast(@alignCast(context.?));
    return host.lsp_request(host.context, allocator, method, params_json);
}

fn editorContextBridge(context: ?*anyopaque, allocator: std.mem.Allocator) ?[]const u8 {
    const host: *Host = @ptrCast(@alignCast(context.?));
    return host.snapshot_editor_context(host.context, allocator);
}

fn streamBridge(context: ?*anyopaque, chunk: []const u8) void {
    const host: *Host = @ptrCast(@alignCast(context.?));
    enqueueStreamChunk(host, chunk, .text);
}

fn thinkingBridge(context: ?*anyopaque, chunk: []const u8) void {
    const host: *Host = @ptrCast(@alignCast(context.?));
    enqueueStreamChunk(host, chunk, .thought);
}

fn clearLines(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |line| allocator.free(line);
    list.clearRetainingCapacity();
}

fn dupeStringSlice(allocator: std.mem.Allocator, items: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, items.len);
    errdefer allocator.free(out);
    for (items, 0..) |item, index| {
        out[index] = try allocator.dupe(u8, item);
    }
    return out;
}

fn freeStringSlice(allocator: std.mem.Allocator, items: []const []const u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

fn collectRecentFiles(host: *const Host) ![]const []const u8 {
    return host.snapshot_recent_files(host.context, host.allocator);
}

fn buildContext(
    host: *const Host,
    intent: ?[]const u8,
    explicit_files: []const []const u8,
    active_file: ?[]const u8,
    attachments: []const ai.context_loader.AttachmentInput,
    preview_only: bool,
) AgentError!ai.context.ContextBuilder {
    const recent = host.snapshot_recent_files(host.context, host.allocator);
    defer host.free_recent_files_snapshot(host.context, host.allocator, recent);

    const supplement = host.snapshot_context_supplement(host.context, host.allocator);
    defer host.free_context_supplement(host.context, host.allocator, supplement);

    host.agent.lock();
    const mode: ai.tools.Mode = @enumFromInt(@intFromEnum(host.agent.mode));
    host.agent.unlock();

    const selection_text = host.snapshot_editor_selection(host.context, host.allocator);
    defer if (selection_text) |text| host.allocator.free(text);
    const has_selection = selection_text != null and selection_text.?.len > 0;

    var effective_attachments = attachments;
    var selection_attachment: ?ai.context_loader.AttachmentInput = null;
    if (has_selection) {
        selection_attachment = .{
            .kind = .text_snippet,
            .label = host.allocator.dupe(u8, "editor_selection") catch return error.ProviderFailed,
            .text = host.allocator.dupe(u8, selection_text.?) catch return error.ProviderFailed,
            .stored_path = null,
        };
        const merged = host.allocator.alloc(ai.context_loader.AttachmentInput, attachments.len + 1) catch return error.ProviderFailed;
        errdefer host.allocator.free(merged);
        @memcpy(merged[0..attachments.len], attachments);
        merged[attachments.len] = selection_attachment.?;
        effective_attachments = merged;
    }
    defer {
        if (has_selection) {
            host.allocator.free(effective_attachments);
            if (selection_attachment) |attachment| {
                host.allocator.free(attachment.label);
                if (attachment.text) |text| host.allocator.free(text);
            }
        }
    }

    const intent_text = intent orelse "";
    const route = ai.route_resolver.resolveHeuristic(.{
        .mode = mode,
        .intent = intent_text,
        .has_active_file = active_file != null,
        .has_selection = has_selection,
    }, .{
        .intent = intent,
        .explicit_files = explicit_files,
        .active_file = active_file,
        .attachments = effective_attachments,
        .include_project_rules = true,
        .workspace_cwd = host.workspace_path,
        .recent_files = recent,
        .supplement = supplement,
        .prefer_gemini_embeddings = !preview_only,
        .include_semantic_search = !preview_only,
        .environ_map = host.environ_map,
        .embedding = host.embeddingOptions(),
        .excluded_entries = host.agent.excluded_entries.items,
        .cache = &host.agent.context_cache,
    }).route;
    var context_opts = route.context;
    if (preview_only) {
        context_opts.allow_rebuild = false;
        context_opts.include_import_graph = false;
        context_opts.auto_semantic_search = false;
    }

    var tools_buf: [256]u8 = undefined;
    const tools_summary = ai.routing.formatToolsSummary(
        &tools_buf,
        route.capability_profile,
        route.intent,
        intent_text,
    );
    host.agent.setRoutingPreview(
        ai.routing.intentLabel(route.intent),
        @tagName(route.capability_profile),
        tools_summary,
    ) catch {};

    var builder = ai.context_loader.build(host.allocator, host.io, host.workspace_root, context_opts) catch return error.ProviderFailed;
    {
        var routing_buf: [128]u8 = undefined;
        const summary = ai.routing.formatRoutingSummary(&routing_buf, .{
            .mode = mode,
            .intent = intent_text,
            .has_active_file = active_file != null,
            .has_selection = has_selection,
        }, route);
        builder.addBlock(.intent, "routing", summary) catch {};
    }
    return builder;
}

fn collectAttachmentInputs(host: *const Host) ![]const ai.context_loader.AttachmentInput {
    host.agent.lock();
    defer host.agent.unlock();

    var items: std.ArrayList(ai.context_loader.AttachmentInput) = .empty;
    errdefer {
        for (items.items) |item| {
            host.allocator.free(item.label);
            if (item.text) |text| host.allocator.free(text);
            if (item.stored_path) |path| host.allocator.free(path);
        }
        items.deinit(host.allocator);
    }

    for (host.agent.attachments.items) |attachment| {
        try items.append(host.allocator, .{
            .kind = switch (attachment.kind) {
                .text_snippet => .text_snippet,
                .image => .image,
            },
            .label = try host.allocator.dupe(u8, attachment.label),
            .text = if (attachment.text_preview) |text| try host.allocator.dupe(u8, text) else null,
            .stored_path = if (attachment.stored_path) |path| try host.allocator.dupe(u8, path) else null,
        });
    }
    return try items.toOwnedSlice(host.allocator);
}

fn freeAttachmentInputs(allocator: std.mem.Allocator, items: []const ai.context_loader.AttachmentInput) void {
    for (items) |item| {
        allocator.free(item.label);
        if (item.text) |text| allocator.free(text);
        if (item.stored_path) |path| allocator.free(path);
    }
    allocator.free(items);
}
