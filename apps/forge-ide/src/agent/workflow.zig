const std = @import("std");
const ai = @import("forge-ai");
const workspace = @import("forge-workspace");
const kernel = @import("forge-kernel");
const session_mod = @import("session.zig");

pub const ChatRole = enum { user, agent };

pub const Host = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    ai_provider: []const u8,
    ai_model: ?[]const u8,
    workspace_root: workspace.WorkspaceRoot,
    agent: *session_mod.Session,
    agent_cancel_slot: *?*kernel.cancellation.CancellationTokenSource,
    context: ?*anyopaque,
    append_chat: *const fn (?*anyopaque, ChatRole, []const u8) void,
    refresh_explorer: *const fn (?*anyopaque) void,
    open_file: *const fn (?*anyopaque, []const u8) void,
};

pub const default_ask_response = ai.proposal_workflow.default_ask_response;
pub const default_plan_response = ai.proposal_workflow.default_plan_response;

pub const AgentError = error{
    AgentBusy,
    NoProposal,
    ProviderFailed,
    Cancelled,
    MissingProviderCredentials,
};

pub fn spawnGenerate(host: *const Host, intent: []const u8, scope_files: []const []const u8) AgentError!void {
    if (host.agent.worker_running) return error.AgentBusy;

    const ctx = host.allocator.create(GenerateContext) catch return error.ProviderFailed;
    ctx.* = .{
        .host = host.*,
        .intent = host.allocator.dupe(u8, intent) catch return error.ProviderFailed,
        .scope_files = dupeStringSlice(host.allocator, scope_files) catch return error.ProviderFailed,
        .cancel_source = kernel.cancellation.CancellationTokenSource.init(host.allocator) catch return error.ProviderFailed,
    };

    host.agent.resetForNewRun();
    host.agent.clearStreamText();
    host.agent.setPhase(.building_context, "Building context...") catch {};
    host.agent.lock();
    host.agent.worker_running = true;
    if (host.agent.intent) |old| host.allocator.free(old);
    host.agent.intent = host.allocator.dupe(u8, intent) catch "";
    host.agent.unlock();

    const thread = std.Thread.spawn(.{}, generateWorker, .{ctx}) catch {
        ctx.deinit();
        return error.ProviderFailed;
    };
    thread.detach();
}

pub fn cancel(host: *const Host) void {
    if (host.agent_cancel_slot.*) |source| source.cancel();
}

pub fn applyCurrentProposal(host: *const Host) AgentError!u64 {
    const proposal_rel = host.agent.proposal_rel orelse return error.NoProposal;
    host.agent.setPhase(.applying, "Applying proposal...") catch {};

    var proposal = workspace.OwnedProposal.readPath(host.allocator, host.io, host.workspace_root, proposal_rel) catch return error.ProviderFailed;
    defer proposal.deinit();

    const workspace_edit = proposal.workspaceEdit();
    workspace_edit.validate() catch return error.ProviderFailed;

    var service = workspace.TransactionService.init(host.allocator, host.io, host.workspace_root);
    const tx_id = workspace.history.nextTransactionId(host.allocator, host.io, host.workspace_root) catch return error.ProviderFailed;

    var record = workspace.TransactionRecord{
        .id = tx_id,
        .state = .approved,
        .workspace_edit = workspace_edit,
        .timestamp_ms = std.Io.Timestamp.now(host.io, .real).toMilliseconds(),
    };
    defer service.freeRecord(&record);

    service.apply(&record) catch return error.ProviderFailed;
    workspace.history.persistApplied(host.allocator, host.io, host.workspace_root, &record, proposal_rel) catch return error.ProviderFailed;

    host.agent.lock();
    host.agent.last_transaction_id = tx_id;
    host.agent.show_review = false;
    host.agent.phase = .done;
    if (host.agent.status_line.len > 0) host.allocator.free(host.agent.status_line);
    host.agent.status_line = host.allocator.dupe(u8, "Applied successfully") catch "";
    host.agent.unlock();

    host.refresh_explorer(host.context);
    for (proposal.files) |file| {
        host.open_file(host.context, file.path);
    }

    return tx_id;
}

pub fn loadProposalPreview(host: *const Host, proposal_rel: []const u8) !void {
    var proposal = try workspace.OwnedProposal.readPath(host.allocator, host.io, host.workspace_root, proposal_rel);
    defer proposal.deinit();

    const edit = proposal.workspaceEdit();
    try edit.validate();

    var diff_writer = std.Io.Writer.Allocating.init(host.allocator);
    defer diff_writer.deinit();
    try workspace.preview.renderDiff(host.allocator, host.io, host.workspace_root, edit, &diff_writer.writer);

    host.agent.lock();
    defer host.agent.unlock();

    clearLines(host.allocator, &host.agent.diff_lines);

    const diff_bytes = diff_writer.writer.buffer[0..diff_writer.writer.end];
    var diff_it = std.mem.splitScalar(u8, diff_bytes, '\n');
    while (diff_it.next()) |line| {
        if (line.len == 0) continue;
        try host.agent.diff_lines.append(host.allocator, try host.allocator.dupe(u8, line));
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

    try host.agent.context_lines.append(host.allocator, try std.fmt.allocPrint(host.allocator, "Proposal: {s}", .{proposal_rel}));

    host.agent.show_review = true;
    host.agent.phase = .reviewing;
    host.agent.review_scroll_y = 0;
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
    cancel_source: kernel.cancellation.CancellationTokenSource,

    fn deinit(self: *GenerateContext) void {
        self.host.allocator.free(self.intent);
        freeStringSlice(self.host.allocator, self.scope_files);
        self.cancel_source.deinit();
        self.host.allocator.destroy(self);
    }
};

fn providerOptions(host: *const Host, fake_response: []const u8) ai.provider_factory.Options {
    return .{
        .kind = ai.provider_factory.Kind.parse(host.ai_provider),
        .model = host.ai_model,
        .fake_response = fake_response,
        .stream_callback = streamBridge,
        .stream_context = @ptrCast(@constCast(host)),
    };
}

fn generateWorker(ctx: *GenerateContext) void {
    defer ctx.deinit();

    ctx.host.agent_cancel_slot.* = &ctx.cancel_source;
    defer ctx.host.agent_cancel_slot.* = null;

    const fake_response = switch (ctx.host.agent.mode) {
        .ask => default_ask_response,
        .plan => default_plan_response,
    };

    generateInner(ctx, providerOptions(&ctx.host, fake_response)) catch |err| {
        const msg = switch (err) {
            error.Cancelled => "Cancelled",
            error.MissingProviderCredentials => "Missing provider credentials",
            else => "Agent failed",
        };
        ctx.host.agent.lock();
        ctx.host.agent.phase = if (err == error.Cancelled) .cancelled else .failed;
        if (ctx.host.agent.status_line.len > 0) ctx.host.allocator.free(ctx.host.agent.status_line);
        ctx.host.agent.status_line = ctx.host.allocator.dupe(u8, msg) catch "";
        ctx.host.agent.worker_running = false;
        ctx.host.agent.unlock();
        ctx.host.append_chat(ctx.host.context, .agent, msg);
    };
}

fn generateInner(ctx: *GenerateContext, provider_options: ai.provider_factory.Options) AgentError!void {
    const host = &ctx.host;
    const cancel_token = ctx.cancel_source.getToken();

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
                .ask => .ask,
                .plan => .plan,
            },
            .cancel_token = &cancel_token,
            .progress_callback = phaseBridge,
            .progress_context = host,
            .stream_callback = streamBridge,
            .stream_context = host,
        },
    ) catch |err| switch (err) {
        ai.proposal_workflow.WorkflowError.Cancelled => return error.Cancelled,
        ai.proposal_workflow.WorkflowError.MissingProviderCredentials => return error.MissingProviderCredentials,
        else => return error.ProviderFailed,
    };
    defer ai.proposal_workflow.deinitResult(host.allocator, &result);

    var builder = ai.context_loader.build(host.allocator, host.io, host.workspace_root, .{
        .intent = ctx.intent,
        .explicit_files = ctx.scope_files,
        .include_project_rules = true,
    }) catch return;
    defer builder.deinit();
    captureContextManifest(host, &builder) catch {};

    host.agent.lock();
    host.agent.run_id = host.allocator.dupe(u8, result.run_id) catch null;
    host.agent.proposal_rel = host.allocator.dupe(u8, result.proposal_rel) catch null;
    host.agent.worker_running = false;
    host.agent.phase = .proposal_ready;
    if (host.agent.status_line.len > 0) host.allocator.free(host.agent.status_line);
    host.agent.status_line = host.allocator.dupe(u8, "Proposal ready for review") catch "";
    host.agent.unlock();

    loadProposalPreview(host, result.proposal_rel) catch {};
    refreshRunHistory(host) catch {};

    var status_buf: [256]u8 = undefined;
    const agent_msg = std.fmt.bufPrint(&status_buf, "Proposal ready: {s}", .{result.proposal_rel}) catch "Proposal ready";
    host.append_chat(host.context, .agent, agent_msg);
}

fn phaseBridge(context: ?*anyopaque, phase: ai.progress.Phase) void {
    const host: *Host = @ptrCast(@alignCast(context.?));
    if (phase == .sending) host.agent.clearStreamText();
    const mapped: session_mod.Phase = switch (phase) {
        .context_built => .building_context,
        .sending => .sending,
        .streaming => .streaming,
        .parsing => .parsing,
        .proposal_ready => .proposal_ready,
    };
    const label = switch (phase) {
        .context_built => "Building context...",
        .sending => "Sending to provider...",
        .streaming => "Streaming response...",
        .parsing => "Parsing proposal...",
        .proposal_ready => "Proposal ready for review",
    };
    host.agent.setPhase(mapped, label) catch {};
}

fn streamBridge(context: ?*anyopaque, chunk: []const u8) void {
    const host: *Host = @ptrCast(@alignCast(context.?));
    host.agent.appendStreamChunk(chunk) catch {};
}

fn captureContextManifest(host: *const Host, builder: *const ai.context.ContextBuilder) !void {
    var manifest_writer = std.Io.Writer.Allocating.init(host.allocator);
    defer manifest_writer.deinit();
    try ai.context_loader.renderManifestHuman(builder, &manifest_writer.writer);

    host.agent.lock();
    defer host.agent.unlock();
    clearLines(host.allocator, &host.agent.context_lines);

    const bytes = manifest_writer.writer.buffer[0..manifest_writer.writer.end];
    var line_it = std.mem.splitScalar(u8, bytes, '\n');
    while (line_it.next()) |line| {
        if (line.len == 0) continue;
        try host.agent.context_lines.append(host.allocator, try host.allocator.dupe(u8, line));
    }
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
