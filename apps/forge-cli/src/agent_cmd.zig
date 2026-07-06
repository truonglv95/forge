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
        try writer.writeAll("error: agent requires a subcommand (run|resume|list)\n");
        return 2;
    }

    const subcommand = parsed.positional[0];
    if (std.mem.eql(u8, subcommand, "list")) {
        return runList(allocator, io, parsed, writer);
    }
    if (std.mem.eql(u8, subcommand, "resume")) {
        return runResume(allocator, io, environ_map, parsed, writer);
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

    if (!parsed.flags.quiet and !parsed.flags.json) {
        if (is_resume) {
            try writer.print("Agent resume: {s}\n", .{target});
        } else {
            try writer.print("Agent run: {s}\n", .{target});
        }
    }

    const provider_opts = ai_workflow.agentProviderOptionsFromFlags(parsed.flags);
    const max_steps = if (parsed.flags.max_steps > 0) parsed.flags.max_steps else 8;
    const progress_writer: ?*std.Io.Writer = if (parsed.flags.quiet or parsed.flags.json) null else writer;
    var cancel_token = scope.token();

    const agent_config = ai.agent.Config{
        .max_steps = max_steps,
        .provider_options = provider_opts,
        .capability_profile = capabilityFromFlags(parsed.flags),
        .workspace_cwd = opened.path,
        .cancel_token = &cancel_token,
        .progress_writer = progress_writer,
        .progress_json = parsed.flags.json,
        .max_repair_attempts = if (provider_opts.kind == .fake) 0 else 2,
        .approve_every_time_tools = workspace_cmd.approved(parsed),
    };

    var result = (if (is_resume)
        ai.agent.resumeSession(allocator, io, environ_map, opened.root, target, agent_config)
    else
        ai.agent.run(allocator, io, environ_map, opened.root, target, agent_config)) catch |err| switch (err) {
        ai.agent.AgentError.StepLimitReached => {
            try writer.writeAll("error: agent reached step limit before completing\n");
            return 2;
        },
        ai.agent.AgentError.Cancelled => {
            try writer.writeAll("error: agent cancelled\n");
            return 130;
        },
        ai.agent.AgentError.ProviderFailed => {
            try writer.writeAll("error: agent provider failed\n");
            return 2;
        },
        ai.agent.AgentError.WorkspaceFailed => {
            try writer.writeAll("error: agent workspace operation failed\n");
            return 2;
        },
        ai.agent.AgentError.InvalidProposal => {
            try writer.writeAll("error: agent returned invalid proposal JSON\n");
            return 2;
        },
    };
    defer ai.agent.deinitResult(allocator, &result);

    var exit_code: u8 = 0;

    if (parsed.flags.json) {
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
    } else {
        try writer.print("Session: .forge/sessions/{s}.json\n", .{result.session_id});
        for (result.steps) |step| {
            try writer.print("  step {d} [{s}] {s}\n", .{ step.index, step.kind, step.summary });
        }
        if (result.proposal_rel) |prop| {
            try writer.print("Proposal: {s}\nReview: forge diff {s} --workspace <path>\n", .{ prop, prop });
        }
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
    const value = flags.capability orelse return ai.tools.profileForMode(.agent);
    if (std.mem.eql(u8, value, "read_only")) return .read_only;
    if (std.mem.eql(u8, value, "propose_and_task")) return .propose_and_task;
    return .propose;
}
