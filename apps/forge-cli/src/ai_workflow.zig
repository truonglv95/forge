const std = @import("std");
const ai = @import("forge-ai");
const workspace = @import("forge-workspace");
const kernel = @import("forge-kernel");
const workspace_cmd = @import("workspace_cmd.zig");
const args_mod = @import("args.zig");

pub const Mode = ai.proposal_workflow.Mode;
pub const Result = struct {
    run_id: []const u8,
    proposal_rel: []const u8,
};

pub const WorkflowError = ai.proposal_workflow.WorkflowError;

pub const GenerateOptions = struct {
    cancel_token: ?*const kernel.cancellation.CancellationToken = null,
    progress_writer: ?*std.Io.Writer = null,
    progress_json: bool = false,
};

pub fn providerOptionsFromFlags(
    allocator: std.mem.Allocator,
    mode: Mode,
    flags: args_mod.GlobalFlags,
    io: std.Io,
    root: ?workspace.WorkspaceRoot,
) ai.provider_factory.Options {
    const fake_response = switch (mode) {
        .ask => ai.proposal_workflow.default_ask_response,
        .plan => ai.proposal_workflow.default_plan_response,
    };
    const fake_plan = if (mode == .plan) ai.proposal_workflow.default_plan_markdown else null;

    var workspace_cfg: ?workspace_cmd.AiConfig = null;
    defer if (workspace_cfg) |*cfg| cfg.deinit();
    if (root) |opened| {
        workspace_cfg = workspace_cmd.AiConfig.load(allocator, io, opened) catch null;
    }

    const provider_name = flags.provider orelse if (workspace_cfg) |cfg| cfg.provider else null;
    const model_name: ?[]const u8 = if (flags.model) |model| model else if (workspace_cfg) |cfg| if (cfg.model) |model| blk: {
        break :blk allocator.dupe(u8, model) catch null;
    } else null else null;

    return .{
        .kind = ai.provider_factory.Kind.parse(provider_name),
        .model = model_name,
        .fake_response = fake_response,
        .fake_plan_response = fake_plan,
    };
}

pub fn agentProviderOptionsFromFlags(
    allocator: std.mem.Allocator,
    flags: args_mod.GlobalFlags,
    intent: []const u8,
    io: std.Io,
    root: ?workspace.WorkspaceRoot,
) ai.provider_factory.Options {
    var options = providerOptionsFromFlags(allocator, .ask, flags, io, root);
    options.fake_response = ai.proposal_workflow.fakeAgentResponseForIntent(intent);
    options.fake_tool_loop = true;
    const max_steps = if (flags.max_steps > 0) flags.max_steps else 8;
    options.fake_tool_loop_short = max_steps <= 2;
    return options;
}

fn progressBridge(context: ?*anyopaque, phase: ai.progress.Phase) void {
    const ctx: *ProgressBridge = @ptrCast(@alignCast(context.?));
    ai.progress.emitIf(ctx.writer, ctx.json, phase);
}

const ProgressBridge = struct {
    writer: ?*std.Io.Writer,
    json: bool,
};

pub fn generateAndPersist(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    opened: workspace_cmd.OpenedWorkspace,
    mode: Mode,
    intent: []const u8,
    files: []const []const u8,
    provider_options: ai.provider_factory.Options,
    generate_options: GenerateOptions,
) WorkflowError!Result {
    var bridge = ProgressBridge{
        .writer = generate_options.progress_writer,
        .json = generate_options.progress_json,
    };

    var inner = ai.proposal_workflow.generateAndPersist(
        allocator,
        io,
        environ_map,
        opened.root,
        intent,
        files,
        provider_options,
        .{
            .surface = .cli,
            .mode = mode,
            .cancel_token = generate_options.cancel_token,
            .progress_callback = progressBridge,
            .progress_context = &bridge,
            .workspace_cwd = opened.path,
            .enable_repair_loop = provider_options.kind != .fake,
            .max_repair_attempts = 2,
        },
    ) catch |err| switch (err) {
        error.MissingProviderCredentials => return error.MissingProviderCredentials,
        error.Cancelled => return error.Cancelled,
        else => |e| return e,
    };
    defer ai.proposal_workflow.deinitResult(allocator, &inner);

    const run_id = allocator.dupe(u8, inner.run_id) catch return error.ProviderFailed;
    errdefer allocator.free(run_id);
    const proposal_rel = allocator.dupe(u8, inner.proposal_rel) catch return error.ProviderFailed;
    errdefer allocator.free(proposal_rel);

    return .{ .run_id = run_id, .proposal_rel = proposal_rel };
}

pub fn writeError(writer: *std.Io.Writer, err: WorkflowError) !u8 {
    switch (err) {
        error.MissingProviderCredentials => {
            try writer.writeAll("error: provider requires credentials (gemini) or a running Ollama server (ollama)\n");
            return 2;
        },
        error.Cancelled => return 130,
        error.ProviderFailed => {
            try writer.writeAll("error: AI provider failed\n");
            return 2;
        },
        error.InvalidProposal => {
            try writer.writeAll("error: model returned an invalid proposal JSON\n");
            return 2;
        },
        error.AuthenticationFailed,
        error.RateLimitExceeded,
        error.ContextLengthExceeded,
        error.NetworkError,
        error.MalformedResponse,
        error.ProviderInternalError,
        => |e| {
            try writer.writeAll("error: ");
            try writer.writeAll(ai.provider.Provider.errorMessage(e));
            try writer.writeAll("\n");
            return 2;
        },
    }
}

pub const default_ask_response = ai.proposal_workflow.default_ask_response;
pub const default_plan_response = ai.proposal_workflow.default_plan_response;
