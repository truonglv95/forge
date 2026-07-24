const std = @import("std");
const ai = @import("forge-ai");
const args_mod = @import("args.zig");
const workspace_cmd = @import("workspace_cmd.zig");
const ai_workflow = @import("ai_workflow.zig");
const cancel_scope_mod = @import("cancel_scope.zig");

const Io = std.Io;

/// `forge chat` — Interactive chat REPL with @mentions and slash commands.
///
/// RFC-0017 (stub for MR #1; full implementation in MR #3).
/// For now, supports:
///   - `--pipe` mode: read intent from stdin, one-shot response
///   - Basic slash commands: /help, /exit, /mode, /capability, /provider
///
/// Full REPL with streaming, autocomplete, session resume will be added in MR #3.
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

    // Interactive REPL (basic stub)
    if (parsed.flags.json) {
        try writer.writeAll("{\"type\":\"chat\",\"status\":\"interactive_not_supported\",\"note\":\"Use --pipe for one-shot, or wait for MR #3 full REPL\"}\n");
        return 0;
    }

    try writer.writeAll("Forge Chat REPL (RFC-0017 stub — full REPL in MR #3)\n");
    try writer.writeAll("Use --pipe for one-shot mode. Slash commands: /help, /exit, /mode, /provider\n");
    try writer.writeAll("Type /exit to quit.\n\n");

    // Set up stdin reader.
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader: Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    const stdin = &stdin_reader.interface;

    var mode: []const u8 = "agent";
    var capability: []const u8 = "propose";
    var provider: []const u8 = parsed.flags.provider orelse "auto";

    while (true) {
        try writer.print("[{s}|{s}|{s}] > ", .{ mode, capability, provider });
        try writer.flush();

        const maybe_slice = stdin.takeDelimiter('\n') catch break;
        const slice = maybe_slice orelse break; // EOF

        const input = std.mem.trim(u8, slice, " \t\r\n");
        if (input.len == 0) continue;

        if (std.mem.startsWith(u8, input, "/")) {
            const cmd_end = std.mem.indexOfScalar(u8, input, ' ') orelse input.len;
            const cmd = input[1..cmd_end];
            const arg = if (cmd_end < input.len) std.mem.trim(u8, input[cmd_end..], " ") else "";

            if (std.mem.eql(u8, cmd, "exit") or std.mem.eql(u8, cmd, "quit")) {
                try writer.writeAll("Session ended.\n");
                return 0;
            } else if (std.mem.eql(u8, cmd, "help")) {
                try writer.writeAll("Commands: /help, /exit, /mode <ask|plan|agent>, /capability <read_only|propose|propose_and_task>, /provider <name>\n");
            } else if (std.mem.eql(u8, cmd, "mode")) {
                if (arg.len > 0) mode = arg;
                try writer.print("Mode: {s}\n", .{mode});
            } else if (std.mem.eql(u8, cmd, "capability")) {
                if (arg.len > 0) capability = arg;
                try writer.print("Capability: {s}\n", .{capability});
            } else if (std.mem.eql(u8, cmd, "provider")) {
                if (arg.len > 0) provider = arg;
                try writer.print("Provider: {s}\n", .{provider});
            } else {
                try writer.print("Unknown command: /{s}. Try /help.\n", .{cmd});
            }
            continue;
        }

        // Treat input as intent and dispatch to ask workflow (stub).
        try writer.print("[stub] Would ask: '{s}' (full REPL in MR #3)\n", .{input});
    }

    return 0;
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

    var opened = try workspace_cmd.OpenedWorkspace.open(allocator, io, parsed);
    defer opened.close(io);

    var scope = try cancel_scope_mod.Scope.init(allocator);
    defer scope.deinit();
    const cancel_token = scope.token();

    var provider_options = ai_workflow.agentProviderOptionsFromFlags(allocator, parsed.flags, intent, io, opened.root);
    defer provider_options.deinit(allocator);

    const generated = ai_workflow.generateAndPersist(
        allocator,
        io,
        environ_map,
        opened,
        .ask,
        intent,
        parsed.flags.files,
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
    // Stub test; full REPL tests in MR #3.
    try std.testing.expect(true);
}
