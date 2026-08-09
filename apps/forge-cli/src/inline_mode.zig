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
//!   - Simpler code
//!
//! Features:
//!   - Slash command autocomplete popup (type / to see commands)
//!   - /model picker (list + arrow keys to select)
//!   - History navigation (up/down)
//!   - Line editing (backspace, left/right, Ctrl+U)
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
    var provider_name: []const u8 = parsed.flags.provider orelse "auto";
    var model_label: []const u8 = parsed.flags.model orelse "auto";
    var total_input_tokens: u64 = 0;
    var total_output_tokens: u64 = 0;
    var quit = false;
    var first_render = true;
    _ = &first_render;
    var show_cmd_suggestions = false;
    var cmd_suggestion_index: usize = 0;
    var in_model_picker = false;
    var model_picker_index: usize = 0;

    // Welcome
    printWelcome(provider_name, model_label, agent_mode);
    first_render = false;

    // Show initial prompt once.
    redrawInputLineFull(provider_name, model_label, agent_mode, &input_buf, cursor, total_input_tokens + total_output_tokens);

    while (!quit) {
        // NOTE: prompt is NOT redrawn here every iteration. It's only
        // drawn once at startup, and redrawn only when input changes
        // (in redrawInputLine). Drawing it every loop iteration caused
        // the "jumping line" bug — each keystroke printed a new prompt
        // line because \r\x1b[2K only works if cursor is on the prompt
        // line, but after readKey returns the cursor might have moved.
        //
        // The loop is: read key → handle key → (handler redraws if needed)
        // No unconditional prompt render at top of loop.

        // Read a key
        var key_buf: [16]u8 = undefined;
        const n = std.posix.read(fd, &key_buf) catch break;
        if (n == 0) break;

        const k = parseInlineKey(key_buf[0..n]);

        // Model picker mode — intercept all keys
        if (in_model_picker) {
            switch (k) {
                .up => {
                    if (model_picker_index > 0) model_picker_index -= 1;
                },
                .down => {
                    if (model_picker_index + 1 < ai.provider_capability.builtin_models.len) model_picker_index += 1;
                },
                .enter => {
                    const m = ai.provider_capability.builtin_models[model_picker_index];
                    model_label = m.model_id;
                    provider_name = m.provider;
                    in_model_picker = false;
                    _ = writeAll("\r\n");
                    var buf2: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf2, " ✓ Model: {s}/{s}\r\n", .{ m.provider, m.model_id }) catch "";
                    _ = writeAll(msg);
                },
                .escape => in_model_picker = false,
                else => {},
            }
            continue;
        }

        switch (k) {
            .enter => {
                // Clear suggestion popup if showing
                if (show_cmd_suggestions) {
                    clearCmdSuggestions();
                    show_cmd_suggestions = false;
                }
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
                        .model_show => {
                            // Show current model
                            var buf2: [256]u8 = undefined;
                            const msg = std.fmt.bufPrint(&buf2, "\r\n Current: {s}/{s}\r\n", .{ provider_name, model_label }) catch "";
                            _ = writeAll(msg);
                        },
                        .model_set => {
                            // Open model picker
                            in_model_picker = true;
                            model_picker_index = 0;
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
                    var err_buf: [256]u8 = undefined;
                    const err_msg = std.fmt.bufPrint(&err_buf, "\r\n\x1b[91m✗ Error: {}\x1b[0m\r\n", .{err}) catch "\r\n✗ Error\r\n";
                    _ = writeAll(err_msg);
                };
                // After agent completes, print a fresh prompt on a new line.
                _ = writeAll("\r\n");
                redrawInputLineFull(provider_name, model_label, agent_mode, &input_buf, cursor, total_input_tokens + total_output_tokens);
            },
            .ctrl_c => {
                if (input_buf.items.len > 0) {
                    input_buf.clearRetainingCapacity();
                    cursor = 0;
                    show_cmd_suggestions = false;
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
                    // Update suggestions
                    if (input_buf.items.len > 0 and input_buf.items[0] == '/') {
                        show_cmd_suggestions = true;
                        cmd_suggestion_index = 0;
                        printCmdSuggestions(input_buf.items, cmd_suggestion_index);
                    } else {
                        if (show_cmd_suggestions) clearCmdSuggestions();
                        show_cmd_suggestions = false;
                    }
                }
            },
            .up => {
                if (show_cmd_suggestions) {
                    // Navigate suggestions
                    if (cmd_suggestion_index > 0) cmd_suggestion_index -= 1;
                    clearCmdSuggestions();
                    printCmdSuggestions(input_buf.items, cmd_suggestion_index);
                } else {
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
                }
            },
            .down => {
                if (show_cmd_suggestions) {
                    cmd_suggestion_index += 1;
                    clearCmdSuggestions();
                    printCmdSuggestions(input_buf.items, cmd_suggestion_index);
                } else {
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
                        show_cmd_suggestions = false;
                        _ = writeAll("^C\r\n");
                    } else {
                        quit = true;
                    }
                } else if (ch == 4) { // Ctrl+D
                    quit = true;
                } else if (ch == 21) { // Ctrl+U — clear line
                    input_buf.clearRetainingCapacity();
                    cursor = 0;
                    show_cmd_suggestions = false;
                    redrawInputLine(&input_buf, cursor);
                } else if (ch == 12) { // Ctrl+L — clear screen
                    _ = writeAll("\x1b[2J\x1b[H");
                    printWelcome(provider_name, model_label, agent_mode);
                } else if (ch >= 32 and ch < 127) {
                    _ = input_buf.insert(allocator, cursor, ch) catch {};
                    cursor += 1;
                    redrawInputLine(&input_buf, cursor);
                    // Show/update suggestions when typing /
                    if (input_buf.items.len > 0 and input_buf.items[0] == '/') {
                        if (!show_cmd_suggestions) {
                            show_cmd_suggestions = true;
                            cmd_suggestion_index = 0;
                        }
                        printCmdSuggestions(input_buf.items, cmd_suggestion_index);
                    } else {
                        if (show_cmd_suggestions) clearCmdSuggestions();
                        show_cmd_suggestions = false;
                    }
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

// printPrompt removed — was causing "jumping line" bug.
// redrawInputLine + redrawInputLineFull replace it.

fn redrawInputLine(input: *std.ArrayList(u8), cursor: usize) void {
    // Clear current line + redraw prompt + input.
    // \r = carriage return (col 0), \x1b[2K = erase entire line.
    // Then print prompt + input. Cursor goes to end naturally.
    // Do NOT emit \r\n — that would create a new line (the jumping bug).
    _ = writeAll("\r\x1b[2K> ");
    if (input.items.len > 0) {
        _ = writeAll(input.items);
    }
    // Position cursor left if not at end.
    if (cursor < input.items.len) {
        var move_buf: [16]u8 = undefined;
        const back = input.items.len - cursor;
        const move = std.fmt.bufPrint(&move_buf, "\x1b[{d}D", .{back}) catch "";
        _ = writeAll(move);
    }
}

/// Print a fresh prompt line (after welcome or after agent response).
/// This outputs the prompt on a NEW line — used only when we want a new
/// prompt to appear (not during typing).
fn redrawInputLineFull(provider: []const u8, model: []const u8, mode: ai.tools.Mode, input: *std.ArrayList(u8), cursor: usize, tokens: u64) void {
    _ = provider;
    _ = model;
    _ = tokens;
    _ = cursor;
    _ = input;
    // Just print the prompt prefix on current line.
    // After welcome's \r\n, cursor is at start of a new line.
    const mode_icon: u8 = switch (mode) {
        .ask => '?',
        .plan => '+',
        .agent => '>',
    };
    var icon_buf: [2]u8 = .{ mode_icon, ' ' };
    _ = writeAll(&icon_buf);
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

// ─── Slash command suggestion popup ────────────────────────────────────

const INLINE_COMMANDS = [_][]const u8{
    "/help",    "/exit",   "/clear", "/mode",    "/model",
    "/cost",    "/policy", "/tools", "/context", "/diff",
    "/review",  "/search", "/undo",  "/redo",    "/compact",
    "/version", "/stats",  "/save",  "/export",
};

fn printCmdSuggestions(input: []const u8, selected: usize) void {
    // Save cursor position, move to line below prompt.
    _ = writeAll("\x1b[s"); // save cursor
    _ = writeAll("\r\n"); // move to next line

    // Print matching commands.
    var shown: usize = 0;
    for (INLINE_COMMANDS) |cmd| {
        if (std.mem.startsWith(u8, cmd, input)) {
            if (shown == selected % @max(INLINE_COMMANDS.len, 1)) {
                _ = writeAll("\x1b[36m▶ ");
            } else {
                _ = writeAll("\x1b[90m  ");
            }
            _ = writeAll(cmd);
            _ = writeAll("  \x1b[0m");
            shown += 1;
            if (shown >= 8) break; // max 8 suggestions
        }
    }

    // If no matches, show hint.
    if (shown == 0) {
        _ = writeAll("\x1b[90m  (no matching commands)\x1b[0m");
    }

    // Restore cursor position.
    _ = writeAll("\x1b[u"); // restore cursor
}

fn clearCmdSuggestions() void {
    // Clear the suggestion line below the prompt.
    _ = writeAll("\x1b[s"); // save cursor
    _ = writeAll("\r\n"); // move down
    _ = writeAll("\x1b[2K"); // clear line
    _ = writeAll("\x1b[u"); // restore cursor
}

// ─── Model picker ──────────────────────────────────────────────────────

fn printModelPicker(selected: usize) void {
    // Clear screen and show model list.
    _ = writeAll("\r\x1b[2J\x1b[H");
    _ = writeAll("\x1b[1m\x1b[92m  Select Model\x1b[0m\r\n");
    _ = writeAll("\x1b[90m  ↑↓ navigate · Enter select · Esc cancel\x1b[0m\r\n\r\n");

    const models = ai.provider_capability.builtin_models;
    for (models, 0..) |m, i| {
        if (i == selected) {
            _ = writeAll("\x1b[36m▶ ");
        } else {
            _ = writeAll("\x1b[90m  ");
        }
        var buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{s: <10} {s: <36} ctx:{d}  ${d:.2}/${d:.2}\x1b[0m\r\n", .{
            m.provider,
            m.model_id,
            m.capability.max_context_tokens,
            @as(f64, @floatFromInt(m.capability.price_per_mtok_input)) / 100.0,
            @as(f64, @floatFromInt(m.capability.price_per_mtok_output)) / 100.0,
        }) catch "";
        _ = writeAll(line);
    }
}
