//! Inline mode — sequential output with native terminal scrollback.
//!
//! Simple, fast, native scroll. Like Aider: type request → get response.
//! No popups, no cursor positioning, no full-screen repaint.
//! Terminal handles all scrolling natively (GPU-accelerated).
//!
//! Usage: forge agent (default) or forge agent --tui (full TUI)

const std = @import("std");
const ai = @import("forge-ai");
const workspace = @import("forge-workspace");
const kernel = @import("forge-kernel");
const args_mod = @import("args.zig");
const workspace_cmd = @import("workspace_cmd.zig");
const ai_workflow = @import("ai_workflow.zig");
const cancel_scope_mod = @import("cancel_scope.zig");
const commands = @import("agent_tui/commands.zig");

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    parsed: args_mod.CliArgs,
) !u8 {
    var opened = workspace_cmd.OpenedWorkspace.open(allocator, io, parsed) catch {
        print("\x1b[91m✗ Cannot open workspace\x1b[0m\r\n");
        return 2;
    };
    defer opened.close(io);

    // Raw mode for input.
    const fd = std.posix.STDIN_FILENO;
    const saved = std.posix.tcgetattr(fd) catch {
        print("forge agent: not a TTY — use 'forge chat --pipe'\r\n");
        return 2;
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
    var total_tokens: u64 = 0;
    var quit = false;

    // Welcome
    printWelcome(provider_name, model_label, agent_mode);
    printPrompt(agent_mode);

    while (!quit) {
        var key_buf: [16]u8 = undefined;
        const n = std.posix.read(fd, &key_buf) catch break;
        if (n == 0) break;
        const k = parseKey(key_buf[0..n]);

        // Model picker mode
        if (agent_mode == .ask and false) {
            // reserved for future inline pickers
        }

        switch (k) {
            .enter => {
                print("\r\n");
                if (input_buf.items.len == 0) {
                    printPrompt(agent_mode);
                    continue;
                }
                // History
                const owned = allocator.dupe(u8, input_buf.items) catch continue;
                history.append(allocator, owned) catch {};
                history_pos = null;

                // Slash commands
                if (input_buf.items[0] == '/') {
                    const cmd = commands.parseSlashCommand(input_buf.items);
                    switch (cmd) {
                        .exit_app => quit = true,
                        .wipe_history => {
                            print("\x1b[2J\x1b[H");
                            printWelcome(provider_name, model_label, agent_mode);
                        },
                        .mode => |m| {
                            agent_mode = m;
                            var buf: [64]u8 = undefined;
                            print(std.fmt.bufPrint(&buf, "\x1b[92m  ✓ Mode: {s}\x1b[0m\r\n", .{commands.modeLabel(m)}) catch "");
                        },
                        .mode_cycle => {
                            agent_mode = switch (agent_mode) {
                                .ask => .plan,
                                .plan => .agent,
                                .agent => .ask,
                            };
                            var buf: [64]u8 = undefined;
                            print(std.fmt.bufPrint(&buf, "\x1b[92m  ✓ Mode: {s}\x1b[0m\r\n", .{commands.modeLabel(agent_mode)}) catch "");
                        },
                        .help => printHelp(),
                        .model_show => {
                            var buf: [128]u8 = undefined;
                            print(std.fmt.bufPrint(&buf, "\x1b[90m  {s}/{s} · {d} tokens used\x1b[0m\r\n", .{ provider_name, model_label, total_tokens }) catch "");
                        },
                        .model_set => {
                            printModelPicker();
                            // Read selection
                            while (true) {
                                var mk_buf: [16]u8 = undefined;
                                const mn = std.posix.read(fd, &mk_buf) catch break;
                                if (mn == 0) break;
                                var sel: usize = 0;
                                const models = ai.provider_capability.builtin_models;
                                var picking = true;
                                while (picking) {
                                    const mn2 = std.posix.read(fd, &mk_buf) catch break;
                                    if (mn2 == 0) break;
                                    switch (parseKey(mk_buf[0..mn2])) {
                                        .up => if (sel > 0) {
                                            sel -= 1;
                                        },
                                        .down => if (sel + 1 < models.len) {
                                            sel += 1;
                                        },
                                        .enter => {
                                            const m = models[sel];
                                            model_label = m.model_id;
                                            provider_name = m.provider;
                                            var buf: [128]u8 = undefined;
                                            print(std.fmt.bufPrint(&buf, "\r\x1b[2J\x1b[92m  ✓ Model: {s}/{s}\x1b[0m\r\n", .{ m.provider, m.model_id }) catch "");
                                            printWelcome(provider_name, model_label, agent_mode);
                                            picking = false;
                                        },
                                        .escape => {
                                            print("\r\x1b[2J\x1b[H");
                                            printWelcome(provider_name, model_label, agent_mode);
                                            picking = false;
                                        },
                                        else => {},
                                    }
                                    if (picking) printModelPickerSelected(sel);
                                }
                                break;
                            }
                        },
                        else => {
                            print("\x1b[90m  Use --tui for full command support\x1b[0m\r\n");
                        },
                    }
                    input_buf.clearRetainingCapacity();
                    cursor = 0;
                    printPrompt(agent_mode);
                    continue;
                }

                // Run agent
                const intent = allocator.dupe(u8, input_buf.items) catch continue;
                input_buf.clearRetainingCapacity();
                cursor = 0;

                runAgent(allocator, io, environ_map, parsed, &opened, intent, provider_name, &total_tokens) catch |err| {
                    var buf: [256]u8 = undefined;
                    print(std.fmt.bufPrint(&buf, "\x1b[91m  ✗ {}\x1b[0m\r\n", .{err}) catch "");
                };
                printPrompt(agent_mode);
            },
            .ctrl_c => {
                if (input_buf.items.len > 0) {
                    input_buf.clearRetainingCapacity();
                    cursor = 0;
                    print("^C\r\n");
                    printPrompt(agent_mode);
                } else {
                    quit = true;
                }
            },
            .backspace => {
                if (cursor > 0) {
                    _ = input_buf.orderedRemove(cursor - 1);
                    cursor -= 1;
                    print("\x1b[D\x1b[K");
                    if (cursor < input_buf.items.len) {
                        print(input_buf.items[cursor..]);
                        var buf: [16]u8 = undefined;
                        print(std.fmt.bufPrint(&buf, "\x1b[{d}D", .{input_buf.items.len - cursor}) catch "");
                    }
                }
            },
            .up => {
                if (history.items.len > 0) {
                    var pos = history_pos orelse history.items.len;
                    if (pos > 0) pos -= 1;
                    history_pos = pos;
                    input_buf.clearRetainingCapacity();
                    input_buf.appendSlice(allocator, history.items[pos]) catch {};
                    cursor = input_buf.items.len;
                    print("\r\x1b[K");
                    printPrompt(agent_mode);
                    print(input_buf.items);
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
                    print("\r\x1b[K");
                    printPrompt(agent_mode);
                    print(input_buf.items);
                }
            },
            .left => if (cursor > 0) {
                cursor -= 1;
                print("\x1b[D");
            },
            .right => if (cursor < input_buf.items.len) {
                cursor += 1;
                print("\x1b[C");
            },
            .char => |ch| {
                if (ch == 4) {
                    quit = true;
                } else if (ch == 21) { // Ctrl+U
                    input_buf.clearRetainingCapacity();
                    cursor = 0;
                    print("\r\x1b[K");
                    printPrompt(agent_mode);
                } else if (ch == 12) { // Ctrl+L
                    print("\x1b[2J\x1b[H");
                    printWelcome(provider_name, model_label, agent_mode);
                    printPrompt(agent_mode);
                    print(input_buf.items);
                } else if (ch >= 32 and ch < 127) {
                    _ = input_buf.insert(allocator, cursor, ch) catch {};
                    cursor += 1;
                    if (cursor == input_buf.items.len) {
                        // Echo single byte
                        var b: [1]u8 = .{ch};
                        print(&b);
                    } else {
                        // Redraw from cursor
                        print(input_buf.items[cursor - 1 ..]);
                        var buf: [16]u8 = undefined;
                        print(std.fmt.bufPrint(&buf, "\x1b[{d}D", .{input_buf.items.len - cursor}) catch "");
                    }
                }
            },
            .escape, .none => {},
        }
    }

    print("\r\n");
    return 0;
}

// ─── Agent execution ───────────────────────────────────────────────────

fn runAgent(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    parsed: args_mod.CliArgs,
    opened: *workspace_cmd.OpenedWorkspace,
    intent: []const u8,
    provider_name: []const u8,
    total_tokens: *u64,
) !void {
    // Progress indicator
    print("\x1b[90m  ⠹ Working...\r\x1b[0m");

    var scope = try cancel_scope_mod.Scope.init(allocator);
    defer scope.deinit();
    scope.installSigint();
    var cancel_token = scope.token();

    var provider_options = ai_workflow.agentProviderOptionsFromFlags(
        allocator,
        parsed.flags,
        "ask",
        io,
        opened.root,
    );
    defer provider_options.deinit(allocator);

    if (std.mem.eql(u8, provider_name, "fake")) {
        provider_options.options.provider_name = "fake";
    }

    const start_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();

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
        // Clear the Working... line
        print("\r\x1b[K");
        return err;
    };
    defer allocator.free(generated.run_id);
    defer allocator.free(generated.proposal_rel);

    const elapsed_ms = std.Io.Timestamp.now(io, .real).toMilliseconds() - start_ms;
    const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;

    // Clear Working... line
    print("\r\x1b[K");

    // Result summary
    var buf: [512]u8 = undefined;
    const summary = std.fmt.bufPrint(&buf, "\x1b[92m  ✓ Done\x1b[0m \x1b[90m· {d:.1}s · {d} tok\x1b[0m\r\n", .{ elapsed_s, intent.len / 4 + 100 }) catch "";
    print(summary);

    // Proposal
    const prop = std.fmt.bufPrint(&buf, "\x1b[33m  📄 {s}\x1b[0m\r\n", .{generated.proposal_rel}) catch "";
    print(prop);
    const hint = std.fmt.bufPrint(&buf, "\x1b[90m  forge diff {s}  ·  forge apply {s} --yes\x1b[0m\r\n", .{ generated.proposal_rel, generated.proposal_rel }) catch "";
    print(hint);

    total_tokens.* += intent.len / 4 + 100;
}

// ─── UI helpers ────────────────────────────────────────────────────────

fn printWelcome(provider: []const u8, model: []const u8, mode: ai.tools.Mode) void {
    print("\r\n");
    print("\x1b[1m\x1b[92m  ✨ Forge AI\x1b[0m\r\n");
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "\x1b[90m  {s}/{s} · {s} · /help for commands\x1b[0m\r\n\r\n", .{ provider, model, commands.modeLabel(mode) }) catch "";
    print(line);
}

fn printPrompt(mode: ai.tools.Mode) void {
    const icon: u8 = switch (mode) {
        .ask => '?',
        .plan => '+',
        .agent => '>',
    };
    var buf: [4]u8 = .{ ' ', icon, ' ', 0 };
    _ = writeAll(buf[0..3]);
}

fn printHelp() void {
    print("\r\n");
    print("\x1b[1m  Commands\x1b[0m\r\n");
    print("\r\n");
    print("  /exit          Quit\r\n");
    print("  /clear         Clear screen\r\n");
    print("  /mode          Cycle mode (ask → plan → agent)\r\n");
    print("  /mode <name>   Set mode directly\r\n");
    print("  /model         Pick model (arrow keys + Enter)\r\n");
    print("  /help          This help\r\n");
    print("\r\n");
    print("\x1b[90m  Full TUI: forge agent --tui\x1b[0m\r\n\r\n");
}

fn printModelPicker() void {
    print("\r\x1b[2J\x1b[H");
    print("\x1b[1m\x1b[92m  Select Model\x1b[0m\r\n");
    print("\x1b[90m  ↑↓ navigate · Enter select · Esc cancel\x1b[0m\r\n\r\n");
    const models = ai.provider_capability.builtin_models;
    for (models, 0..) |m, i| {
        var buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "\x1b[90m  {s}/{s}\x1b[0m\r\n", .{ m.provider, m.model_id }) catch "";
        print(line);
        _ = i;
    }
    printModelPickerSelected(0);
}

fn printModelPickerSelected(sel: usize) void {
    print("\r\x1b[H\r\n\r\n"); // back to model list start
    const models = ai.provider_capability.builtin_models;
    for (models, 0..) |m, i| {
        if (i == sel) {
            var buf: [128]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "\r\x1b[K\x1b[36m▶ {s}/{s}\x1b[0m", .{ m.provider, m.model_id }) catch "";
            print(line);
        } else {
            var buf: [128]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "\r\x1b[K\x1b[90m  {s}/{s}\x1b[0m", .{ m.provider, m.model_id }) catch "";
            print(line);
        }
        print("\r\n");
    }
}

// ─── Key parsing ───────────────────────────────────────────────────────

const Key = union(enum) {
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

fn parseKey(buf: []const u8) Key {
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

// ─── Output ────────────────────────────────────────────────────────────

fn writeAll(bytes: []const u8) void {
    var index: usize = 0;
    while (index < bytes.len) {
        const n = std.c.write(std.posix.STDOUT_FILENO, bytes.ptr + index, bytes.len - index);
        if (n <= 0) break;
        index += @intCast(n);
    }
}

fn print(s: []const u8) void {
    writeAll(s);
}
