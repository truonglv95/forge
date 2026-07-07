const std = @import("std");
const ai = @import("forge-ai");
const workspace = @import("forge-workspace");
const args_mod = @import("args.zig");
const workspace_cmd = @import("workspace_cmd.zig");
const ai_workflow = @import("ai_workflow.zig");
const cancel_scope_mod = @import("cancel_scope.zig");

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    parsed: args_mod.CliArgs,
    writer: *std.Io.Writer,
) !u8 {
    if (parsed.positional.len == 0) {
        if (parsed.flags.json or parsed.flags.quiet or parsed.flags.non_interactive) {
            try writer.writeAll("error: agent requires a subcommand (run|resume|list) in non-interactive mode\n");
            return 2;
        }
        const agent_tui = @import("agent_tui.zig");
        return agent_tui.run(allocator, io, environ_map, parsed);
    }

    const subcommand = parsed.positional[0];
    if (std.mem.eql(u8, subcommand, "list")) {
        return runList(allocator, io, parsed, writer);
    }
    if (std.mem.eql(u8, subcommand, "resume")) {
        return runResume(allocator, io, environ_map, parsed, writer);
    }
    if (std.mem.eql(u8, subcommand, "events")) {
        return runEvents(allocator, io, parsed, writer);
    }
    if (!std.mem.eql(u8, subcommand, "run")) {
        try writer.print("error: unknown agent subcommand '{s}'\n", .{subcommand});
        return 2;
    }

    if (parsed.positional.len < 2) {
        try writer.writeAll("error: agent run requires an intent\n");
        return 2;
    }

    const intent = parsed.positional[1];
    return runAgent(allocator, io, environ_map, parsed, intent, false, writer);
}

fn runList(
    allocator: std.mem.Allocator,
    io: std.Io,
    parsed: args_mod.CliArgs,
    writer: *std.Io.Writer,
) !u8 {
    var opened = try workspace_cmd.OpenedWorkspace.open(allocator, io, parsed);
    defer opened.close(io);

    var list = try workspace.sessions.listEntries(allocator, io, opened.root);
    defer list.deinit();

    if (parsed.flags.json) {
        try writer.writeAll("{\"status\":\"ok\",\"type\":\"agent_list\",\"sessions\":[");
        for (list.items, 0..) |entry, index| {
            if (index > 0) try writer.writeAll(",");
            try writer.print(
                "{{\"session_id\":\"{s}\",\"intent\":\"{s}\",\"timestamp_ms\":{d}}}",
                .{ entry.session_id, entry.intent, entry.timestamp_ms },
            );
        }
        try writer.writeAll("]}\n");
    } else {
        try writer.writeAll("Agent sessions\n");
        for (list.items) |entry| {
            try writer.print("  {s}  {s}  ({d})\n", .{ entry.session_id, entry.intent, entry.timestamp_ms });
        }
        if (list.items.len == 0) try writer.writeAll("  (none)\n");
    }

    return 0;
}

fn runResume(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    parsed: args_mod.CliArgs,
    writer: *std.Io.Writer,
) !u8 {
    if (parsed.positional.len < 2) {
        try writer.writeAll("error: agent resume requires a session id\n");
        return 2;
    }

    const session_id = parsed.positional[1];
    return runAgent(allocator, io, environ_map, parsed, session_id, true, writer);
}

fn runEvents(
    allocator: std.mem.Allocator,
    io: std.Io,
    parsed: args_mod.CliArgs,
    writer: *std.Io.Writer,
) !u8 {
    if (parsed.positional.len < 2) {
        try writer.writeAll("error: agent events requires a session id\n");
        return 2;
    }

    var opened = try workspace_cmd.OpenedWorkspace.open(allocator, io, parsed);
    defer opened.close(io);

    const session_id = parsed.positional[1];
    const body = workspace.sessions.readEvents(allocator, io, opened.root, session_id) catch {
        try writer.print("error: no event log for session '{s}'\n", .{session_id});
        return 2;
    };
    defer allocator.free(body);

    if (parsed.flags.json) {
        try writer.writeAll(body);
        if (body.len > 0 and body[body.len - 1] != '\n') try writer.writeAll("\n");
        return 0;
    }

    try writer.print("Agent events for {s}\n", .{session_id});
    var lines = std.mem.splitScalar(u8, body, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        count += 1;
        try renderEventLine(allocator, trimmed, writer);
    }
    if (count == 0) try writer.writeAll("  (no events)\n");
    return 0;
}

fn renderEventLine(allocator: std.mem.Allocator, line: []const u8, writer: *std.Io.Writer) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
        try writer.print("  ? {s}\n", .{line});
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try writer.print("  ? {s}\n", .{line});
        return;
    }
    const obj = parsed.value.object;
    const type_str = if (obj.get("type")) |v| (if (v == .string) v.string else "?") else "?";

    if (std.mem.eql(u8, type_str, "session_started")) {
        try writer.print("  session_started  intent={s}\n", .{jsonStr(obj, "intent")});
    } else if (std.mem.eql(u8, type_str, "context_manifest_built")) {
        try writer.print("  context_manifest  used_bytes={d} blocks={d}\n", .{ jsonInt(obj, "used_bytes"), jsonInt(obj, "blocks") });
    } else if (std.mem.eql(u8, type_str, "run_started")) {
        try writer.print("  run_started\n", .{});
    } else if (std.mem.eql(u8, type_str, "tool_call")) {
        try writer.print("  [{d}] tool_call  {s}  ({s})\n", .{ jsonInt(obj, "step"), jsonStr(obj, "tool"), jsonStr(obj, "reason") });
    } else if (std.mem.eql(u8, type_str, "tool_result")) {
        try writer.print("  [{d}] tool_result  {s}  {s}\n", .{ jsonInt(obj, "step"), jsonStr(obj, "kind"), jsonStr(obj, "summary") });
    } else if (std.mem.eql(u8, type_str, "validation_started")) {
        try writer.print("  validation_started  attempt={d}\n", .{jsonInt(obj, "attempt")});
    } else if (std.mem.eql(u8, type_str, "validation_result")) {
        const passed = if (obj.get("passed")) |v| (v == .bool and v.bool) else false;
        try writer.print("  validation_result  attempt={d} passed={}\n", .{ jsonInt(obj, "attempt"), passed });
    } else if (std.mem.eql(u8, type_str, "proposal_created")) {
        try writer.print("  proposal_created  {s}\n", .{jsonStr(obj, "proposal_path")});
    } else if (std.mem.eql(u8, type_str, "final_answer")) {
        try writer.print("  final_answer\n", .{});
    } else if (std.mem.eql(u8, type_str, "run_completed")) {
        try writer.print("  run_completed  steps={d} repairs={d}\n", .{ jsonInt(obj, "steps"), jsonInt(obj, "repair_attempts") });
    } else if (std.mem.eql(u8, type_str, "error")) {
        try writer.print("  error  {s}\n", .{jsonStr(obj, "code")});
    } else {
        try writer.print("  {s}\n", .{type_str});
    }
}

fn jsonStr(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    if (obj.get(key)) |v| {
        if (v == .string) return v.string;
    }
    return "";
}

fn jsonInt(obj: std.json.ObjectMap, key: []const u8) i64 {
    if (obj.get(key)) |v| {
        return switch (v) {
            .integer => v.integer,
            .float => @intFromFloat(v.float),
            else => 0,
        };
    }
    return 0;
}

fn runAgent(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    parsed: args_mod.CliArgs,
    target: []const u8,
    is_resume: bool,
    writer: *std.Io.Writer,
) !u8 {
    var opened = try workspace_cmd.OpenedWorkspace.open(allocator, io, parsed);
    defer opened.close(io);

    var scope = try cancel_scope_mod.Scope.init(allocator);
    defer scope.deinit();
    if (!parsed.flags.quiet and !parsed.flags.json) scope.installSigint();

    const provider_opts = ai_workflow.agentProviderOptionsFromFlags(parsed.flags, target);
    const max_steps = if (parsed.flags.max_steps > 0) parsed.flags.max_steps else 8;
    const progress_writer: ?*std.Io.Writer = null;
    var cancel_token = scope.token();
    const event_stream = eventStreamMode(parsed.flags) catch {
        try writer.writeAll("error: unsupported --events format; expected ndjson\n");
        return 2;
    };
    if (event_stream and parsed.flags.json) {
        try writer.writeAll("error: --events ndjson cannot be combined with --json\n");
        return 2;
    }
    if (event_stream and workspace_cmd.approved(parsed)) {
        try writer.writeAll("error: --events ndjson cannot be combined with --yes yet; apply events are not implemented\n");
        return 2;
    }
    const mode = modeFromFlags(parsed.flags);
    const capability = capabilityFromFlags(parsed.flags);
    var event_writer = AgentEventWriter{
        .allocator = allocator,
        .writer = writer,
    };
    if (event_stream) {
        try event_writer.sessionStarted(if (is_resume) "agent_resume" else "agent_run");
        try event_writer.runStarted(if (is_resume) "agent_resume" else "agent_run", providerName(provider_opts.kind), provider_opts.model, mode, capability, max_steps);
    }

    const agent_config = ai.agent.Config{
        .max_steps = max_steps,
        .provider_options = provider_opts,
        .mode = mode,
        .capability_profile = capability,
        .workspace_cwd = opened.path,
        .cancel_token = &cancel_token,
        .progress_writer = progress_writer,
        .progress_json = parsed.flags.json,
        .max_repair_attempts = if (provider_opts.kind == .fake) 0 else 2,
        .approve_every_time_tools = workspace_cmd.approved(parsed),
        .turn_callback = if (event_stream) AgentEventWriter.onTurn else null,
        .turn_context = &event_writer,
        .step_begin_callback = if (event_stream) AgentEventWriter.onStepBegin else null,
        .step_begin_context = &event_writer,
        .step_callback = if (event_stream) AgentEventWriter.onStep else null,
        .step_context = &event_writer,
    };

    if (event_stream and !is_resume) {
        // Mirror `forge context` at run start, but as an event. Resume runs
        // can reconstruct context from the saved session state later.
        const route = ai.routing.plan(.{
            .mode = mode,
            .intent = target,
            .has_active_file = parsed.flags.files.len > 0,
        }, .{
            .intent = target,
            .explicit_files = parsed.flags.files,
            .max_bytes = if (parsed.flags.budget_bytes > 0) parsed.flags.budget_bytes else 1024 * 1024,
            .workspace_cwd = opened.path,
        });
        context_event: {
            var ctx_builder = ai.context_loader.build(allocator, io, opened.root, route.context) catch break :context_event;
            defer ctx_builder.deinit();
            var out = std.Io.Writer.Allocating.init(allocator);
            defer out.deinit();
            ai.context_loader.renderManifestJson(&ctx_builder, &out.writer) catch break :context_event;
            try event_writer.contextManifestBuilt(out.writer.buffered());
        }
    }

    var result = (if (is_resume)
        ai.agent.resumeSession(allocator, io, environ_map, opened.root, target, agent_config)
    else
        ai.agent.run(allocator, io, environ_map, opened.root, target, agent_config)) catch |err| switch (err) {
        ai.agent.AgentError.StepLimitReached => {
            if (event_stream) try event_writer.agentError(.step_limit_reached, "agent reached step limit before completing", true) else try writer.writeAll("error: agent reached step limit before completing\n");
            return 2;
        },
        ai.agent.AgentError.Cancelled => {
            if (event_stream) try event_writer.agentError(.cancelled, "agent cancelled", false) else try writer.writeAll("error: agent cancelled\n");
            return 130;
        },
        ai.agent.AgentError.ProviderFailed => {
            if (event_stream) try event_writer.agentError(.provider_failed, "agent provider failed", true) else try writer.writeAll("error: agent provider failed\n");
            return 2;
        },
        ai.agent.AgentError.RateLimitExceeded => {
            if (event_stream) try event_writer.agentError(.rate_limit_exceeded, "agent provider rate limit exceeded; retry later or switch provider/model", true) else try writer.writeAll("error: agent provider rate limit exceeded; retry later or switch provider/model\n");
            return 2;
        },
        ai.agent.AgentError.AuthenticationFailed => {
            if (event_stream) try event_writer.agentError(.authentication_failed, "agent provider authentication failed; check provider API key", false) else try writer.writeAll("error: agent provider authentication failed; check provider API key\n");
            return 2;
        },
        ai.agent.AgentError.ContextLengthExceeded => {
            if (event_stream) try event_writer.agentError(.context_length_exceeded, "agent provider rejected the context; reduce --budget-bytes or attached files", true) else try writer.writeAll("error: agent provider rejected the context; reduce --budget-bytes or attached files\n");
            return 2;
        },
        ai.agent.AgentError.NetworkError => {
            if (event_stream) try event_writer.agentError(.network_error, "agent provider network request failed", true) else try writer.writeAll("error: agent provider network request failed\n");
            return 2;
        },
        ai.agent.AgentError.WorkspaceFailed => {
            if (event_stream) try event_writer.agentError(.workspace_failed, "agent workspace operation failed", false) else try writer.writeAll("error: agent workspace operation failed\n");
            return 2;
        },
        ai.agent.AgentError.InvalidProposal => {
            if (event_stream) try event_writer.agentError(.invalid_proposal, "agent returned invalid proposal JSON", false) else try writer.writeAll("error: agent returned invalid proposal JSON\n");
            return 2;
        },
        ai.agent.AgentError.DuplicateLoop => {
            if (event_stream) try event_writer.agentError(.duplicate_loop, "agent detected a duplicate tool loop; refine intent or provide file paths", false) else try writer.writeAll("error: agent detected a duplicate tool loop; refine intent or provide file paths\n");
            return 2;
        },
        ai.agent.AgentError.NoProgress => {
            if (event_stream) try event_writer.agentError(.no_progress, "agent made no progress after multiple broad tool calls; provide a specific file or symbol", false) else try writer.writeAll("error: agent made no progress after multiple broad tool calls; provide a specific file or symbol\n");
            return 2;
        },
    };
    defer ai.agent.deinitResult(allocator, &result);

    var exit_code: u8 = 0;

    if (event_stream) {
        if (result.response_text) |text| {
            try event_writer.finalAnswer(text);
        }
        if (result.proposal_rel != null) {
            try event_writer.proposalCreated(result.proposal_rel orelse "");
        }
        try event_writer.runCompleted(if (is_resume) "agent_resume" else "agent_run", result);
    } else if (parsed.flags.json) {
        const event_type = if (is_resume) "agent_resume" else "agent_run";
        try writer.print(
            "{{\"status\":\"ok\",\"type\":\"{s}\",\"session_id\":\"{s}\",\"run_id\":\"{s}\",\"proposal_path\":\"{s}\",\"steps\":{d},\"repair_attempts\":{d},\"reported_tokens\":{{\"prompt\":{d},\"completion\":{d},\"total\":{d}}}",
            .{
                event_type,
                result.session_id,
                result.final_run_id orelse "",
                result.proposal_rel orelse "",
                result.steps.len,
                result.repair_attempts,
                result.usage.prompt_tokens,
                result.usage.completion_tokens,
                result.usage.total_tokens,
            },
        );
        if (result.response_text) |text| {
            const escaped = try std.json.Stringify.valueAlloc(allocator, text, .{});
            defer allocator.free(escaped);
            try writer.print(",\"response_text\":{s}", .{escaped});
        }
    } else {
        try renderHumanTranscript(writer, result, !parsed.flags.no_color);
    }

    if (result.proposal_rel) |prop| {
        if (workspace_cmd.approved(parsed)) {
            exit_code = try workspace_cmd.applyProposal(allocator, io, opened, prop, writer, parsed.flags.json);
            if (parsed.flags.json and exit_code == 0) {
                try writer.writeAll(",\"applied\":true");
            }
        } else if (parsed.flags.json) {
            try writer.writeAll(",\"applied\":false");
        }
    } else if (parsed.flags.json) {
        try writer.writeAll(",\"applied\":false");
    }

    if (parsed.flags.json) {
        try writer.writeAll("}\n");
    }

    return exit_code;
}

fn capabilityFromFlags(flags: args_mod.GlobalFlags) ai.tools.CapabilityProfile {
    const value = flags.capability orelse return ai.tools.profileForMode(modeFromFlags(flags));
    if (std.mem.eql(u8, value, "read_only")) return .read_only;
    if (std.mem.eql(u8, value, "propose_and_task")) return .propose_and_task;
    return .propose;
}

fn modeFromFlags(flags: args_mod.GlobalFlags) ai.tools.Mode {
    if (flags.mode) |mode| {
        if (std.mem.eql(u8, mode, "ask")) return .ask;
        if (std.mem.eql(u8, mode, "plan")) return .plan;
    }
    return .agent;
}

fn renderHumanTranscript(writer: *std.Io.Writer, result: ai.agent.Result, use_color: bool) !void {
    try writeStyled(writer, use_color, Style.dim, "Session: ");
    try writer.print(".forge/sessions/{s}.json\n\n", .{result.session_id});

    if (result.steps.len > 0) {
        for (result.steps) |step| {
            try writeStyled(writer, use_color, Style.magenta, "↻ call llm");
            try writer.print("  next tool step {d}\n", .{step.index});

            try writeStyled(writer, use_color, Style.yellow, "$ ");
            try writeStyled(writer, use_color, Style.bright_yellow, step.kind);
            try writer.print("  step {d}\n", .{step.index});

            var buf: [512]u8 = undefined;
            const preview = summarizeStep(&buf, step.summary);
            try writeStyled(writer, use_color, Style.green, "ok ");
            try writeStyled(writer, use_color, Style.bright_green, step.kind);
            try writer.print(" · {s}\n\n", .{preview});
        }
    }

    if (result.response_text) |text| {
        try writeStyled(writer, use_color, Style.bold_yellow, "Answer: ");
        try writer.print("{s}\n", .{text});
    }

    if (result.proposal_rel) |prop| {
        try writer.writeAll("\n");
        try writeStyled(writer, use_color, Style.bold_yellow, "Proposal: ");
        try writer.print("{s}\n", .{prop});
        try writeStyled(writer, use_color, Style.dim, "Review: ");
        try writer.print("forge diff {s} --workspace <path>\n", .{prop});
    }
}

const Style = struct {
    const reset = "\x1b[0m";
    const dim = "\x1b[2m";
    const yellow = "\x1b[33m";
    const bright_yellow = "\x1b[93m";
    const bold_yellow = "\x1b[1;93m";
    const green = "\x1b[32m";
    const bright_green = "\x1b[92m";
    const magenta = "\x1b[35m";
};

fn writeStyled(writer: *std.Io.Writer, use_color: bool, style: []const u8, text: []const u8) !void {
    if (use_color) try writer.writeAll(style);
    try writer.writeAll(text);
    if (use_color) try writer.writeAll(Style.reset);
}

fn summarizeStep(buf: []u8, summary: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, summary, '\n');
    var count: usize = 0;
    var first: []const u8 = "";
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        if (count == 0) first = trimmed;
        count += 1;
    }
    const clipped = if (first.len > 220) first[0..220] else first;
    if (count > 4) {
        return std.fmt.bufPrint(buf, "{s} · {d} output lines hidden", .{ clipped, count }) catch clipped;
    }
    return clipped;
}

fn eventStreamMode(flags: args_mod.GlobalFlags) !bool {
    const value = flags.events orelse return false;
    if (std.mem.eql(u8, value, "ndjson")) return true;
    return error.UnsupportedEventStream;
}

fn providerName(kind: ai.provider_factory.Kind) []const u8 {
    return switch (kind) {
        .auto => "auto",
        .fake => "fake",
        .gemini => "gemini",
        .ollama => "ollama",
    };
}

const AgentEventWriter = struct {
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,

    fn onTurn(ctx: ?*anyopaque, next_step: u32) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.llmTurn(next_step) catch {};
    }

    fn onStepBegin(ctx: ?*anyopaque, step: ai.agent.StepBegin) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.toolCall(step.index, step.tool_name, step.args_json) catch {};
    }

    fn onStep(ctx: ?*anyopaque, step: ai.agent.Step) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.toolResult(step) catch {};
    }

    fn sessionStarted(self: *@This(), event_type: []const u8) !void {
        const event_json = try jsonString(self.allocator, event_type);
        defer self.allocator.free(event_json);
        try self.writer.print(
            "{{\"schema_version\":{d},\"type\":\"{s}\",\"run_type\":{s}}}\n",
            .{ ai.agent_event.schema_version, ai.agent_event.typeName(.session_started), event_json },
        );
    }

    fn contextManifestBuilt(self: *@This(), manifest_json: []const u8) !void {
        // `manifest_json` is already JSON text; wrap as a string to keep stable contract.
        const body_json = try jsonString(self.allocator, manifest_json);
        defer self.allocator.free(body_json);
        try self.writer.print(
            "{{\"schema_version\":{d},\"type\":\"{s}\",\"manifest_json\":{s}}}\n",
            .{ ai.agent_event.schema_version, ai.agent_event.typeName(.context_manifest_built), body_json },
        );
    }

    fn runStarted(
        self: *@This(),
        event_type: []const u8,
        provider: []const u8,
        model: ?[]const u8,
        mode: ai.tools.Mode,
        capability: ai.tools.CapabilityProfile,
        max_steps: u32,
    ) !void {
        const model_json = try jsonString(self.allocator, model orelse "");
        defer self.allocator.free(model_json);
        try self.writer.print(
            "{{\"schema_version\":{d},\"type\":\"{s}\",\"run_type\":\"{s}\",\"provider\":\"{s}\",\"model\":{s},\"mode\":\"{s}\",\"capability\":\"{s}\",\"max_steps\":{d}}}\n",
            .{ ai.agent_event.schema_version, ai.agent_event.typeName(.run_started), event_type, provider, model_json, @tagName(mode), @tagName(capability), max_steps },
        );
    }

    fn llmTurn(self: *@This(), next_step: u32) !void {
        try self.writer.print(
            "{{\"schema_version\":{d},\"type\":\"{s}\",\"next_step\":{d}}}\n",
            .{ ai.agent_event.schema_version, ai.agent_event.typeName(.llm_turn), next_step },
        );
    }

    fn toolCall(self: *@This(), step: u32, tool: []const u8, args_json: []const u8) !void {
        const tool_json = try jsonString(self.allocator, tool);
        defer self.allocator.free(tool_json);
        const args_json_string = try jsonString(self.allocator, args_json);
        defer self.allocator.free(args_json_string);
        const reason_json = try jsonString(self.allocator, toolReason(tool));
        defer self.allocator.free(reason_json);
        const args_preview_json = try jsonString(self.allocator, argsPreview(args_json));
        defer self.allocator.free(args_preview_json);
        try self.writer.print(
            "{{\"schema_version\":{d},\"type\":\"{s}\",\"step\":{d},\"tool\":{s},\"reason\":{s},\"args_preview\":{s},\"args_json\":{s}}}\n",
            .{ ai.agent_event.schema_version, ai.agent_event.typeName(.tool_call), step, tool_json, reason_json, args_preview_json, args_json_string },
        );
    }

    fn toolResult(self: *@This(), step: ai.agent.Step) !void {
        const kind_json = try jsonString(self.allocator, step.kind);
        defer self.allocator.free(kind_json);
        const summary_json = try jsonString(self.allocator, step.summary);
        defer self.allocator.free(summary_json);
        const run_id_json = try jsonString(self.allocator, step.run_id orelse "");
        defer self.allocator.free(run_id_json);
        try self.writer.print(
            "{{\"schema_version\":{d},\"type\":\"{s}\",\"step\":{d},\"kind\":{s},\"summary\":{s},\"run_id\":{s}}}\n",
            .{ ai.agent_event.schema_version, ai.agent_event.typeName(.tool_result), step.index, kind_json, summary_json, run_id_json },
        );
    }

    fn runCompleted(self: *@This(), event_type: []const u8, result: ai.agent.Result) !void {
        const session_json = try jsonString(self.allocator, result.session_id);
        defer self.allocator.free(session_json);
        const run_id_json = try jsonString(self.allocator, result.final_run_id orelse "");
        defer self.allocator.free(run_id_json);
        const proposal_json = try jsonString(self.allocator, result.proposal_rel orelse "");
        defer self.allocator.free(proposal_json);
        const response_json = try jsonString(self.allocator, result.response_text orelse "");
        defer self.allocator.free(response_json);
        try self.writer.print(
            "{{\"schema_version\":{d},\"type\":\"{s}\",\"run_type\":\"{s}\",\"session_id\":{s},\"run_id\":{s},\"proposal_path\":{s},\"steps\":{d},\"repair_attempts\":{d},\"reported_tokens\":{{\"prompt\":{d},\"completion\":{d},\"total\":{d}}},\"response_text\":{s}}}\n",
            .{
                ai.agent_event.schema_version,
                ai.agent_event.typeName(.run_completed),
                event_type,
                session_json,
                run_id_json,
                proposal_json,
                result.steps.len,
                result.repair_attempts,
                result.usage.prompt_tokens,
                result.usage.completion_tokens,
                result.usage.total_tokens,
                response_json,
            },
        );
    }

    fn agentError(self: *@This(), code: ai.agent_event.ErrorCode, message: []const u8, retryable: bool) !void {
        const code_json = try jsonString(self.allocator, ai.agent_event.errorCodeName(code));
        defer self.allocator.free(code_json);
        const message_json = try jsonString(self.allocator, message);
        defer self.allocator.free(message_json);
        try self.writer.print(
            "{{\"schema_version\":{d},\"type\":\"{s}\",\"error\":{{\"code\":{s},\"message\":{s},\"retryable\":{}}}}}\n",
            .{ ai.agent_event.schema_version, ai.agent_event.typeName(.@"error"), code_json, message_json, retryable },
        );
    }

    fn proposalCreated(self: *@This(), proposal_path: []const u8) !void {
        const proposal_json = try jsonString(self.allocator, proposal_path);
        defer self.allocator.free(proposal_json);
        try self.writer.print(
            "{{\"schema_version\":{d},\"type\":\"{s}\",\"proposal_path\":{s}}}\n",
            .{ ai.agent_event.schema_version, ai.agent_event.typeName(.proposal_created), proposal_json },
        );
    }

    fn finalAnswer(self: *@This(), text: []const u8) !void {
        const text_json = try jsonString(self.allocator, text);
        defer self.allocator.free(text_json);
        try self.writer.print(
            "{{\"schema_version\":{d},\"type\":\"{s}\",\"text\":{s}}}\n",
            .{ ai.agent_event.schema_version, ai.agent_event.typeName(.final_answer), text_json },
        );
    }
};

fn jsonString(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

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

test "agent events renders a timeline from the session log" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir);

    try workspace.sessions.appendEvent(allocator, io, root, "sess_demo", "{\"schema_version\":1,\"type\":\"session_started\",\"intent\":\"do work\"}");
    try workspace.sessions.appendEvent(allocator, io, root, "sess_demo", "{\"schema_version\":1,\"type\":\"tool_call\",\"step\":1,\"tool\":\"read_file\",\"reason\":\"gather\"}");
    try workspace.sessions.appendEvent(allocator, io, root, "sess_demo", "{\"schema_version\":1,\"type\":\"run_completed\",\"steps\":1,\"repair_attempts\":0}");

    var ws_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ws = try std.fmt.bufPrint(&ws_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    const parsed = args_mod.CliArgs{
        .flags = .{ .workspace = ws },
        .command = .agent,
        .positional = &.{ "events", "sess_demo" },
    };
    const code = try runEvents(allocator, io, parsed, &out);
    try std.testing.expectEqual(@as(u8, 0), code);
    const rendered = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "session_started") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "tool_call") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "run_completed") != null);
}
