const std = @import("std");
const workspace = @import("forge-workspace");
const kernel = @import("forge-kernel");
const provider_factory = @import("provider_factory.zig");
const context_loader = @import("context_loader.zig");
const planner = @import("planner.zig");
const multimodal = @import("multimodal.zig");
const progress = @import("progress.zig");
const provider = @import("provider.zig");
const run_record = @import("run_record.zig");

pub const Mode = enum { ask, plan };

pub const WorkflowError = error{
    MissingProviderCredentials,
    ProviderFailed,
    InvalidProposal,
    Cancelled,
} || provider.ProviderError;

pub const GenerateOptions = struct {
    surface: run_record.Surface = .cli,
    mode: Mode = .ask,
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
};

pub const Result = struct {
    run_id: []const u8,
    proposal_rel: []const u8,
    proposal_body: []const u8,
    plan_body: ?[]const u8 = null,
    plan_rel: ?[]const u8 = null,
};

pub fn validateProposalBody(allocator: std.mem.Allocator, proposal_body: []const u8) WorkflowError!void {
    var parsed_proposal = workspace.OwnedProposal.parseJson(allocator, proposal_body) catch return error.InvalidProposal;
    defer parsed_proposal.deinit();
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
        .kind = provider_options.kind,
        .model = provider_options.model,
        .fake_response = provider_options.fake_response,
        .fake_plan_response = provider_options.fake_plan_response,
        .stream_callback = options.stream_callback,
        .stream_context = options.stream_context,
        .thinking_callback = options.thinking_callback,
        .thinking_context = options.thinking_context,
    }) catch |err| switch (err) {
        provider_factory.FactoryError.MissingCredentials => return error.MissingProviderCredentials,
        else => return error.ProviderFailed,
    };
    defer provider_handle.deinit();

    var ctx_builder = context_loader.build(allocator, io, root, .{
        .intent = intent,
        .explicit_files = files,
        .include_project_rules = options.include_project_rules,
        .active_file = options.active_file,
        .attachments = options.attachments,
        .workspace_cwd = options.workspace_cwd,
        .recent_files = options.recent_files,
    }) catch return error.ProviderFailed;
    defer ctx_builder.deinit();
    emitProgress(options, .context_built);

    const timestamp_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    const run_id = run_record.makeRunId(allocator, timestamp_ms) catch return error.ProviderFailed;
    errdefer allocator.free(run_id);

    const llm = provider_handle.interface();
    const meta = llm.metadata();

    const images = multimodal.loadImages(allocator, io, root, options.attachments) catch &[_]provider.ImagePart{};
    defer if (images.len > 0) multimodal.freeImages(allocator, images);

    var plan_inst = planner.Planner.init(allocator, llm, &ctx_builder, options.conversation, images);

    var cancel_src = kernel.cancellation.CancellationTokenSource.init(allocator) catch return error.ProviderFailed;
    defer cancel_src.deinit();
    const local_token = cancel_src.getToken();
    const cancel_token: *const kernel.cancellation.CancellationToken = options.cancel_token orelse &local_token;

    var owned_plan_body: ?[]u8 = null;
    errdefer if (owned_plan_body) |body| allocator.free(body);
    var owned_plan_rel: ?[]u8 = null;
    errdefer if (owned_plan_rel) |path| allocator.free(path);

    if (options.mode == .plan) {
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

        workspace.history.ensureLayout(io, root) catch return error.ProviderFailed;
        root.dir.createDirPath(io, ".forge/plans") catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return error.ProviderFailed,
        };
        workspace.atomic.replaceFile(io, root, workspace.WorkspacePath.parse(plan_rel) catch return error.ProviderFailed, plan_body) catch return error.ProviderFailed;

        ctx_builder.addBlock(.intent, "implementation_plan", plan_body) catch return error.ProviderFailed;
        plan_inst = planner.Planner.init(allocator, llm, &ctx_builder, options.conversation, images);
    }

    var response = std.Io.Writer.Allocating.init(allocator);
    defer response.deinit();

    emitProgress(options, .sending);
    plan_inst.plan(&response.writer, cancel_token) catch |err| {
        if (cancel_token.isCancelled()) return error.Cancelled;
        return err;
    };
    emitProgress(options, .streaming);
    emitProgress(options, .parsing);

    const proposal_body = response.writer.buffer[0..response.writer.end];
    try validateProposalBody(allocator, proposal_body);

    const owned_body = allocator.dupe(u8, proposal_body) catch return error.ProviderFailed;
    errdefer allocator.free(owned_body);

    workspace.history.ensureLayout(io, root) catch return error.ProviderFailed;

    var proposal_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const proposal_rel = std.fmt.bufPrint(&proposal_path_buf, ".forge/proposals/{s}.json", .{run_id}) catch return error.ProviderFailed;
    workspace.atomic.replaceFile(io, root, workspace.WorkspacePath.parse(proposal_rel) catch return error.ProviderFailed, proposal_body) catch return error.ProviderFailed;

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
    workspace.runs.persistRun(io, root, run_id, json_body) catch return error.ProviderFailed;

    const index_line = run_record.formatIndexLine(allocator, record) catch return error.ProviderFailed;
    defer allocator.free(index_line);
    workspace.runs.appendIndex(allocator, io, root, index_line) catch return error.ProviderFailed;

    emitProgress(options, .proposal_ready);

    const owned_proposal_rel = allocator.dupe(u8, proposal_rel) catch return error.ProviderFailed;

    return .{
        .run_id = run_id,
        .proposal_rel = owned_proposal_rel,
        .proposal_body = owned_body,
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

test "cli and ide surfaces produce identical proposal bodies" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir);

    const rules = "# rules\nUse zig fmt.\n";
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("FORGE.md"), rules);
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("forge.toml"), "[ai]\napply_mode = \"review\"\n");

    const intent = "add notes";
    const files = [_][]const u8{"sample.txt"};
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("sample.txt"), "hello\n");

    const provider_options = provider_factory.Options{
        .kind = .fake,
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

test "project rules are included in context manifest" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir);

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

test "generateAndPersist rejects invalid proposal json" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir);

    const provider_options = provider_factory.Options{
        .kind = .fake,
        .fake_response = "not valid proposal json",
    };

    try std.testing.expectError(
        error.InvalidProposal,
        generateAndPersist(allocator, io, null, root, "test", &.{}, provider_options, .{}),
    );
}
