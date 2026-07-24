const std = @import("std");
const workspace = @import("forge-workspace");
const ai = @import("forge-ai");
const args_mod = @import("args.zig");
const ai_workflow = @import("ai_workflow.zig");
const cancel_scope_mod = @import("cancel_scope.zig");
const kernel = @import("forge-kernel");

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    parsed: args_mod.CliArgs,
    writer: *std.Io.Writer,
) !u8 {
    const positionals = parsed.positional;
    if (positionals.len == 0) {
        try printUsage(writer);
        return 2;
    }

    const sub = positionals[0];
    const workspace_path = parsed.flags.workspace orelse ".";

    var root = workspace.WorkspaceRoot.open(io, workspace_path) catch {
        try writer.print("error: cannot open workspace '{s}'\n", .{workspace_path});
        return 1;
    };
    defer root.close(io);

    if (std.mem.eql(u8, sub, "create")) {
        return try createSpec(allocator, io, root, positionals, parsed.flags, writer);
    }
    if (std.mem.eql(u8, sub, "list")) {
        return try listSpecs(allocator, io, root, parsed.flags, writer);
    }
    if (std.mem.eql(u8, sub, "show")) {
        return try showSpec(allocator, io, root, positionals, parsed.flags, writer);
    }
    if (std.mem.eql(u8, sub, "edit")) {
        return try editSpec(allocator, io, root, positionals, parsed.flags, writer);
    }
    if (std.mem.eql(u8, sub, "approve")) {
        return try setSpecStatus(allocator, io, root, positionals, .approved, writer);
    }
    if (std.mem.eql(u8, sub, "reject")) {
        return try setSpecStatus(allocator, io, root, positionals, .rejected, writer);
    }
    if (std.mem.eql(u8, sub, "implement")) {
        return try implementSpec(allocator, io, environ_map, root, positionals, parsed.flags, writer);
    }
    if (std.mem.eql(u8, sub, "trace")) {
        return try traceSpec(allocator, io, root, positionals, writer);
    }
    // Phase 3 additions (RFC-0014)
    if (std.mem.eql(u8, sub, "init")) {
        return try initSpecs(allocator, io, root, parsed.flags, writer);
    }
    if (std.mem.eql(u8, sub, "template")) {
        return try showTemplate(allocator, positionals, writer);
    }
    if (std.mem.eql(u8, sub, "validate")) {
        return try validateSpecs(allocator, io, root, positionals, writer);
    }

    try writer.print("error: unknown spec subcommand '{s}'\n", .{sub});
    try printUsage(writer);
    return 2;
}

fn createSpec(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot, positionals: []const []const u8, flags: args_mod.GlobalFlags, writer: *std.Io.Writer) !u8 {
    if (positionals.len < 2) {
        try writer.print("usage: forge spec create <name> [--intent \"text\"]\n", .{});
        return 2;
    }
    const name = positionals[1];
    const intent = flags.intent orelse name;

    ai.spec_writer.createSpec(allocator, io, root, name, intent, null, null, null) catch {
        try writer.print("error: failed to create spec '{s}'\n", .{name});
        return 1;
    };

    if (flags.json) {
        try writer.print("{{\"spec_id\":\"{s}\",\"status\":\"pending\"}}\n", .{name});
    } else {
        try writer.print("Created spec '{s}' (status: pending)\n", .{name});
        try writer.print("  requirements.md  (placeholder - edit me)\n", .{});
        try writer.print("  design.md        (placeholder - edit me)\n", .{});
        try writer.print("  tasks.md         (placeholder - edit me)\n", .{});
        try writer.print("\nNext: `forge spec edit {s} --section requirements --body \"...\"`\n", .{name});
    }
    return 0;
}

fn listSpecs(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot, flags: args_mod.GlobalFlags, writer: *std.Io.Writer) !u8 {
    const specs = ai.spec_writer.listSpecs(allocator, io, root) catch {
        try writer.print("error: failed to list specs\n", .{});
        return 1;
    };
    defer ai.spec_writer.freeSpecList(allocator, specs);

    if (specs.len == 0) {
        if (flags.json) {
            try writer.print("[]\n", .{});
        } else {
            try writer.print("No specs found. Create one with `forge spec create <name>`.\n", .{});
        }
        return 0;
    }

    if (flags.json) {
        try writer.print("[", .{});
        for (specs, 0..) |spec, i| {
            if (i > 0) try writer.print(",", .{});
            try writer.print("{{\"id\":\"{s}\",\"status\":\"{s}\"}}", .{ spec.run_id, spec.status.label() });
        }
        try writer.print("]\n", .{});
    } else {
        try writer.print("{s:<20} {s:<12} {s}\n", .{ "SPEC", "STATUS", "FILES" });
        for (specs) |spec| {
            var files_buf: [128]u8 = undefined;
            const files = std.fmt.bufPrint(&files_buf, "{s}{s}{s}{s}", .{
                if (spec.has_requirements) "req " else "    ",
                if (spec.has_design) "des " else "    ",
                if (spec.has_tasks) "tsk " else "    ",
                if (spec.has_plan) "pln" else "   ",
            }) catch "?";
            try writer.print("{s:<20} {s:<12} {s}\n", .{ spec.run_id, spec.status.label(), files });
        }
    }
    return 0;
}

fn showSpec(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot, positionals: []const []const u8, flags: args_mod.GlobalFlags, writer: *std.Io.Writer) !u8 {
    if (positionals.len < 2) {
        try writer.print("usage: forge spec show <name> [--section req|design|tasks|plan]\n", .{});
        return 2;
    }
    const name = positionals[1];
    const section = flags.section orelse if (positionals.len >= 3) positionals[2] else "requirements";

    const body = ai.spec_writer.readSection(allocator, io, root, name, section) catch {
        try writer.print("error: spec '{s}' or section '{s}' not found\n", .{ name, section });
        return 1;
    };
    defer allocator.free(body);

    if (flags.json) {
        try writer.print("{{\"spec_id\":\"{s}\",\"section\":\"{s}\",\"body_len\":{d}}}\n", .{ name, section, body.len });
    } else {
        try writer.print("{s}\n", .{body});
    }
    return 0;
}

fn editSpec(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot, positionals: []const []const u8, flags: args_mod.GlobalFlags, writer: *std.Io.Writer) !u8 {
    if (positionals.len < 2) {
        try writer.print("usage: forge spec edit <name> --section <req|design|tasks> --body \"text\"\n", .{});
        return 2;
    }
    const name = positionals[1];
    const section = flags.section orelse "requirements";
    const body = flags.body orelse {
        try writer.print("error: --body is required to specify new content\n", .{});
        return 2;
    };

    ai.spec_writer.editSection(allocator, io, root, name, section, body) catch {
        try writer.print("error: failed to edit spec '{s}' section '{s}'\n", .{ name, section });
        return 1;
    };

    try writer.print("Updated spec '{s}' section '{s}' ({d} bytes)\n", .{ name, section, body.len });
    return 0;
}

fn setSpecStatus(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot, positionals: []const []const u8, status: ai.spec_writer.SpecStatus, writer: *std.Io.Writer) !u8 {
    if (positionals.len < 2) {
        try writer.print("usage: forge spec {s} <name>\n", .{status.label()});
        return 2;
    }
    const name = positionals[1];
    switch (status) {
        .approved => ai.spec_writer.approve(allocator, io, root, name) catch {
            try writer.print("error: failed to approve spec '{s}'\n", .{name});
            return 1;
        },
        .rejected => ai.spec_writer.reject(allocator, io, root, name) catch {
            try writer.print("error: failed to reject spec '{s}'\n", .{name});
            return 1;
        },
        else => {},
    }
    try writer.print("Spec '{s}' {s}.\n", .{ name, status.label() });
    return 0;
}

fn implementSpec(allocator: std.mem.Allocator, io: std.Io, environ_map: ?*const std.process.Environ.Map, root: workspace.WorkspaceRoot, positionals: []const []const u8, flags: args_mod.GlobalFlags, writer: *std.Io.Writer) !u8 {
    if (positionals.len < 2) {
        try writer.print("usage: forge spec implement <name> [--provider ...] [--max-steps N]\n", .{});
        return 2;
    }
    const spec_id = positionals[1];

    const status = ai.spec_writer.readStatus(allocator, io, root, spec_id);
    if (status == null) {
        try writer.print("error: spec '{s}' not found. Create it with `forge spec create {s}`\n", .{ spec_id, spec_id });
        return 1;
    }
    if (status.? != .approved and !flags.yes) {
        try writer.print("error: spec '{s}' is not approved (status: {s}). Run `forge spec approve {s}` first, or use --yes to override.\n", .{ spec_id, status.?.label(), spec_id });
        return 1;
    }

    const requirements = ai.spec_writer.readSection(allocator, io, root, spec_id, "requirements") catch {
        try writer.print("error: cannot read requirements.md for spec '{s}'\n", .{spec_id});
        return 1;
    };
    defer allocator.free(requirements);
    const design = ai.spec_writer.readSection(allocator, io, root, spec_id, "design") catch {
        try writer.print("error: cannot read design.md for spec '{s}'\n", .{spec_id});
        return 1;
    };
    defer allocator.free(design);
    const tasks = ai.spec_writer.readSection(allocator, io, root, spec_id, "tasks") catch {
        try writer.print("error: cannot read tasks.md for spec '{s}'\n", .{spec_id});
        return 1;
    };
    defer allocator.free(tasks);

    var intent_buf: std.ArrayList(u8) = .empty;
    defer intent_buf.deinit(allocator);
    intent_buf.appendSlice(allocator, "Implement the following spec.\n\n") catch return error.OutOfMemory;
    intent_buf.appendSlice(allocator, "## Requirements\n") catch return error.OutOfMemory;
    intent_buf.appendSlice(allocator, requirements) catch return error.OutOfMemory;
    intent_buf.appendSlice(allocator, "\n\n## Design\n") catch return error.OutOfMemory;
    intent_buf.appendSlice(allocator, design) catch return error.OutOfMemory;
    intent_buf.appendSlice(allocator, "\n\n## Tasks\n") catch return error.OutOfMemory;
    intent_buf.appendSlice(allocator, tasks) catch return error.OutOfMemory;
    intent_buf.appendSlice(allocator, "\n\nImplement all tasks. Use multi_edit for cross-file changes. Run validation after each significant change.") catch return error.OutOfMemory;

    if (!flags.quiet) {
        try writer.print("Implementing spec '{s}' (status: {s})...\n", .{ spec_id, status.?.label() });
        try writer.print("  Requirements: {d} bytes\n", .{requirements.len});
        try writer.print("  Design:       {d} bytes\n", .{design.len});
        try writer.print("  Tasks:        {d} bytes\n", .{tasks.len});
        try writer.print("  Intent total: {d} bytes\n\n", .{intent_buf.items.len});
    }

    var scope = cancel_scope_mod.Scope.init(allocator) catch return error.OutOfMemory;
    defer scope.deinit();
    if (!flags.quiet and !flags.json) scope.installSigint();
    var cancel_token = scope.token();

    var provider_opts = ai_workflow.agentProviderOptionsFromFlags(allocator, flags, intent_buf.items, io, root);
    defer provider_opts.deinit(allocator);

    const max_steps: u32 = if (flags.max_steps > 0) flags.max_steps else 16;

    var embedding = ai_workflow.embeddingOptionsFromFlags(allocator, flags, io, root);
    defer embedding.deinit(allocator);

    const agent_config = ai.agent.Config{
        .max_steps = max_steps,
        .context_max_bytes = if (flags.budget_bytes > 0) flags.budget_bytes else 8 * 1024 * 1024,
        .embedding = embedding.options,
        .provider_options = provider_opts.options,
        .mode = ai.tools.Mode.agent,
        .capability_profile = ai.tools.CapabilityProfile.propose_and_task,
        .auto_capability = false,
        .workspace_cwd = flags.workspace orelse ".",
        .cancel_token = &cancel_token,
        .progress_writer = if (flags.quiet) null else writer,
        .progress_json = flags.json,
        .max_repair_attempts = if (std.mem.eql(u8, provider_opts.options.provider_name, "fake")) 0 else 2,
        .approve_every_time_tools = flags.yes,
    };

    if (!flags.quiet) {
        try writer.print("Starting agent (provider={s}, model={s}, max_steps={d})...\n\n", .{
            provider_opts.options.provider_name,
            provider_opts.options.model orelse "(default)",
            max_steps,
        });
    }

    const result = ai.agent.run(allocator, io, environ_map, root, intent_buf.items, agent_config) catch |err| {
        try writer.print("\nerror: agent failed: {}\n", .{err});
        return 1;
    };
    defer {
        for (result.steps) |s| {
            allocator.free(s.kind);
            allocator.free(s.summary);
            if (s.run_id) |r| allocator.free(r);
        }
        allocator.free(result.steps);
        if (result.final_run_id) |r| allocator.free(r);
        if (result.proposal_rel) |p| allocator.free(p);
        if (result.response_text) |t| allocator.free(t);
    }

    if (!flags.quiet) {
        try writer.print("\nAgent completed: {d} steps, {d} repair attempts\n", .{ result.steps.len, result.repair_attempts });
        if (result.proposal_rel) |p| {
            try writer.print("Proposal: {s}\n", .{p});
        }
        if (result.response_text) |t| {
            try writer.print("Response: {s}\n", .{t});
        }
    }

    ai.spec_writer.markImplemented(allocator, io, root, spec_id) catch {
        try writer.print("warning: failed to mark spec as implemented\n", .{});
    };

    if (result.final_run_id != null or result.proposal_rel != null) {
        const git_head = captureGitHead(allocator, flags.workspace orelse ".");
        if (git_head) |head| {
            defer allocator.free(head);
            if (head.len >= 7 and head.len <= 40 and isHex(head)) {
                ai.spec_writer.recordCommit(allocator, io, root, spec_id, head, "spec implement: agent run") catch {};
            }
        }
    }

    if (!flags.quiet) {
        try writer.print("\nSpec '{s}' marked as implemented.\n", .{spec_id});
        try writer.print("Run `forge spec trace {s}` to see the commit history.\n", .{spec_id});
    }

    if (flags.json) {
        try writer.print("{{\"spec_id\":\"{s}\",\"status\":\"implemented\",\"steps\":{d},\"repair_attempts\":{d}}}\n", .{
            spec_id, result.steps.len, result.repair_attempts,
        });
    }

    return 0;
}

fn captureGitHead(allocator: std.mem.Allocator, cwd: []const u8) ?[]u8 {
    var argv = [_][]const u8{ "git", "rev-parse", "HEAD" };
    const captured = kernel.process.runCapture(allocator, .{
        .argv = &argv,
        .cwd = cwd,
        .max_bytes = 256,
    }) catch return null;
    defer allocator.free(captured.output);
    if (captured.exit_code != 0) return null;
    const trimmed = std.mem.trim(u8, captured.output, " \n\r\t");
    return allocator.dupe(u8, trimmed) catch null;
}

fn isHex(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

fn traceSpec(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot, positionals: []const []const u8, writer: *std.Io.Writer) !u8 {
    if (positionals.len < 2) {
        try writer.print("usage: forge spec trace <name>\n", .{});
        return 2;
    }
    const name = positionals[1];

    const tasks = ai.spec_writer.readSection(allocator, io, root, name, "tasks") catch {
        try writer.print("error: spec '{s}' not found\n", .{name});
        return 1;
    };
    defer allocator.free(tasks);

    try writer.print("Spec: {s}\n\n", .{name});
    try writer.print("Tasks:\n{s}\n\n", .{tasks});

    const trace_entries: []ai.spec_writer.TraceEntry = ai.spec_writer.readTrace(allocator, io, root, name) catch blk: {
        const empty = allocator.alloc(ai.spec_writer.TraceEntry, 0) catch break :blk &[_]ai.spec_writer.TraceEntry{};
        break :blk empty;
    };
    defer if (trace_entries.len > 0) ai.spec_writer.freeTrace(allocator, trace_entries);

    if (trace_entries.len > 0) {
        try writer.print("Recorded commits ({d}):\n", .{trace_entries.len});
        for (trace_entries) |entry| {
            try writer.print("  {s}  {s}\n", .{ entry.commit[0..@min(entry.commit.len, 8)], entry.subject });
        }
        try writer.print("\n", .{});
    } else {
        try writer.print("Recorded commits: (none)\n\n", .{});
    }

    const git_result = blk: {
        var git_argv = [_][]const u8{ "git", "log", "--oneline", "--all", "--grep", name };
        const captured = kernel.process.runCapture(allocator, .{
            .argv = &git_argv,
            .cwd = null,
            .max_bytes = 8 * 1024,
        }) catch break :blk null;
        break :blk captured;
    } orelse {
        try writer.print("(git log not available - skipping git grep)\n", .{});
        return 0;
    };
    defer allocator.free(git_result.output);

    if (git_result.output.len == 0) {
        try writer.print("Git log matches: (none)\n", .{});
    } else {
        try writer.print("Git log matches:\n{s}\n", .{git_result.output});
    }
    return 0;
}

fn printUsage(writer: *std.Io.Writer) !void {
    try writer.print(
        \\Usage: forge spec <subcommand> [options]
        \\
        \\Subcommands:
        \\  init                                      Create specs/ directory with templates
        \\  template <type>                           Print spec template (feature|bugfix|refactor|spike)
        \\  create <name> [--intent "text"]            Create a new spec
        \\  list                                      List all specs
        \\  show <name> [section]                      Show spec content (req|design|tasks|plan)
        \\  edit <name> --section <s> --body "text"    Replace a section
        \\  approve <name>                            Mark spec approved
        \\  reject <name>                             Mark spec rejected
        \\  implement <name> [--provider ...] [--max-steps N]  Run agent to implement spec
        \\  trace <name>                              Show task->commit traceability
        \\  validate [<name>]                         Validate spec schema and requirements
        \\
        \\Sections: requirements (req), design, tasks, plan
        \\
    , .{});
}

// ---------------------------------------------------------------------------
// Phase 3 additions (RFC-0014)
// ---------------------------------------------------------------------------

/// `forge spec init` — create specs/ directory with templates and README.
fn initSpecs(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot, flags: args_mod.GlobalFlags, writer: *std.Io.Writer) !u8 {
    _ = allocator;
    const subdirs = [_][]const u8{ "specs/features", "specs/bugfixes", "specs/refactors", "specs/spikes", "specs/templates" };
    var created: u32 = 0;
    for (subdirs) |subdir| {
        root.dir.createDirPath(io, subdir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => {
                try writer.print("error: cannot create {s}: {}\n", .{ subdir, err });
                return 1;
            },
        };
        created += 1;
    }

    // Create templates
    const templates = [_]struct { path: []const u8, content: []const u8 }{
        .{ .path = "specs/templates/feature.md", .content = feature_template },
        .{ .path = "specs/templates/bugfix.md", .content = bugfix_template },
        .{ .path = "specs/templates/refactor.md", .content = refactor_template },
        .{ .path = "specs/templates/spike.md", .content = spike_template },
    };
    for (templates) |tpl| {
        const rel = workspace.WorkspacePath.parse(tpl.path) catch continue;
        workspace.atomic.replaceFile(io, root, rel, tpl.content) catch {
            try writer.print("warning: cannot create {s}\n", .{tpl.path});
            continue;
        };
        created += 1;
    }

    // Create README
    const readme_rel = workspace.WorkspacePath.parse("specs/README.md") catch return 1;
    workspace.atomic.replaceFile(io, root, readme_rel, specs_readme) catch {};

    if (flags.json) {
        try writer.print("{{\"type\":\"spec_init\",\"created\":{d},\"status\":\"ok\"}}\n", .{created});
    } else {
        try writer.print("Created specs/ directory structure ({d} items).\n", .{created});
        try writer.writeAll("\nNext steps:\n");
        try writer.writeAll("  1. forge spec template feature > specs/features/my-feature.md\n");
        try writer.writeAll("  2. Edit the spec to add requirements and acceptance criteria.\n");
        try writer.writeAll("  3. forge spec approve my-feature\n");
        try writer.writeAll("  4. forge spec implement my-feature\n");
    }
    return 0;
}

/// `forge spec template <type>` — print a spec template to stdout.
fn showTemplate(allocator: std.mem.Allocator, positionals: []const []const u8, writer: *std.Io.Writer) !u8 {
    _ = allocator;
    const tpl_type = if (positionals.len >= 2) positionals[1] else "feature";
    const template: []const u8 = if (std.mem.eql(u8, tpl_type, "feature"))
        feature_template
    else if (std.mem.eql(u8, tpl_type, "bugfix"))
        bugfix_template
    else if (std.mem.eql(u8, tpl_type, "refactor"))
        refactor_template
    else if (std.mem.eql(u8, tpl_type, "spike"))
        spike_template
    else {
        try writer.print("error: unknown template type '{s}'. Use: feature|bugfix|refactor|spike\n", .{tpl_type});
        return 2;
    };
    try writer.writeAll(template);
    return 0;
}

/// `forge spec validate [<name>]` — validate spec schema and requirements.
fn validateSpecs(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot, positionals: []const []const u8, writer: *std.Io.Writer) !u8 {
    var has_errors = false;
    var checked: u32 = 0;

    if (positionals.len >= 2) {
        // Validate single spec
        const name = positionals[1];
        checked += 1;
        const errors = try validateOneSpec(allocator, io, root, name);
        defer allocator.free(errors);
        if (errors.len > 0) {
            has_errors = true;
            try writer.print("✗ Spec '{s}' has issues:\n", .{name});
            for (errors) |e| try writer.print("  - {s}\n", .{e});
        } else {
            try writer.print("✓ Spec '{s}' is valid\n", .{name});
        }
    } else {
        // Validate all specs
        const specs = ai.spec_writer.listSpecs(allocator, io, root) catch {
            try writer.writeAll("error: failed to list specs\n");
            return 1;
        };
        defer ai.spec_writer.freeSpecList(allocator, specs);

        for (specs) |spec| {
            checked += 1;
            const errors = try validateOneSpec(allocator, io, root, spec.run_id);
            defer allocator.free(errors);
            if (errors.len > 0) {
                has_errors = true;
                try writer.print("✗ Spec '{s}':\n", .{spec.run_id});
                for (errors) |e| try writer.print("  - {s}\n", .{e});
            } else {
                try writer.print("✓ Spec '{s}' is valid\n", .{spec.run_id});
            }
        }
    }

    if (checked == 0) {
        try writer.writeAll("No specs found. Run `forge spec init` to create the specs/ directory.\n");
    } else if (!has_errors) {
        try writer.print("\nAll {d} specs valid.\n", .{checked});
    }

    return if (has_errors) 1 else 0;
}

fn validateOneSpec(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot, name: []const u8) ![][]const u8 {
    var errors: std.ArrayList([]const u8) = .empty;
    defer errors.deinit(allocator);

    // Check requirements section exists and is non-empty.
    const req = ai.spec_writer.readSection(allocator, io, root, name, "requirements") catch {
        try errors.append(allocator, try std.fmt.allocPrint(allocator, "missing 'requirements' section", .{}));
        return errors.toOwnedSlice(allocator);
    };
    defer allocator.free(req);
    if (std.mem.trim(u8, req, " \t\r\n").len == 0) {
        try errors.append(allocator, try std.fmt.allocPrint(allocator, "'requirements' section is empty", .{}));
    }

    // Check tasks section exists.
    const tasks = ai.spec_writer.readSection(allocator, io, root, name, "tasks") catch {
        try errors.append(allocator, try std.fmt.allocPrint(allocator, "missing 'tasks' section", .{}));
        return errors.toOwnedSlice(allocator);
    };
    defer allocator.free(tasks);
    if (std.mem.trim(u8, tasks, " \t\r\n").len == 0) {
        try errors.append(allocator, try std.fmt.allocPrint(allocator, "'tasks' section is empty", .{}));
    }

    return errors.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Spec templates (RFC-0014)
// ---------------------------------------------------------------------------

const feature_template =
    \\---
    \\spec_id: <auto-generated>
    \\title: "<title>"
    \\type: feature
    \\status: draft
    \\author: <your-name>
    \\created: <YYYY-MM-DD>
    \\updated: <YYYY-MM-DD>
    \\approver: ""
    \\implementation_pr: ""
    \\related_rfc: ""
    \\---
    \\
    \\## Context
    \\<Why this spec exists — what problem does it solve?>
    \\
    \\## Requirements
    \\- R1: <requirement 1>
    \\- R2: <requirement 2>
    \\
    \\## Design
    \\<High-level design — no implementation detail. Reference RFCs if applicable.>
    \\
    \\## Acceptance
    \\- [ ] R1 verified via <how>
    \\- [ ] R2 verified via <how>
    \\
    \\## Out of scope
    \\<What is explicitly NOT in this spec.>
    \\
;

const bugfix_template =
    \\---
    \\spec_id: <auto-generated>
    \\title: "<title>"
    \\type: bugfix
    \\status: draft
    \\author: <your-name>
    \\created: <YYYY-MM-DD>
    \\updated: <YYYY-MM-DD>
    \\approver: ""
    \\implementation_pr: ""
    \\related_rfc: ""
    \\---
    \\
    \\## Context
    \\<What is the bug? When does it happen? What is the impact?>
    \\
    \\## Requirements
    \\- R1: <root cause addressed>
    \\- R2: <regression test added>
    \\
    \\## Design
    \\<Minimal fix description. Avoid scope creep.>
    \\
    \\## Acceptance
    \\- [ ] Bug no longer reproduces with <repro steps>
    \\- [ ] Regression test passes
    \\- [ ] No new failures in `forge check`
    \\
    \\## Out of scope
    \\<Related improvements that should be separate specs.>
    \\
;

const refactor_template =
    \\---
    \\spec_id: <auto-generated>
    \\title: "<title>"
    \\type: refactor
    \\status: draft
    \\author: <your-name>
    \\created: <YYYY-MM-DD>
    \\updated: <YYYY-MM-DD>
    \\approver: ""
    \\implementation_pr: ""
    \\related_rfc: ""
    \\---
    \\
    \\## Context
    \\<What code is being refactored? Why now? What is the current pain?>
    \\
    \\## Requirements
    \\- R1: <behavior preserved>
    \\- R2: <measurable improvement: perf, readability, testability>
    \\
    \\## Design
    \\<Before/after sketch. Call out any API changes.>
    \\
    \\## Acceptance
    \\- [ ] All existing tests pass
    \\- [ ] New tests cover the refactored path
    \\- [ ] No public API breaks (or migration guide added)
    \\
    \\## Out of scope
    \\<Behavior changes that should be separate specs.>
    \\
;

const spike_template =
    \\---
    \\spec_id: <auto-generated>
    \\title: "<title>"
    \\type: spike
    \\status: draft
    \\author: <your-name>
    \\created: <YYYY-MM-DD>
    \\updated: <YYYY-MM-DD>
    \\approver: ""
    \\implementation_pr: ""
    \\related_rfc: ""
    \\---
    \\
    \\## Context
    \\<What question are we trying to answer? What is the time box?>
    \\
    \\## Requirements
    \\- R1: <question answered with evidence>
    \\- R2: <decision: proceed / pivot / abort>
    \\
    \\## Design
    \\<Experiment plan. What will we build/measure to answer the question?>
    \\
    \\## Acceptance
    \\- [ ] Question answered with concrete data
    \\- [ ] Decision documented
    \\- [ ] Findings shared with team
    \\
    \\## Out of scope
    \\<Production implementation — that is a follow-up spec.>
    \\
;

const specs_readme =
    \\# Specs
    \\
    \\This directory is the source of truth for spec-driven development in Forge.
    \\See [RFC-0014](../docs/rfc/RFC-0014-spec-driven-development.md) for the full workflow.
    \\
    \\## Layout
    \\
    \\```text
    \\specs/
    \\├── features/      # new functionality
    \\├── bugfixes/      # bug fixes
    \\├── refactors/     # code refactors
    \\├── spikes/        # research / time-boxed experiments
    \\└── templates/     # spec templates (feature, bugfix, refactor, spike)
    \\```
    \\
    \\## Workflow
    \\
    \\```bash
    \\forge spec init                          # create this directory + templates
    \\forge spec template feature > specs/features/my-feature.md
    \\forge spec create my-feature             # register with Forge
    \\forge spec edit my-feature --section requirements --body "..."
    \\forge spec validate my-feature           # check schema
    \\forge spec approve my-feature            # mark ready to implement
    \\forge spec implement my-feature          # agent proposes from spec
    \\forge spec trace my-feature              # show spec -> commit trace
    \\```
    \\
    \\`forge check` runs `forge spec validate` on all specs automatically.
    \\
;
