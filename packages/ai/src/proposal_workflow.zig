const std = @import("std");
const workspace = @import("forge-workspace");
const kernel = @import("forge-kernel");
const provider_factory = @import("provider_factory.zig");
const context_loader = @import("context_loader.zig");
const planner = @import("planner.zig");
const progress = @import("progress.zig");
const run_record = @import("run_record.zig");

pub const Mode = enum { ask, plan };

pub const WorkflowError = error{
    MissingProviderCredentials,
    ProviderFailed,
    Cancelled,
};

pub const GenerateOptions = struct {
    surface: run_record.Surface = .cli,
    mode: Mode = .ask,
    cancel_token: ?*const kernel.cancellation.CancellationToken = null,
    progress_callback: ?*const fn (?*anyopaque, progress.Phase) void = null,
    progress_context: ?*anyopaque = null,
    stream_callback: ?*const fn (?*anyopaque, []const u8) void = null,
    stream_context: ?*anyopaque = null,
    include_project_rules: bool = true,
};

pub const Result = struct {
    run_id: []const u8,
    proposal_rel: []const u8,
    proposal_body: []const u8,
};

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
        .stream_callback = options.stream_callback,
        .stream_context = options.stream_context,
    }) catch |err| switch (err) {
        provider_factory.FactoryError.MissingCredentials => return error.MissingProviderCredentials,
        else => return error.ProviderFailed,
    };
    defer provider_handle.deinit();

    var ctx_builder = context_loader.build(allocator, io, root, .{
        .intent = intent,
        .explicit_files = files,
        .include_project_rules = options.include_project_rules,
    }) catch return error.ProviderFailed;
    defer ctx_builder.deinit();
    emitProgress(options, .context_built);

    const provider = provider_handle.interface();
    const meta = provider.metadata();
    var plan = planner.Planner.init(allocator, provider, &ctx_builder);

    var response = std.Io.Writer.Allocating.init(allocator);
    defer response.deinit();

    var cancel_src = kernel.cancellation.CancellationTokenSource.init(allocator) catch return error.ProviderFailed;
    defer cancel_src.deinit();
    const local_token = cancel_src.getToken();
    const cancel_token: *const kernel.cancellation.CancellationToken = options.cancel_token orelse &local_token;

    emitProgress(options, .sending);
    plan.plan(&response.writer, cancel_token) catch {
        if (cancel_token.isCancelled()) return error.Cancelled;
        return error.ProviderFailed;
    };
    emitProgress(options, .streaming);
    emitProgress(options, .parsing);

    const proposal_body = response.writer.buffer[0..response.writer.end];
    const owned_body = allocator.dupe(u8, proposal_body) catch return error.ProviderFailed;
    errdefer allocator.free(owned_body);

    const timestamp_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    const run_id = run_record.makeRunId(allocator, timestamp_ms) catch return error.ProviderFailed;
    errdefer allocator.free(run_id);

    workspace.history.ensureLayout(io, root) catch return error.ProviderFailed;

    var proposal_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const proposal_rel = std.fmt.bufPrint(&proposal_path_buf, ".forge/proposals/{s}.json", .{run_id}) catch return error.ProviderFailed;
    workspace.atomic.replaceFile(io, root, workspace.WorkspacePath.parse(proposal_rel) catch return error.ProviderFailed, proposal_body) catch return error.ProviderFailed;

    const initial_state: run_record.State = switch (options.mode) {
        .ask => .proposed,
        .plan => .planning,
    };

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
    };
}

pub fn deinitResult(allocator: std.mem.Allocator, result: *Result) void {
    allocator.free(result.run_id);
    allocator.free(result.proposal_rel);
    allocator.free(result.proposal_body);
    result.* = undefined;
}

pub const default_ask_response =
    \\{"schema_version":1,"summary":"Create notes.txt from ask intent","assumptions":["No conflicting notes.txt exists"],"validation_tasks":["zig build test"],"workspace_edit":{"files":[{"path":"notes.txt","operation":"create","edits":[{"start":0,"end":0,"replacement":"generated by forge ask\n"}]}]}}
;

pub const default_plan_response =
    \\{"schema_version":1,"summary":"Create plan.txt from planner","assumptions":["Workspace is writable"],"validation_tasks":["zig build test"],"workspace_edit":{"files":[{"path":"plan.txt","operation":"create","edits":[{"start":0,"end":0,"replacement":"planned change\n"}]}]}}
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
