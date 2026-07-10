const std = @import("std");
const workspace = @import("forge-workspace");
const kernel = @import("forge-kernel");
const provider_factory = @import("provider_factory.zig");
const context_loader = @import("context_loader.zig");
const codebase_search = @import("codebase_search.zig");
const routing = @import("routing.zig");
const context_phase = @import("agent/context_phase.zig");
const tools = @import("tools.zig");
const planner = @import("planner.zig");
const multimodal = @import("multimodal.zig");
const progress = @import("progress.zig");
const provider = @import("provider.zig");
const run_record = @import("run_record.zig");
const spec_writer = @import("spec_writer.zig");
const validation_hints = @import("validation_hints.zig");
const repair_loop = @import("repair_loop.zig");
const proposal_normalize = @import("proposal_normalize.zig");
const proposal_precondition = @import("proposal_precondition.zig");

pub const Mode = enum { ask, plan };

pub const PlanPhase = enum {
    full,
    plan_only,
    proposal_only,
};

pub const WorkflowError = error{
    MissingProviderCredentials,
    ProviderFailed,
    InvalidProposal,
    Cancelled,
} || provider.ProviderError;

pub const GenerateOptions = struct {
    surface: run_record.Surface = .cli,
    mode: Mode = .ask,
    plan_phase: PlanPhase = .full,
    continue_run_id: ?[]const u8 = null,
    cancel_token: ?*const kernel.cancellation.CancellationToken = null,
    progress_callback: ?*const fn (?*anyopaque, progress.Phase) void = null,
    progress_context: ?*anyopaque = null,
    stream_callback: ?*const fn (?*anyopaque, []const u8) void = null,
    stream_context: ?*anyopaque = null,
    thinking_callback: ?*const fn (?*anyopaque, []const u8) void = null,
    thinking_context: ?*anyopaque = null,
    include_project_rules: bool = true,
    active_file: ?[]const u8 = null,
    attachments: []const context_loader.AttachmentInput = &.{},
    conversation: []const @import("conversation.zig").Turn = &.{},
    workspace_cwd: ?[]const u8 = null,
    recent_files: []const []const u8 = &.{},
    embedding: codebase_search.EmbeddingOptions = .{},
    /// Repair trials run inside a disposable workspace snapshot. This protects
    /// the authoritative tree from edits, but is not an OS security boundary.
    enable_repair_loop: bool = false,
    max_repair_attempts: u8 = 2,
};

pub const Result = struct {
    run_id: []const u8,
    proposal_rel: []const u8,
    proposal_body: []const u8,
    plan_body: ?[]const u8 = null,
    plan_rel: ?[]const u8 = null,
};

pub fn validateProposalBody(allocator: std.mem.Allocator, proposal_body: []const u8) WorkflowError!void {
    const normalized = proposal_normalize.normalize(allocator, proposal_body) catch return error.InvalidProposal;
    defer allocator.free(normalized);
    // Do not log raw model output here: proposals may contain source or secrets.
    var parsed_proposal = workspace.OwnedProposal.parseJson(allocator, normalized) catch return error.InvalidProposal;
    defer parsed_proposal.deinit();
    if (parsed_proposal.files.len == 0) return;
    parsed_proposal.workspaceEdit().validate() catch return error.InvalidProposal;
}

pub fn emitProgress(options: GenerateOptions, phase: progress.Phase) void {
    if (options.progress_callback) |callback| {
        callback(options.progress_context, phase);
    }
}

pub fn generateAndPersist(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    root: workspace.WorkspaceRoot,
    intent: []const u8,
    files: []const []const u8,
    provider_options: provider_factory.Options,
    options: GenerateOptions,
) WorkflowError!Result {
    var provider_handle = provider_factory.create(allocator, io, environ_map, .{
        .provider_name = provider_options.provider_name,
        .base_url = provider_options.base_url,
        .model = provider_options.model,
        .fake_response = provider_options.fake_response,
        .fake_plan_response = provider_options.fake_plan_response,
        .stream_callback = options.stream_callback,
        .stream_context = options.stream_context,
        .thinking_callback = options.thinking_callback,
        .thinking_context = options.thinking_context,
    }) catch |err| {
        if (err == error.MissingCredentials) {
            return error.MissingProviderCredentials;
        }
        return error.ProviderInternalError;
    };
    defer provider_handle.deinit(allocator);

    const route_input = routing.RouteInput{
        .mode = switch (options.mode) {
            .ask => tools.Mode.ask,
            .plan => tools.Mode.plan,
        },
        .intent = intent,
        .has_active_file = options.active_file != null,
    };
    var resolved_context = context_phase.build(allocator, io, root, .{
        .route = route_input,
        .load = .{
            .intent = intent,
            .explicit_files = files,
            .include_project_rules = options.include_project_rules,
            .active_file = options.active_file,
            .attachments = options.attachments,
            .workspace_cwd = options.workspace_cwd,
            .recent_files = options.recent_files,
            .embedding = options.embedding,
        },
        .provider = provider_handle,
        .cancel_token = options.cancel_token,
    }) catch return error.ProviderFailed;
    defer resolved_context.deinit();
    var ctx_builder = &resolved_context.builder;
    emitProgress(options, .context_built);

    const timestamp_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    const run_id = if (options.continue_run_id) |existing|
        allocator.dupe(u8, existing) catch return error.ProviderFailed
    else
        run_record.makeRunId(allocator, timestamp_ms) catch return error.ProviderFailed;
    errdefer allocator.free(run_id);

    const llm = provider_handle;
    const meta = llm.metadata();

    const images = multimodal.loadImages(allocator, io, root, options.attachments) catch &[_]provider.ImagePart{};
    defer if (images.len > 0) multimodal.freeImages(allocator, images);

    var plan_inst = planner.Planner.init(allocator, llm, ctx_builder, options.conversation, images);

    var cancel_src = kernel.cancellation.CancellationTokenSource.init(allocator) catch return error.ProviderFailed;
    defer cancel_src.deinit();
    const local_token = cancel_src.getToken();
    const cancel_token: *const kernel.cancellation.CancellationToken = options.cancel_token orelse &local_token;

    var owned_plan_body: ?[]u8 = null;
    errdefer if (owned_plan_body) |body| allocator.free(body);
    var owned_plan_rel: ?[]u8 = null;
    errdefer if (owned_plan_rel) |path| allocator.free(path);

    if (options.mode == .plan and options.plan_phase != .proposal_only) {
        emitProgress(options, .planning);
        var plan_writer = std.Io.Writer.Allocating.init(allocator);
        defer plan_writer.deinit();

        plan_inst.planMarkdown(&plan_writer.writer, cancel_token) catch |err| {
            if (cancel_token.isCancelled()) return error.Cancelled;
            return err;
        };
        emitProgress(options, .plan_ready);

        const plan_body = plan_writer.writer.buffer[0..plan_writer.writer.end];
        owned_plan_body = allocator.dupe(u8, plan_body) catch return error.ProviderFailed;

        var plan_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const plan_rel = std.fmt.bufPrint(&plan_path_buf, ".forge/plans/{s}.md", .{run_id}) catch return error.ProviderFailed;
        owned_plan_rel = allocator.dupe(u8, plan_rel) catch return error.ProviderFailed;

        workspace.history.ensureLayout(allocator, io, root) catch return error.ProviderFailed;
        root.dir.createDirPath(io, ".forge/plans") catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return error.ProviderFailed,
        };
        workspace.atomic.replaceFile(io, root, workspace.WorkspacePath.parse(plan_rel) catch return error.ProviderFailed, plan_body) catch return error.ProviderFailed;

        spec_writer.persistFromPlan(allocator, io, root, run_id, plan_body, intent) catch {};

        ctx_builder.addBlock(.intent, "implementation_plan", plan_body) catch return error.ProviderFailed;
        plan_inst = planner.Planner.init(allocator, llm, ctx_builder, options.conversation, images);
    } else if (options.mode == .plan and options.plan_phase == .proposal_only) {
        var plan_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const plan_rel = std.fmt.bufPrint(&plan_path_buf, ".forge/plans/{s}.md", .{run_id}) catch return error.ProviderFailed;
        var plan_snap = workspace.FileSnapshot.read(allocator, io, root, workspace.WorkspacePath.parse(plan_rel) catch return error.ProviderFailed) catch return error.ProviderFailed;
        defer plan_snap.deinit();
        owned_plan_body = allocator.dupe(u8, plan_snap.content) catch return error.ProviderFailed;
        owned_plan_rel = allocator.dupe(u8, plan_rel) catch return error.ProviderFailed;
        ctx_builder.addBlock(.intent, "implementation_plan", plan_snap.content) catch return error.ProviderFailed;
        plan_inst = planner.Planner.init(allocator, llm, ctx_builder, options.conversation, images);
    }

    if (options.mode == .plan and options.plan_phase == .plan_only) {
        const record = run_record.Record{
            .run_id = run_id,
            .surface = options.surface,
            .intent = intent,
            .state = .planning,
            .proposal_path = "",
            .provider_id = meta.provider_name,
            .model_id = meta.model_name,
            .timestamp_ms = timestamp_ms,
        };
        const json_body = run_record.formatJson(allocator, record) catch return error.ProviderFailed;
        defer allocator.free(json_body);
        workspace.runs.persistRun(allocator, io, root, run_id, json_body) catch return error.ProviderFailed;
        const index_line = run_record.formatIndexLine(allocator, record) catch return error.ProviderFailed;
        defer allocator.free(index_line);
        workspace.runs.appendIndex(allocator, io, root, index_line) catch return error.ProviderFailed;
        emitProgress(options, .plan_ready);

        return .{
            .run_id = run_id,
            .proposal_rel = allocator.dupe(u8, "") catch return error.ProviderFailed,
            .proposal_body = allocator.dupe(u8, "") catch return error.ProviderFailed,
            .plan_body = owned_plan_body,
            .plan_rel = owned_plan_rel,
        };
    }

    var response = std.Io.Writer.Allocating.init(allocator);
    defer response.deinit();

    const workspace_cwd = options.workspace_cwd orelse ".";
    const max_repair = if (options.enable_repair_loop) options.max_repair_attempts else 0;
    var owned_body: ?[]u8 = null;
    errdefer if (owned_body) |body| allocator.free(body);
    var last_validation_report: ?[]u8 = null;
    errdefer if (last_validation_report) |report| allocator.free(report);
    var attempt: u8 = 0;
    var use_repair_prompt = false;
    var json_repair_attempts: u8 = 0;

    while (true) {
        response.writer.end = 0;
        if (!use_repair_prompt) {
            emitProgress(options, .sending);
            plan_inst.plan(&response.writer, cancel_token) catch |err| {
                if (cancel_token.isCancelled()) return error.Cancelled;
                return err;
            };
        } else {
            emitProgress(options, .repairing);
            plan_inst.planRepair(&response.writer, cancel_token, last_validation_report.?, owned_body.?) catch |err| {
                if (cancel_token.isCancelled()) return error.Cancelled;
                return err;
            };
        }
        emitProgress(options, .streaming);
        emitProgress(options, .parsing);

        const proposal_body = response.writer.buffer[0..response.writer.end];
        const normalized = proposal_normalize.normalize(allocator, proposal_body) catch {
            if (json_repair_attempts < 2) {
                json_repair_attempts += 1;
                use_repair_prompt = true;
                if (last_validation_report) |old| allocator.free(old);
                last_validation_report = std.fmt.allocPrint(
                    allocator,
                    "proposal JSON normalization failed. Output ONLY raw JSON for schema_version 1.\n\nModel output (truncated):\n{s}",
                    .{if (proposal_body.len > 1500) proposal_body[0..1500] else proposal_body},
                ) catch return error.InvalidProposal;
                if (owned_body) |old| allocator.free(old);
                owned_body = allocator.dupe(u8, proposal_body) catch return error.ProviderFailed;
                continue;
            }
            return error.InvalidProposal;
        };
        defer allocator.free(normalized);

        const prepared = proposal_precondition.fillMissingExpectedHashes(allocator, io, root, normalized) catch normalized;
        defer if (prepared.ptr != normalized.ptr) allocator.free(prepared);

        validateProposalBody(allocator, prepared) catch {
            if (json_repair_attempts < 2) {
                json_repair_attempts += 1;
                use_repair_prompt = true;
                if (last_validation_report) |old| allocator.free(old);
                last_validation_report = std.fmt.allocPrint(
                    allocator,
                    "proposal JSON validation failed. For modify/delete set expected_hash from file snapshot context, or use operation create for new files. Output ONLY valid WorkspaceEdit JSON.\n\nModel output (truncated):\n{s}",
                    .{if (prepared.len > 1500) prepared[0..1500] else prepared},
                ) catch return error.InvalidProposal;
                if (owned_body) |old| allocator.free(old);
                owned_body = allocator.dupe(u8, prepared) catch return error.ProviderFailed;
                continue;
            }
            return error.InvalidProposal;
        };
        use_repair_prompt = false;

        const augmented_body = validation_hints.augmentProposalJson(allocator, prepared) catch return error.ProviderFailed;
        defer allocator.free(augmented_body);

        if (owned_body) |old| allocator.free(old);
        owned_body = allocator.dupe(u8, augmented_body) catch return error.ProviderFailed;

        if (max_repair == 0) break;

        const trial = repair_loop.trialApplyAndValidate(allocator, io, root, workspace_cwd, owned_body.?) catch break;
        if (trial.passed) {
            if (trial.hint_paths.len > 0) {
                for (trial.hint_paths) |p| allocator.free(p);
                allocator.free(trial.hint_paths);
            }
            allocator.free(trial.report);
            break;
        }
        if (attempt >= max_repair) {
            if (trial.hint_paths.len > 0) {
                for (trial.hint_paths) |p| allocator.free(p);
                allocator.free(trial.hint_paths);
            }
            allocator.free(trial.report);
            break;
        }

        ctx_builder.addBlock(.diagnostic, "validation_failure", trial.report) catch {
            allocator.free(trial.report);
            return error.ProviderFailed;
        };
        ctx_builder.addBlock(.intent, "failed_proposal", owned_body.?) catch return error.ProviderFailed;
        plan_inst = planner.Planner.init(allocator, llm, ctx_builder, options.conversation, images);
        if (last_validation_report) |old| allocator.free(old);
        last_validation_report = allocator.dupe(u8, trial.report) catch {
            if (trial.hint_paths.len > 0) {
                for (trial.hint_paths) |p| allocator.free(p);
                allocator.free(trial.hint_paths);
            }
            allocator.free(trial.report);
            return error.ProviderFailed;
        };
        if (trial.hint_paths.len > 0) {
            for (trial.hint_paths) |p| allocator.free(p);
            allocator.free(trial.hint_paths);
        }
        allocator.free(trial.report);
        use_repair_prompt = true;
        attempt += 1;
    }

    if (last_validation_report) |report| allocator.free(report);

    const final_body = owned_body orelse return error.ProviderFailed;
    owned_body = null;

    workspace.history.ensureLayout(allocator, io, root) catch return error.ProviderFailed;
    var proposal_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const proposal_rel = std.fmt.bufPrint(&proposal_path_buf, ".forge/proposals/{s}.json", .{run_id}) catch return error.ProviderFailed;
    workspace.atomic.ensureProposalDir(io, root) catch return error.ProviderFailed;
    workspace.atomic.replaceFile(io, root, workspace.WorkspacePath.parse(proposal_rel) catch return error.ProviderFailed, final_body) catch return error.ProviderFailed;

    const initial_state: run_record.State = .proposed;

    const record = run_record.Record{
        .run_id = run_id,
        .surface = options.surface,
        .intent = intent,
        .state = initial_state,
        .proposal_path = proposal_rel,
        .provider_id = meta.provider_name,
        .model_id = meta.model_name,
        .timestamp_ms = timestamp_ms,
    };

    const json_body = run_record.formatJson(allocator, record) catch return error.ProviderFailed;
    defer allocator.free(json_body);
    workspace.runs.persistRun(allocator, io, root, run_id, json_body) catch return error.ProviderFailed;

    const index_line = run_record.formatIndexLine(allocator, record) catch return error.ProviderFailed;
    defer allocator.free(index_line);
    workspace.runs.appendIndex(allocator, io, root, index_line) catch return error.ProviderFailed;

    emitProgress(options, .proposal_ready);

    const owned_proposal_rel = allocator.dupe(u8, proposal_rel) catch return error.ProviderFailed;

    return .{
        .run_id = run_id,
        .proposal_rel = owned_proposal_rel,
        .proposal_body = final_body,
        .plan_body = owned_plan_body,
        .plan_rel = owned_plan_rel,
    };
}

pub fn deinitResult(allocator: std.mem.Allocator, result: *Result) void {
    allocator.free(result.run_id);
    allocator.free(result.proposal_rel);
    allocator.free(result.proposal_body);
    if (result.plan_body) |body| allocator.free(body);
    if (result.plan_rel) |path| allocator.free(path);
    result.* = undefined;
}

pub const default_ask_response =
    \\{"schema_version":1,"summary":"Create notes.txt from ask intent","assumptions":["No conflicting notes.txt exists"],"validation_tasks":["zig build test"],"workspace_edit":{"files":[{"path":"notes.txt","operation":"create","edits":[{"start":0,"end":0,"replacement":"generated by forge ask\n"}]}]}}
;

const eval_sample_seed = "hello forge search\n";

pub const default_agent_modify_sample_response = blk: {
    const hash = workspace.edit.contentHash(eval_sample_seed);
    break :blk std.fmt.comptimePrint(
        \\{{"schema_version":1,"summary":"Add reliability marker to sample.txt","assumptions":["sample.txt matches eval seed"],"validation_tasks":["zig build test"],"workspace_edit":{{"files":[{{"path":"sample.txt","operation":"modify","expected_hash":{d},"edits":[{{"search":"hello forge search\n","replacement":"hello forge search\nreliability marker\n"}}]}}]}}}}
    , .{hash});
};

/// Picks deterministic fake agent proposals for eval fixtures and CLI dogfood.
pub fn fakeAgentResponseForIntent(intent: []const u8) []const u8 {
    if (intentContains(intent, "reliability marker") or intentContains(intent, "modify sample"))
        return default_agent_modify_sample_response;
    return default_ask_response;
}

fn intentContains(haystack: []const u8, needle: []const u8) bool {
    var lower_buf: [512]u8 = undefined;
    const lower = toLowerBounded(haystack, &lower_buf);
    var needle_buf: [128]u8 = undefined;
    const needle_lower = toLowerBounded(needle, &needle_buf);
    return std.mem.indexOf(u8, lower, needle_lower) != null;
}

fn toLowerBounded(text: []const u8, buf: []u8) []const u8 {
    const n = @min(text.len, buf.len);
    for (text[0..n], 0..) |c, i| {
        buf[i] = std.ascii.toLower(c);
    }
    return buf[0..n];
}

pub const default_plan_response =
    \\{"schema_version":1,"summary":"Create plan.txt from planner","assumptions":["Workspace is writable"],"validation_tasks":["zig build test"],"workspace_edit":{"files":[{"path":"plan.txt","operation":"create","edits":[{"start":0,"end":0,"replacement":"planned change\n"}]}]}}
;

pub const default_plan_markdown: []const u8 =
    \\# Implementation Plan
    \\
    \\## Goal
    \\Apply the requested change safely in the workspace.
    \\
    \\## Steps
    \\1. Inspect scoped files
    \\2. Apply minimal edit
    \\3. Run `zig build test`
    \\
    \\## Risks
    \\- May conflict with existing files
;

test "fakeAgentResponseForIntent maps modify fixture to sample.txt edit" {
    const response = fakeAgentResponseForIntent("Modify sample.txt so it also contains reliability marker");
    try std.testing.expect(std.mem.indexOf(u8, response, "sample.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "reliability marker") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"operation\":\"modify\"") != null);
}

test "cli and ide surfaces produce identical proposal bodies" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const forge_home = try initProposalTestHome(allocator, &tmp);
    defer allocator.free(forge_home);
    defer workspace.global_store.clearForgeHomeOverride();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");

    const rules = "# rules\nUse zig fmt.\n";
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("FORGE.md"), rules);
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("forge.toml"), "[ai]\napply_mode = \"review\"\n");

    const intent = "add notes";
    const files = [_][]const u8{"sample.txt"};
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("sample.txt"), "hello\n");

    const provider_options = provider_factory.Options{
        .provider_name = "fake",
        .fake_response = default_ask_response,
    };

    var cli_result = try generateAndPersist(allocator, io, null, root, intent, &files, provider_options, .{
        .surface = .cli,
        .mode = .ask,
    });
    defer deinitResult(allocator, &cli_result);

    var ide_result = try generateAndPersist(allocator, io, null, root, intent, &files, provider_options, .{
        .surface = .ide,
        .mode = .ask,
    });
    defer deinitResult(allocator, &ide_result);

    try std.testing.expectEqualStrings(cli_result.proposal_body, ide_result.proposal_body);

    var cli_proposal = try workspace.OwnedProposal.parseJson(allocator, cli_result.proposal_body);
    defer cli_proposal.deinit();
    var ide_proposal = try workspace.OwnedProposal.parseJson(allocator, ide_result.proposal_body);
    defer ide_proposal.deinit();

    try std.testing.expectEqual(cli_proposal.files.len, ide_proposal.files.len);
    try std.testing.expectEqualStrings(
        cli_proposal.metadata.summary orelse "",
        ide_proposal.metadata.summary orelse "",
    );
}

test "cli and ide proposals have identical apply and undo outcomes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var cli_tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer cli_tmp.cleanup();
    var ide_tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer ide_tmp.cleanup();
    const forge_home = try initProposalTestHome(allocator, &cli_tmp);
    defer allocator.free(forge_home);
    defer workspace.global_store.clearForgeHomeOverride();
    const cli_root = workspace.WorkspaceRoot.init(cli_tmp.dir, ".");
    const ide_root = workspace.WorkspaceRoot.init(ide_tmp.dir, ".");

    const provider_options = provider_factory.Options{
        .provider_name = "fake",
        .fake_response = default_ask_response,
    };
    var cli_result = try generateAndPersist(allocator, io, null, cli_root, "create notes", &.{}, provider_options, .{ .surface = .cli });
    defer deinitResult(allocator, &cli_result);
    var ide_result = try generateAndPersist(allocator, io, null, ide_root, "create notes", &.{}, provider_options, .{ .surface = .ide });
    defer deinitResult(allocator, &ide_result);

    var cli_proposal = try workspace.OwnedProposal.parseJson(allocator, cli_result.proposal_body);
    defer cli_proposal.deinit();
    var ide_proposal = try workspace.OwnedProposal.parseJson(allocator, ide_result.proposal_body);
    defer ide_proposal.deinit();

    const cli_tx = try workspace.execution.applyApproved(allocator, io, cli_root, cli_proposal.workspaceEdit(), cli_result.proposal_rel);
    const ide_tx = try workspace.execution.applyApproved(allocator, io, ide_root, ide_proposal.workspaceEdit(), ide_result.proposal_rel);
    try std.testing.expectEqual(cli_tx, ide_tx);

    var cli_after = try workspace.FileSnapshot.read(allocator, io, cli_root, try workspace.WorkspacePath.parse("notes.txt"));
    defer cli_after.deinit();
    var ide_after = try workspace.FileSnapshot.read(allocator, io, ide_root, try workspace.WorkspacePath.parse("notes.txt"));
    defer ide_after.deinit();
    try std.testing.expectEqualStrings(cli_after.content, ide_after.content);

    var cli_loaded = try workspace.history.loadRecord(allocator, io, cli_root, cli_tx);
    var cli_service = workspace.TransactionService.init(allocator, io, cli_root);
    defer cli_loaded.deinit(&cli_service);
    var ide_loaded = try workspace.history.loadRecord(allocator, io, ide_root, ide_tx);
    var ide_service = workspace.TransactionService.init(allocator, io, ide_root);
    defer ide_loaded.deinit(&ide_service);
    try cli_service.undo(&cli_loaded.record);
    try ide_service.undo(&ide_loaded.record);

    try std.testing.expectError(error.FileNotFound, cli_root.dir.access(io, "notes.txt", .{}));
    try std.testing.expectError(error.FileNotFound, ide_root.dir.access(io, "notes.txt", .{}));
}

test "project rules are included in context manifest" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const forge_home = try initProposalTestHome(allocator, &tmp);
    defer allocator.free(forge_home);
    defer workspace.global_store.clearForgeHomeOverride();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");

    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("FORGE.md"), "# Rules\nAlways test.\n");

    var builder = try context_loader.build(allocator, io, root, .{
        .intent = "test",
        .include_project_rules = true,
    });
    defer builder.deinit();

    var found_rules = false;
    for (builder.blocks.items) |block| {
        if (block.block_type == .rules and std.mem.eql(u8, block.name, "FORGE.md")) found_rules = true;
    }
    try std.testing.expect(found_rules);
}

test "generateAndPersist wraps unparseable model text into empty proposal" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const forge_home = try initProposalTestHome(allocator, &tmp);
    defer allocator.free(forge_home);
    defer workspace.global_store.clearForgeHomeOverride();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");

    const provider_options = provider_factory.Options{
        .provider_name = "fake",
        .fake_response = "not valid proposal json",
    };

    var result = try generateAndPersist(allocator, io, null, root, "test", &.{}, provider_options, .{});
    defer deinitResult(allocator, &result);
    try std.testing.expect(std.mem.indexOf(u8, result.proposal_body, "\"workspace_edit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.proposal_body, "\"files\":[]") != null);
}

test "generateAndPersist with ollama when server is running" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const ollama_provider = @import("providers/ollama/provider.zig");
    if (!liveTestsEnabled()) return error.SkipZigTest;
    if (!ollama_provider.isReachable(allocator, io, ollama_provider.default_host)) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const forge_home = try initProposalTestHome(allocator, &tmp);
    defer allocator.free(forge_home);
    defer workspace.global_store.clearForgeHomeOverride();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("sample.txt"), "hello\n");

    const provider_options = provider_factory.Options{
        .provider_name = "ollama",
        .model = ollama_provider.default_model,
        .fake_response = "",
    };

    var cancel_src = try kernel.cancellation.CancellationTokenSource.init(allocator);
    defer cancel_src.deinit();
    const token = cancel_src.getToken();

    var result = try generateAndPersist(allocator, io, null, root, "add a comment to sample.txt", &.{}, provider_options, .{
        .cancel_token = &token,
        .progress_callback = struct {
            fn cb(_: ?*anyopaque, _: progress.Phase) void {}
        }.cb,
    });
    defer deinitResult(allocator, &result);
    try std.testing.expect(result.proposal_rel.len > 0);
}

test "generateAndPersist ollama via WorkspaceRoot.open path" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const ollama_provider = @import("providers/ollama/provider.zig");
    if (!liveTestsEnabled()) return error.SkipZigTest;
    if (!ollama_provider.isReachable(allocator, io, ollama_provider.default_host)) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const seed_root = workspace.WorkspaceRoot.init(tmp.dir, ".");
    try workspace.atomic.replaceFile(io, seed_root, try workspace.WorkspacePath.parse("sample.txt"), "hello\n");

    var ws_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ws = try std.fmt.bufPrint(&ws_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var opened_root = try workspace.WorkspaceRoot.open(io, ws);
    defer opened_root.close(io);

    const provider_options = provider_factory.Options{
        .provider_name = "ollama",
        .model = ollama_provider.default_model,
        .fake_response = "",
    };

    var result = try generateAndPersist(allocator, io, null, opened_root, "add a comment to sample.txt", &.{}, provider_options, .{});
    defer deinitResult(allocator, &result);
    try std.testing.expect(result.proposal_rel.len > 0);
}

fn liveTestsEnabled() bool {
    return false;
}

fn initProposalTestHome(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]const u8 {
    const path = try std.fmt.allocPrint(allocator, "/tmp/forge-proposal-test-{s}", .{tmp.sub_path});
    try workspace.global_store.setForgeHomeOverride(path);
    return path;
}
