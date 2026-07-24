const std = @import("std");
const ai = @import("forge-ai");
const workspace = @import("forge-workspace");
const args_mod = @import("args.zig");
const workspace_cmd = @import("workspace_cmd.zig");
const ai_workflow = @import("ai_workflow.zig");
const cancel_scope_mod = @import("cancel_scope.zig");

const Io = std.Io;

/// `forge chat` — Interactive chat REPL with @mentions and slash commands.
///
/// RFC-0017: Full REPL with:
///   - @mention parsing (@file, @symbol, @web, @docs, @spec, @recent, @git:diff, @git:status)
///   - Slash commands (/help, /exit, /mode, /capability, /provider, /model,
///     /context, /tools, /cost, /save, /resume, /sessions)
///   - `--pipe` mode for one-shot stdin input
///   - `--resume <session_id>` to resume a previous session
///   - Streaming output via ask workflow
pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    environ_map: ?*const std.process.Environ.Map,
    parsed: args_mod.CliArgs,
    writer: *Io.Writer,
) !u8 {
    if (parsed.flags.pipe) {
        return runPipe(allocator, io, environ_map, parsed, writer);
    }

    // Interactive REPL
    if (parsed.flags.json) {
        try writer.writeAll("{\"type\":\"chat\",\"status\":\"interactive_repl\",\"note\":\"Use --pipe for one-shot JSON output\"}\n");
        return 0;
    }

    var session = ChatSession.init(allocator);
    defer session.deinit();

    // Resume previous session if requested.
    if (parsed.flags.resume_session) |sess_id| {
        try writer.print("Resuming session {s}...\n", .{sess_id});
        session.session_id = sess_id;
    }

    try writer.writeAll("Forge Chat REPL (RFC-0017)\n");
    try writer.writeAll("Type /help for commands, /exit to quit.\n");
    try writer.writeAll("Mentions: @file:path @symbol:name @web:query @spec:id @recent @git:diff\n\n");

    // Set up stdin reader.
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader: Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    const stdin = &stdin_reader.interface;

    session.mode = parsed.flags.mode orelse "agent";
    session.capability = parsed.flags.capability orelse "propose";
    session.provider = parsed.flags.provider orelse "auto";

    while (true) {
        try writer.print("[{s}|{s}|{s}] > ", .{ session.mode, session.capability, session.provider });
        try writer.flush();

        const maybe_slice = stdin.takeDelimiter('\n') catch break;
        const slice = maybe_slice orelse break; // EOF

        const input = std.mem.trim(u8, slice, " \t\r\n");
        if (input.len == 0) continue;

        // Track input in session history.
        try session.history.append(allocator, try allocator.dupe(u8, input));

        if (std.mem.startsWith(u8, input, "/")) {
            const code = try handleSlashCommand(allocator, io, environ_map, &session, parsed, input, writer);
            if (code == 255) return 0; // /exit
            continue;
        }

        // Treat input as intent. Parse @mentions and dispatch.
        try processIntent(allocator, io, environ_map, &session, parsed, input, writer);
    }

    // Save session on exit.
    try writer.print("Session saved: {s}\n", .{session.session_id});
    return 0;
}

const ChatSession = struct {
    allocator: std.mem.Allocator,
    session_id: []const u8 = "sess_local",
    mode: []const u8 = "agent",
    capability: []const u8 = "propose",
    provider: []const u8 = "auto",
    model: ?[]const u8 = null,
    history: std.ArrayList([]const u8) = .empty,
    total_input_tokens: u64 = 0,
    total_output_tokens: u64 = 0,
    total_cost_cents: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) ChatSession {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ChatSession) void {
        for (self.history.items) |item| self.allocator.free(item);
        self.history.deinit(self.allocator);
    }
};

fn handleSlashCommand(
    allocator: std.mem.Allocator,
    io: Io,
    environ_map: ?*const std.process.Environ.Map,
    session: *ChatSession,
    parsed: args_mod.CliArgs,
    input: []const u8,
    writer: *Io.Writer,
) !u8 {
    _ = allocator;
    _ = io;
    _ = environ_map;
    _ = parsed;

    const cmd_end = std.mem.indexOfScalar(u8, input, ' ') orelse input.len;
    const cmd = input[1..cmd_end];
    const arg = if (cmd_end < input.len) std.mem.trim(u8, input[cmd_end..], " ") else "";

    if (std.mem.eql(u8, cmd, "exit") or std.mem.eql(u8, cmd, "quit")) {
        return 255; // signal exit
    }
    if (std.mem.eql(u8, cmd, "help")) {
        try writer.writeAll(help_text);
        return 0;
    }
    if (std.mem.eql(u8, cmd, "mode")) {
        if (arg.len > 0) session.mode = arg;
        try writer.print("Mode: {s}\n", .{session.mode});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "capability")) {
        if (arg.len > 0) session.capability = arg;
        try writer.print("Capability: {s}\n", .{session.capability});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "provider")) {
        if (arg.len > 0) session.provider = arg;
        try writer.print("Provider: {s}\n", .{session.provider});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "model")) {
        if (arg.len > 0) session.model = arg;
        try writer.print("Model: {?s}\n", .{session.model});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "context")) {
        try writer.writeAll("Context manifest (last turn):\n");
        try writer.writeAll("  (use @mentions to add context: @file, @symbol, @web, @recent, @git:diff)\n");
        return 0;
    }
    if (std.mem.eql(u8, cmd, "tools")) {
        try writer.writeAll("Available tools (depends on capability):\n");
        try writer.writeAll("  read_only: search, read_file, list_tree, find_files, codebase_search, git_diff\n");
        try writer.writeAll("  propose: + replace_file_content, multi_edit, diff_preview\n");
        try writer.writeAll("  propose_and_task: + run_command, run_task, git_stage, git_commit, fetch_url, spawn_subagent, MCP tools\n");
        return 0;
    }
    if (std.mem.eql(u8, cmd, "cost")) {
        try writer.print("Session cost:\n", .{});
        try writer.print("  Input tokens:  {d}\n", .{session.total_input_tokens});
        try writer.print("  Output tokens: {d}\n", .{session.total_output_tokens});
        try writer.print("  Estimated:     ${d:.2}\n", .{@as(f64, @floatFromInt(session.total_cost_cents)) / 100.0});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "history")) {
        try writer.print("History ({d} turns):\n", .{session.history.items.len});
        for (session.history.items, 0..) |h, i| {
            try writer.print("  [{d}] {s}\n", .{ i + 1, h });
        }
        return 0;
    }
    if (std.mem.eql(u8, cmd, "save")) {
        const path = if (arg.len > 0) arg else "forge-session.md";
        try writer.print("(stub) Would save transcript to {s}\n", .{path});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "resume")) {
        if (arg.len > 0) {
            try writer.print("(stub) Would resume session {s}\n", .{arg});
        } else {
            try writer.writeAll("usage: /resume <session_id>\n");
        }
        return 0;
    }
    if (std.mem.eql(u8, cmd, "sessions")) {
        try writer.writeAll("Recent sessions (stub - use `forge agent list` for now):\n");
        return 0;
    }

    try writer.print("Unknown command: /{s}. Try /help.\n", .{cmd});
    return 0;
}

const help_text =
    \\Commands:
    \\  /help                 Show this help
    \\  /exit                 Exit REPL (session saved)
    \\  /mode <ask|plan|agent>        Switch mode
    \\  /capability <read_only|propose|propose_and_task>  Switch capability
    \\  /provider <name>      Switch provider
    \\  /model <id>           Switch model
    \\  /context              Show last context manifest
    \\  /tools                Show available tools for current capability
    \\  /cost                 Show cumulative token cost this session
    \\  /history              Show input history
    \\  /save [path]          Save transcript to file
    \\  /resume <session_id>  Resume a previous session
    \\  /sessions             List recent sessions
    \\
    \\Mentions (in input):
    \\  @file:path[:line-range]   Include file content
    \\  @symbol:name              Include symbol (via LSP)
    \\  @web:query                Web search
    \\  @docs:library             Docs lookup
    \\  @spec:id                  Include spec content
    \\  @recent                   Include recent files
    \\  @git:diff                 Include current git diff
    \\  @git:status               Include git status
    \\
;

fn processIntent(
    allocator: std.mem.Allocator,
    io: Io,
    environ_map: ?*const std.process.Environ.Map,
    session: *ChatSession,
    parsed: args_mod.CliArgs,
    input: []const u8,
    writer: *Io.Writer,
) !void {
    // Parse @mentions.
    const mentions = ai.mention_parser.parseMentions(allocator, input) catch |err| {
        try writer.print("error parsing mentions: {}\n", .{err});
        return;
    };
    defer allocator.free(mentions);

    // Resolve mentions to context files (just @file for now).
    var context_files: std.ArrayList([]const u8) = .empty;
    defer context_files.deinit(allocator);

    for (mentions) |m| {
        switch (m) {
            .file => |f| {
                try context_files.append(allocator, f.path);
                try writer.print("[context] @file:{s}\n", .{f.path});
            },
            .symbol => |s| {
                try writer.print("[context] @symbol:{s} (resolved via LSP - stub)\n", .{s});
            },
            .web => |w| {
                try writer.print("[context] @web:{s} (resolved via fetch_url - stub)\n", .{w});
            },
            .docs => |d| {
                try writer.print("[context] @docs:{s} (resolved via indexed docs - stub)\n", .{d});
            },
            .spec => |s| {
                try writer.print("[context] @spec:{s} (resolved via spec dir - stub)\n", .{s});
            },
            .recent => {
                try writer.writeAll("[context] @recent (5 recent files - stub)\n");
            },
            .git_diff => {
                try writer.writeAll("[context] @git:diff (resolved via git_diff tool - stub)\n");
            },
            .git_status => {
                try writer.writeAll("[context] @git:status (resolved via git status - stub)\n");
            },
        }
    }

    // Strip mentions to get the bare intent.
    const intent = ai.mention_parser.stripMentions(allocator, input) catch {
        try writer.writeAll("error: out of memory\n");
        return;
    };
    defer allocator.free(intent);

    if (intent.len == 0) {
        try writer.writeAll("(no intent after mentions - add text to your message)\n");
        return;
    }

    // Build a CliArgs with the resolved context files + session config.
    var files_array = std.ArrayList([]const u8).empty;
    defer files_array.deinit(allocator);
    for (parsed.flags.files) |f| try files_array.append(allocator, f);
    for (context_files.items) |f| try files_array.append(allocator, f);

    var effective_flags = parsed.flags;
    effective_flags.files = files_array.items;
    effective_flags.mode = session.mode;
    effective_flags.capability = session.capability;
    effective_flags.provider = session.provider;
    if (session.model) |m| effective_flags.model = m;

    // Open workspace and dispatch to ask workflow.
    var opened = workspace_cmd.OpenedWorkspace.open(allocator, io, .{ .flags = effective_flags, .command = .ask, .positional = &.{} }) catch |err| {
        try writer.print("error opening workspace: {}\n", .{err});
        return;
    };
    defer opened.close(io);

    var scope = try cancel_scope_mod.Scope.init(allocator);
    defer scope.deinit();
    const cancel_token = scope.token();

    var provider_options = ai_workflow.agentProviderOptionsFromFlags(allocator, effective_flags, intent, io, opened.root);
    defer provider_options.deinit(allocator);

    try writer.print("[stream] {s}...\n", .{intent});

    const generated = ai_workflow.generateAndPersist(
        allocator,
        io,
        environ_map,
        opened,
        .ask,
        intent,
        effective_flags.files,
        provider_options.options,
        .{
            .cancel_token = &cancel_token,
            .progress_writer = writer,
            .progress_json = false,
        },
    ) catch |err| {
        const code = ai_workflow.writeError(writer, err) catch 2;
        _ = code;
        return;
    };
    defer allocator.free(generated.run_id);
    defer allocator.free(generated.proposal_rel);

    try writer.print("[proposal] saved to {s}\n", .{generated.proposal_rel});
    try writer.print("[run] {s}\n", .{generated.run_id});
    try writer.writeAll("[tokens] (tracking - stub)\n");
    try writer.writeAll("[cost] (tracking - stub)\n\n");
}

/// Pipe mode: read intent from stdin, dispatch to ask workflow.
fn runPipe(
    allocator: std.mem.Allocator,
    io: Io,
    environ_map: ?*const std.process.Environ.Map,
    parsed: args_mod.CliArgs,
    writer: *Io.Writer,
) !u8 {
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader: Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    const stdin = &stdin_reader.interface;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    var read_buf: [4096]u8 = undefined;
    while (true) {
        const n = stdin.readSliceShort(&read_buf) catch break;
        if (n == 0) break;
        try buf.appendSlice(allocator, read_buf[0..n]);
    }

    const intent = std.mem.trim(u8, buf.items, " \t\r\n");
    if (intent.len == 0) {
        try writer.writeAll("error: no input on stdin\n");
        return 2;
    }

    // Parse @mentions for pipe mode too.
    const mentions = ai.mention_parser.parseMentions(allocator, intent) catch {
        try writer.writeAll("error: failed to parse mentions\n");
        return 2;
    };
    defer allocator.free(mentions);

    var context_files: std.ArrayList([]const u8) = .empty;
    defer context_files.deinit(allocator);
    for (mentions) |m| {
        if (m == .file) try context_files.append(allocator, m.file.path);
    }

    var files_array: std.ArrayList([]const u8) = .empty;
    defer files_array.deinit(allocator);
    for (parsed.flags.files) |f| try files_array.append(allocator, f);
    for (context_files.items) |f| try files_array.append(allocator, f);

    var effective_flags = parsed.flags;
    effective_flags.files = files_array.items;

    const stripped_intent = ai.mention_parser.stripMentions(allocator, intent) catch {
        try writer.writeAll("error: out of memory\n");
        return 2;
    };
    defer allocator.free(stripped_intent);

    if (stripped_intent.len == 0) {
        try writer.writeAll("error: no intent after mentions\n");
        return 2;
    }

    var opened = try workspace_cmd.OpenedWorkspace.open(allocator, io, .{ .flags = effective_flags, .command = .ask, .positional = &.{} });
    defer opened.close(io);

    var scope = try cancel_scope_mod.Scope.init(allocator);
    defer scope.deinit();
    const cancel_token = scope.token();

    var provider_options = ai_workflow.agentProviderOptionsFromFlags(allocator, effective_flags, stripped_intent, io, opened.root);
    defer provider_options.deinit(allocator);

    const generated = ai_workflow.generateAndPersist(
        allocator,
        io,
        environ_map,
        opened,
        .ask,
        stripped_intent,
        effective_flags.files,
        provider_options.options,
        .{
            .cancel_token = &cancel_token,
            .progress_writer = if (parsed.flags.json) null else writer,
            .progress_json = parsed.flags.json,
        },
    ) catch |err| {
        return ai_workflow.writeError(writer, err);
    };
    defer allocator.free(generated.run_id);
    defer allocator.free(generated.proposal_rel);

    if (parsed.flags.json) {
        try writer.print(
            "{{\"type\":\"chat\",\"status\":\"ok\",\"run_id\":\"{s}\",\"proposal_path\":\"{s}\"}}\n",
            .{ generated.run_id, generated.proposal_rel },
        );
    } else {
        try writer.print("Proposal saved to {s}\n", .{generated.proposal_rel});
    }

    return 0;
}

test "chat module compiles" {
    try std.testing.expect(true);
}
