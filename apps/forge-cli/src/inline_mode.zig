//! Inline mode — sequential output with native terminal scrollback.
//!
//! This is the Aider-style approach: messages are printed sequentially to
//! stdout (going into the terminal's native scrollback), and the input
//! prompt sits at the bottom. No cursor positioning, no alternate screen,
//! no full-screen repaint. The terminal handles all scrolling natively.
//!
//! Benefits over full TUI mode:
//!   - Native scrollback works perfectly (mouse wheel, Shift-PgUp, tmux)
//!   - Zero flicker (no repaint)
//!   - Lower CPU (no render loop)
//!   - Simpler code (~300 LOC vs 8000+ LOC TUI)
//!
//! Trade-offs:
//!   - No status bar (model/mode/tokens shown before each prompt)
//!   - No inline diff highlighting (diffs printed as plain text)
//!   - No slash command autocomplete menu (commands still work, just no popup)
//!   - Tool steps printed inline (not in cards)
//!
//! Usage: forge agent (default = inline) or forge agent --tui (full TUI)

const std = @import("std");
const ai = @import("forge-ai");
const workspace = @import("forge-workspace");
const kernel = @import("forge-kernel");
const args_mod = @import("args.zig");
const workspace_cmd = @import("workspace_cmd.zig");
const ai_workflow = @import("ai_workflow.zig");
const cancel_scope_mod = @import("cancel_scope.zig");
const commands = @import("agent_tui/commands.zig");

const Io = std.Io;

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    parsed: args_mod.CliArgs,
) !u8 {
    var opened = workspace_cmd.OpenedWorkspace.open(allocator, io, parsed) catch |err| {
        std.debug.print("error opening workspace: {}\n", .{err});
        return 2;
    };
    defer opened.close(io);

    // Set up raw mode for input (line editing + history).
    const fd = std.posix.STDIN_FILENO;
    const saved = std.posix.tcgetattr(fd) catch {
        // Not a TTY — fall back to pipe mode.
        return runPipe(allocator, io, environ_map, parsed, &opened);
    };
    var raw = saved;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.cc[@intFromEnum(std.c.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.c.V.TIME)] = 0;
    std.posix.tcsetattr(fd, .FLUSH, raw) catch {};
    defer std.posix.tcsetattr(fd, .FLUSH, saved) catch {};

    var cancel_scope = try cancel_scope_mod.Scope.init(allocator);
    defer cancel_scope.deinit();
    cancel_scope.installSigint();

    // State
    var input_buf: std.ArrayList(u8) = .empty;
    defer input_buf.deinit(allocator);
    var cursor: usize = 0;
    var history: std.ArrayList([]const u8) = .empty;
    defer {
        for (history.items) |h| allocator.free(h);
        history.deinit(allocator);
    }
    var history_pos: ?usize = null;
    var agent_mode: ai.tools.Mode = .agent;
    const provider_name: []const u8 = parsed.flags.provider orelse "auto";
    const model_label: []const u8 = parsed.flags.model orelse "auto";
    var total_input_tokens: u64 = 0;
    var total_output_tokens: u64 = 0;
    var quit = false;
    var first_render = true;
    _ = &first_render;

    // Welcome
    printWelcome(provider_name, model_label, agent_mode);
    first_render = false;

    while (!quit) {
        // Show prompt
        printPrompt(provider_name, model_label, agent_mode, &input_buf, cursor, total_input_tokens + total_output_tokens);

        // Read a key
        var key_buf: [16]u8 = undefined;
        const n = std.posix.read(fd, &key_buf) catch break;
        if (n == 0) break;

        const k = parseInlineKey(key_buf[0..n]);

        switch (k) {
            .enter => {
                _ = writeAll("\r\n");
                if (input_buf.items.len == 0) continue;

                // Save to history
                const owned = allocator.dupe(u8, input_buf.items) catch input_buf.items;
                history.append(allocator, owned) catch {};
                history_pos = null;

                // Check for slash commands
                const input = input_buf.items;
                if (std.mem.startsWith(u8, input, "/")) {
                    const cmd = commands.parseSlashCommand(input);
                    switch (cmd) {
                        .exit_app => quit = true,
                        .wipe_history => {
                            _ = writeAll("\x1b[2J\x1b[H");
                            printWelcome(provider_name, model_label, agent_mode);
                        },
                        .mode => |mode| {
                            agent_mode = mode;
                            _ = writeAll("\r\n ✓ Mode: ");
                            _ = writeAll(commands.modeLabel(mode));
                            _ = writeAll("\r\n");
                        },
                        .mode_cycle => {
                            agent_mode = switch (agent_mode) {
                                .ask => .plan,
                                .plan => .agent,
                                .agent => .ask,
                            };
                            _ = writeAll("\r\n ✓ Mode: ");
                            _ = writeAll(commands.modeLabel(agent_mode));
                            _ = writeAll("\r\n");
                        },
                        .help => {
                            printHelp();
                        },
                        else => {
                            _ = writeAll("\r\n (command not supported in inline mode — use --tui for full TUI)\r\n");
                        },
                    }
                    input_buf.clearRetainingCapacity();
                    cursor = 0;
                    continue;
                }

                // Run agent
                const intent = allocator.dupe(u8, input_buf.items) catch continue;
                input_buf.clearRetainingCapacity();
                cursor = 0;

                _ = writeAll("\r\n");
                runAgentInline(allocator, io, environ_map, parsed, &opened, intent, provider_name, agent_mode, &total_input_tokens, &total_output_tokens) catch |err| {
                    std.debug.print("\r\n✗ Error: {}\r\n", .{err});
                };
                _ = writeAll("\r\n");
            },
            .ctrl_c => {
                if (input_buf.items.len > 0) {
                    input_buf.clearRetainingCapacity();
                    cursor = 0;
                    _ = writeAll("^C\r\n");
                } else {
                    quit = true;
                }
            },
            .backspace => {
                if (cursor > 0) {
                    _ = input_buf.orderedRemove(cursor - 1);
                    cursor -= 1;
                    redrawInputLine(&input_buf, cursor);
                }
            },
            .up => {
                // History navigation
                if (history.items.len > 0) {
                    var pos = history_pos orelse history.items.len;
                    if (pos > 0) pos -= 1;
                    history_pos = pos;
                    input_buf.clearRetainingCapacity();
                    input_buf.appendSlice(allocator, history.items[pos]) catch {};
                    cursor = input_buf.items.len;
                    redrawInputLine(&input_buf, cursor);
                }
            },
            .down => {
                if (history.items.len > 0) {
                    var pos = history_pos orelse history.items.len;
                    if (pos < history.items.len) pos += 1;
                    history_pos = if (pos >= history.items.len) null else pos;
                    input_buf.clearRetainingCapacity();
                    if (history_pos) |p| {
                        input_buf.appendSlice(allocator, history.items[p]) catch {};
                    }
                    cursor = input_buf.items.len;
                    redrawInputLine(&input_buf, cursor);
                }
            },
            .left => {
                if (cursor > 0) {
                    cursor -= 1;
                    _ = writeAll("\x1b[D");
                }
            },
            .right => {
                if (cursor < input_buf.items.len) {
                    cursor += 1;
                    _ = writeAll("\x1b[C");
                }
            },
            .char => |ch| {
                if (ch == 3) { // Ctrl+C
                    if (input_buf.items.len > 0) {
                        input_buf.clearRetainingCapacity();
                        cursor = 0;
                        _ = writeAll("^C\r\n");
                    } else {
                        quit = true;
                    }
                } else if (ch == 4) { // Ctrl+D
                    quit = true;
                } else if (ch >= 32 and ch < 127) {
                    _ = input_buf.insert(allocator, cursor, ch) catch {};
                    cursor += 1;
                    redrawInputLine(&input_buf, cursor);
                }
            },
            .escape, .none => {},
        }
    }

    _ = writeAll("\r\n");
    return 0;
}

const InlineKey = union(enum) {
    enter,
    ctrl_c,
    backspace,
    up,
    down,
    left,
    right,
    char: u8,
    escape,
    none,
};

fn parseInlineKey(buf: []const u8) InlineKey {
    if (buf.len == 0) return .none;
    if (buf[0] == '\r' or buf[0] == '\n') return .enter;
    if (buf[0] == 127 or buf[0] == 8) return .backspace;
    if (buf[0] == 3) return .ctrl_c;
    if (buf[0] == 27) {
        if (buf.len >= 3 and buf[1] == '[') {
            return switch (buf[2]) {
                'A' => .up,
                'B' => .down,
                'C' => .right,
                'D' => .left,
                else => .escape,
            };
        }
        return .escape;
    }
    return .{ .char = buf[0] };
}

fn writeAll(bytes: []const u8) usize {
    var total: usize = 0;
    var index: usize = 0;
    while (index < bytes.len) {
        const n = std.c.write(std.posix.STDOUT_FILENO, bytes.ptr + index, bytes.len - index);
        if (n <= 0) break;
        const written: usize = @intCast(n);
        index += written;
        total += written;
    }
    return total;
}

fn printWelcome(provider: []const u8, model: []const u8, mode: ai.tools.Mode) void {
    _ = writeAll("\r\n");
    _ = writeAll("\x1b[1m\x1b[92m✨ Forge AI\x1b[0m — type your request, or /help for commands\r\n");
    _ = writeAll("\x1b[90m");
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "Provider: {s} · Model: {s} · Mode: {s}\r\n", .{ provider, model, commands.modeLabel(mode) }) catch "";
    _ = writeAll(line);
    _ = writeAll("\x1b[0m\r\n");
}

fn printPrompt(provider: []const u8, model: []const u8, mode: ai.tools.Mode, input: *std.ArrayList(u8), cursor: usize, tokens: u64) void {
    _ = provider;
    _ = model;
    _ = tokens;
    // Clear current line + show prompt
    _ = writeAll("\r\x1b[2K");
    const mode_icon: u8 = switch (mode) {
        .ask => '?',
        .plan => '+',
        .agent => '>',
    };
    var buf: [8]u8 = undefined;
    _ = writeAll(buf[0..1]);
    buf[0] = mode_icon;
    _ = writeAll(buf[0..1]);
    _ = writeAll(" ");
    if (input.items.len > 0) {
        _ = writeAll(input.items);
    }
    // Position cursor
    if (cursor < input.items.len) {
        var move_buf: [16]u8 = undefined;
        const back = input.items.len - cursor;
        const move = std.fmt.bufPrint(&move_buf, "\x1b[{d}D", .{back}) catch "";
        _ = writeAll(move);
    }
}

fn redrawInputLine(input: *std.ArrayList(u8), cursor: usize) void {
    // Clear line + redraw
    _ = writeAll("\r\x1b[2K> ");
    if (input.items.len > 0) {
        _ = writeAll(input.items);
    }
    // Position cursor
    if (cursor < input.items.len) {
        var move_buf: [16]u8 = undefined;
        const back = input.items.len - cursor;
        const move = std.fmt.bufPrint(&move_buf, "\x1b[{d}D", .{back}) catch "";
        _ = writeAll(move);
    }
}

fn printHelp() void {
    _ = writeAll("\r\n");
    _ = writeAll("\x1b[1mForge Inline — Commands\x1b[0m\r\n");
    _ = writeAll("\r\n");
    _ = writeAll("  /exit          Quit\r\n");
    _ = writeAll("  /clear         Clear screen\r\n");
    _ = writeAll("  /mode <mode>   Switch mode (ask|plan|agent)\r\n");
    _ = writeAll("  /help          Show this help\r\n");
    _ = writeAll("  /model <id>    Switch model (in full TUI mode)\r\n");
    _ = writeAll("  /cost          Show token usage (in full TUI mode)\r\n");
    _ = writeAll("\r\n");
    _ = writeAll("\x1b[90mFor full TUI with slash command menu, @mentions, and diff cards:\x1b[0m\r\n");
    _ = writeAll("\x1b[90m  forge agent --tui\x1b[0m\r\n");
    _ = writeAll("\r\n");
}

fn runAgentInline(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    parsed: args_mod.CliArgs,
    opened: *workspace_cmd.OpenedWorkspace,
    intent: []const u8,
    provider_name: []const u8,
    mode: ai.tools.Mode,
    total_input_tokens: *u64,
    total_output_tokens: *u64,
) !void {
    _ = mode;
    // Show "Working..." indicator
    _ = writeAll("\x1b[90m⠹ Working...\x1b[0m\r\n");

    // Set up cancel scope
    var scope = try cancel_scope_mod.Scope.init(allocator);
    defer scope.deinit();
    scope.installSigint();
    var cancel_token = scope.token();

    // Build provider options
    var provider_options = ai_workflow.agentProviderOptionsFromFlags(
        allocator,
        parsed.flags,
        "ask",
        io,
        opened.root,
    );
    defer provider_options.deinit(allocator);

    // Override provider if specified
    if (std.mem.eql(u8, provider_name, "fake")) {
        provider_options.options.provider_name = "fake";
    }

    // Run the workflow
    const generated = ai_workflow.generateAndPersist(
        allocator,
        io,
        environ_map,
        opened.*,
        .ask,
        intent,
        parsed.flags.files,
        provider_options.options,
        .{
            .cancel_token = &cancel_token,
            .progress_writer = null,
            .progress_json = false,
        },
    ) catch |err| {
        var err_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&err_buf, "\x1b[91m✗ Error: {}\x1b[0m\r\n", .{err}) catch "\x1b[91m✗ Error\x1b[0m\r\n";
        _ = writeAll(msg);
        return;
    };
    defer allocator.free(generated.run_id);
    defer allocator.free(generated.proposal_rel);

    // Show proposal info
    var prop_buf: [512]u8 = undefined;
    const prop_line = std.fmt.bufPrint(&prop_buf, "\x1b[33m📄 Proposal saved: {s}\x1b[0m\r\n", .{generated.proposal_rel}) catch "";
    _ = writeAll(prop_line);
    _ = writeAll("\x1b[90mReview: forge diff ");
    _ = writeAll(generated.proposal_rel);
    _ = writeAll(" · Apply: forge apply ");
    _ = writeAll(generated.proposal_rel);
    _ = writeAll(" --yes\x1b[0m\r\n");

    // Token estimates
    total_input_tokens.* += intent.len / 4;
    total_output_tokens.* += 100; // rough estimate
}

fn runPipe(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    parsed: args_mod.CliArgs,
    opened: *workspace_cmd.OpenedWorkspace,
) !u8 {
    _ = allocator;
    _ = io;
    _ = environ_map;
    _ = parsed;
    _ = opened;
    _ = writeAll("forge agent: not a TTY — use 'forge chat --pipe' for piped input\r\n");
    return 2;
}
