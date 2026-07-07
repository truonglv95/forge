const std = @import("std");
const builtin = @import("builtin");
const ai = @import("forge-ai");
const workspace = @import("forge-workspace");
const forge_util = @import("forge-util");
const args_mod = @import("../args.zig");
const workspace_cmd = @import("../workspace_cmd.zig");
const ai_workflow = @import("../ai_workflow.zig");
const cancel_scope_mod = @import("../cancel_scope.zig");
const term = @import("term.zig");
const commands = @import("commands.zig");

pub const ToolRunPolicy = enum {
    run_everything,
    ask_each_time,
    agent_default,

    pub fn label(self: ToolRunPolicy) []const u8 {
        return switch (self) {
            .run_everything => "Run everything",
            .ask_each_time => "Ask each time",
            .agent_default => "Agent default",
        };
    }

    pub fn next(self: ToolRunPolicy) ToolRunPolicy {
        return switch (self) {
            .run_everything => .ask_each_time,
            .ask_each_time => .agent_default,
            .agent_default => .run_everything,
        };
    }
};

const LineKind = enum {
    user,
    agent,
    tool,
    system,
    failure,
};

const ChatLine = struct {
    kind: LineKind,
    text: []u8,
};

const ApprovalGate = struct {
    mutex: forge_util.sync.Mutex = .{},
    cond: forge_util.sync.Condition = .{},
    pending: bool = false,
    decided: bool = false,
    approved: bool = false,
    tool_name: [96]u8 = undefined,
    tool_name_len: usize = 0,
    args_preview: [384]u8 = undefined,
    args_preview_len: usize = 0,
    risk: ai.tool_registry.Risk = .low,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    opened: workspace_cmd.OpenedWorkspace,
    parsed: args_mod.CliArgs,
    term: term.Terminal,
    cancel_scope: cancel_scope_mod.Scope,

    mutex: forge_util.sync.Mutex = .{},
    lines: std.ArrayList(ChatLine) = .empty,
    conversation: std.ArrayList(ai.conversation.Turn) = .empty,
    input: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    history: std.ArrayList([]const u8) = .empty,
    history_pos: ?usize = null,
    scroll: usize = 0,
    events_scroll: usize = 0,
    agent_busy: bool = false,
    quit: bool = false,
    tool_policy: ToolRunPolicy = .agent_default,
    focus_action: bool = false,

    model_label: []const u8 = &.{},
    context_label: []const u8 = &.{},
    edited_label: []const u8 = &.{},
    folder_label: []const u8 = &.{},
    branch_label: []const u8 = &.{},

    approval: ApprovalGate = .{},
    worker: ?std.Thread = null,
    worker_err: ?[]const u8 = null,
    frame: term.FrameBuffer = undefined,
    dirty: bool = true,
    last_render_ms: i64 = 0,
    stream_line_index: ?usize = null,
    pending_proposal: ?[]u8 = null,
    cancel_armed: bool = false,
    session_files: std.ArrayList([]const u8) = .empty,
    agent_mode: ai.tools.Mode = .agent,
    resume_session_id: ?[]u8 = null,
    last_session_id: ?[]u8 = null,
    show_events: bool = false,
    events_lines: std.ArrayList(ChatLine) = .empty,
    terminal_size: term.Terminal.Size = .{ .rows = 25, .cols = 80 },
    active_tool: [96]u8 = undefined,
    active_tool_len: usize = 0,
    active_tool_running: bool = false,
    last_tool_review: ?[]u8 = null,
    last_tool_review_kind: ?[]u8 = null,
    command_index: usize = 0,

    const ALL_COMMANDS = [_][]const u8{ "/clear", "/policy", "/mode", "/context", "/diff", "/events", "/resume", "/sessions", "/help", "/quit" };

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ_map: ?*const std.process.Environ.Map,
        opened: workspace_cmd.OpenedWorkspace,
        parsed: args_mod.CliArgs,
        terminal: term.Terminal,
        cancel_scope: cancel_scope_mod.Scope,
    ) !App {
        const provider_opts = ai_workflow.agentProviderOptionsFromFlags(parsed.flags, "interactive");
        const model = try std.fmt.allocPrint(allocator, "{s}/{s}", .{
            @tagName(provider_opts.kind),
            parsed.flags.model orelse defaultModel(provider_opts.kind),
        });

        const folder = try std.fmt.allocPrint(allocator, "{s}", .{opened.path});

        var app = App{
            .allocator = allocator,
            .io = io,
            .environ_map = environ_map,
            .opened = opened,
            .parsed = parsed,
            .term = terminal,
            .cancel_scope = cancel_scope,
            .model_label = model,
            .context_label = try allocator.dupe(u8, "0 files"),
            .edited_label = try allocator.dupe(u8, "0 edited"),
            .folder_label = folder,
            .branch_label = try allocator.dupe(u8, "no branch"),
            .frame = term.FrameBuffer.init(allocator),
        };
        try app.refreshStatus();
        app.terminal_size = terminal.size();
        if (parsed.flags.mode) |mode_name| {
            if (commands.parseModeName(mode_name)) |mode| app.agent_mode = mode;
        }
        return app;
    }

    pub fn deinit(self: *App) void {
        if (self.worker) |thread| thread.join();
        self.freeLines();
        self.freeEventsLines();
        self.input.deinit(self.allocator);
        for (self.conversation.items) |turn| self.allocator.free(turn.content);
        self.conversation.deinit(self.allocator);
        for (self.history.items) |item| self.allocator.free(item);
        self.history.deinit(self.allocator);
        for (self.session_files.items) |item| self.allocator.free(item);
        self.session_files.deinit(self.allocator);
        self.allocator.free(self.model_label);
        self.allocator.free(self.context_label);
        self.allocator.free(self.edited_label);
        self.allocator.free(self.folder_label);
        self.allocator.free(self.branch_label);
        if (self.worker_err) |msg| self.allocator.free(msg);
        if (self.pending_proposal) |prop| self.allocator.free(prop);
        if (self.resume_session_id) |id| self.allocator.free(id);
        if (self.last_session_id) |id| self.allocator.free(id);
        if (self.last_tool_review) |text| self.allocator.free(text);
        if (self.last_tool_review_kind) |kind| self.allocator.free(kind);
        self.frame.deinit();
        self.approval.cond.deinit();
        self.approval.mutex.deinit();
        self.mutex.deinit();
    }

    pub fn run(self: *App) !u8 {
        self.cancel_scope.installSigint();
        while (!self.quit) {
            if (self.term.sizeChanged(self.terminal_size)) {
                self.terminal_size = self.term.size();
                self.markDirty();
            }

            const now = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
            self.mutex.lock();
            const busy = self.agent_busy;
            const should_render = self.dirty or (busy and now - self.last_render_ms >= 33);
            if (should_render) {
                self.render();
                self.dirty = false;
                self.last_render_ms = now;
            }
            self.mutex.unlock();

            if (busy) {
                self.handleApprovalInput();
                term.sleepMs(16);
                continue;
            }

            const key = self.term.readKey() catch break;
            if (key == .none) continue;
            try self.handleKey(key);
        }
        return 0;
    }

    fn markDirty(self: *App) void {
        self.dirty = true;
    }

    fn getFilteredCommands(self: *App, out: *[ALL_COMMANDS.len][]const u8) usize {
        var len: usize = 0;
        const input_text = self.input.items;
        for (ALL_COMMANDS) |cmd| {
            if (std.mem.startsWith(u8, cmd, input_text)) {
                out[len] = cmd;
                len += 1;
            }
        }
        if (len == 0) {
            for (ALL_COMMANDS) |cmd| {
                out[len] = cmd;
                len += 1;
            }
        }
        return len;
    }

    fn applyCommandSuggestion(self: *App) void {
        var filtered: [ALL_COMMANDS.len][]const u8 = undefined;
        const len = self.getFilteredCommands(&filtered);
        if (len > 0) {
            const idx = if (self.command_index < len) self.command_index else 0;
            const chosen = filtered[idx];
            self.input.clearRetainingCapacity();
            self.input.appendSlice(self.allocator, chosen) catch return;
            if (std.mem.eql(u8, chosen, "/mode") or std.mem.eql(u8, chosen, "/resume")) {
                self.input.append(self.allocator, ' ') catch return;
            }
            self.cursor = self.input.items.len;
            self.command_index = 0;
        }
    }

    fn handleKey(self: *App, key: term.Key) !void {
        switch (key) {
            .ctrl_c, .ctrl_d => {
                if (self.agent_busy) {
                    self.cancel_scope.cancel();
                    try self.pushSystem("Cancelling agent... (Ctrl+C again to quit)");
                } else if (!self.cancel_armed) {
                    self.cancel_armed = true;
                    try self.pushSystem("Press Ctrl+C again to quit");
                } else {
                    self.quit = true;
                }
            },
            .ctrl_l => {
                self.mutex.lock();
                self.freeLines();
                self.scroll = 0;
                self.markDirty();
                self.mutex.unlock();
            },
            .ctrl_m => {
                self.mutex.lock();
                self.agent_mode = commands.nextMode(self.agent_mode);
                self.markDirty();
                self.mutex.unlock();
                var buf: [64]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Mode: {s}", .{commands.modeLabel(self.agent_mode)}) catch return;
                try self.pushSystem(msg);
            },
            .tab => {
                self.mutex.lock();
                if (self.input.items.len > 0 and self.input.items[0] == '/') {
                    self.applyCommandSuggestion();
                    self.markDirty();
                } else {
                    if (self.focus_action) {
                        self.tool_policy = self.tool_policy.next();
                    } else {
                        self.focus_action = true;
                    }
                    self.markDirty();
                }
                self.mutex.unlock();
            },
            .escape => {
                self.mutex.lock();
                if (self.show_events) self.show_events = false;
                self.focus_action = false;
                self.markDirty();
                self.mutex.unlock();
            },
            .enter => {
                self.mutex.lock();
                const is_cmd = self.input.items.len > 0 and self.input.items[0] == '/';
                const has_space = std.mem.indexOfScalar(u8, self.input.items, ' ') != null;
                if (is_cmd and !has_space) {
                    var filtered: [ALL_COMMANDS.len][]const u8 = undefined;
                    const len = self.getFilteredCommands(&filtered);
                    if (len > 0) {
                        const idx = if (self.command_index < len) self.command_index else 0;
                        const chosen = filtered[idx];
                        if (std.mem.startsWith(u8, chosen, self.input.items)) {
                            self.input.clearRetainingCapacity();
                            self.input.appendSlice(self.allocator, chosen) catch {};
                        }
                    }
                }
                self.mutex.unlock();
                try self.submitInput();
            },
            .backspace => {
                self.mutex.lock();
                if (self.cursor > 0) {
                    _ = self.input.orderedRemove(self.cursor - 1);
                    self.cursor -= 1;
                }
                self.markDirty();
                self.mutex.unlock();
            },
            .delete => {
                self.mutex.lock();
                if (self.cursor < self.input.items.len) {
                    _ = self.input.orderedRemove(self.cursor);
                }
                self.markDirty();
                self.mutex.unlock();
            },
            .left => {
                self.mutex.lock();
                if (self.cursor > 0) self.cursor -= 1 else self.focus_action = false;
                self.markDirty();
                self.mutex.unlock();
            },
            .right => {
                self.mutex.lock();
                if (self.cursor < self.input.items.len) {
                    self.cursor += 1;
                } else {
                    self.focus_action = true;
                }
                self.markDirty();
                self.mutex.unlock();
            },
            .home, .ctrl_a => {
                self.mutex.lock();
                if (self.input.items.len == 0) {
                    self.scrollChatToTop();
                } else {
                    self.cursor = 0;
                }
                self.markDirty();
                self.mutex.unlock();
            },
            .end, .ctrl_e => {
                self.mutex.lock();
                if (self.input.items.len == 0) {
                    self.scroll = 0;
                } else {
                    self.cursor = self.input.items.len;
                }
                self.markDirty();
                self.mutex.unlock();
            },
            .ctrl_u => {
                self.mutex.lock();
                self.input.clearRetainingCapacity();
                self.cursor = 0;
                self.markDirty();
                self.mutex.unlock();
            },
            .ctrl_r => try self.showLastToolReview(),
            .ctrl_w => {
                self.mutex.lock();
                self.deleteWordBackward();
                self.markDirty();
                self.mutex.unlock();
            },
            .up => {
                self.mutex.lock();
                if (self.input.items.len > 0 and self.input.items[0] == '/') {
                    var filtered: [ALL_COMMANDS.len][]const u8 = undefined;
                    const len = self.getFilteredCommands(&filtered);
                    if (len > 0) {
                        if (self.command_index > 0) {
                            self.command_index -= 1;
                        } else {
                            self.command_index = len - 1;
                        }
                        self.markDirty();
                    }
                } else {
                    self.mutex.unlock();
                    self.recallHistory(-1);
                    return;
                }
                self.mutex.unlock();
            },
            .down => {
                self.mutex.lock();
                if (self.input.items.len > 0 and self.input.items[0] == '/') {
                    var filtered: [ALL_COMMANDS.len][]const u8 = undefined;
                    const len = self.getFilteredCommands(&filtered);
                    if (len > 0) {
                        if (self.command_index + 1 < len) {
                            self.command_index += 1;
                        } else {
                            self.command_index = 0;
                        }
                        self.markDirty();
                    }
                } else {
                    self.mutex.unlock();
                    self.recallHistory(1);
                    return;
                }
                self.mutex.unlock();
            },
            .page_up => self.scrollChatPage(1),
            .page_down => self.scrollChatPage(-1),
            .char => |ch| {
                if (self.agent_busy) return;
                if (self.tryProposalShortcut(ch)) return;
                if (ch >= 32 and ch < 127) {
                    self.mutex.lock();
                    self.cancel_armed = false;
                    self.input.insert(self.allocator, self.cursor, ch) catch {};
                    self.cursor += 1;
                    self.markDirty();
                    self.mutex.unlock();
                }
            },
            else => {},
        }
    }

    /// d/a/n act on a pending proposal only when the input line is empty,
    /// so typing those letters into a message still works normally.
    fn tryProposalShortcut(self: *App, ch: u8) bool {
        self.mutex.lock();
        const has_proposal = self.pending_proposal != null;
        const input_empty = self.input.items.len == 0;
        self.mutex.unlock();
        if (!has_proposal or !input_empty) return false;
        switch (ch) {
            'd', 'D' => {
                self.showProposalDiff() catch {};
                return true;
            },
            'a', 'A' => {
                self.applyPendingProposal() catch {};
                return true;
            },
            'n', 'N' => {
                self.dismissPendingProposal();
                return true;
            },
            else => return false,
        }
    }

    fn scrollChatPage(self: *App, direction: i32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const chat_rows = self.chatRowCount();
        const page = @max(1, chat_rows);
        if (direction > 0) {
            self.scroll +|= page;
        } else if (self.scroll > page) {
            self.scroll -= page;
        } else {
            self.scroll = 0;
        }
        self.markDirty();
    }

    fn scrollChatToTop(self: *App) void {
        self.scroll = std.math.maxInt(usize);
        self.markDirty();
    }

    fn chatRowCount(self: *const App) usize {
        const footer_rows: u16 = 4;
        if (self.terminal_size.rows <= footer_rows + 2) return 1;
        return self.terminal_size.rows - footer_rows;
    }

    fn deleteWordBackward(self: *App) void {
        while (self.cursor > 0 and self.input.items[self.cursor - 1] == ' ') {
            _ = self.input.orderedRemove(self.cursor - 1);
            self.cursor -= 1;
        }
        while (self.cursor > 0 and self.input.items[self.cursor - 1] != ' ') {
            _ = self.input.orderedRemove(self.cursor - 1);
            self.cursor -= 1;
        }
    }

    fn recallHistory(self: *App, direction: i32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.input.items.len > 0 or self.scroll > 0) {
            if (direction < 0) self.scrollChatPageLocked(1) else if (self.scroll > 0) self.scrollChatPageLocked(-1);
            return;
        }
        if (self.history.items.len == 0) return;
        const len = self.history.items.len;
        var pos = self.history_pos orelse len;
        if (direction < 0) {
            if (pos > 0) pos -= 1;
        } else {
            if (pos < len) pos += 1;
        }
        self.history_pos = pos;
        self.input.clearRetainingCapacity();
        if (pos < len) {
            self.input.appendSlice(self.allocator, self.history.items[pos]) catch {};
        }
        self.cursor = self.input.items.len;
        self.markDirty();
    }

    fn scrollChatPageLocked(self: *App, direction: i32) void {
        const page = @max(1, self.chatRowCount());
        if (direction > 0) {
            self.scroll +|= page;
        } else if (self.scroll > page) {
            self.scroll -= page;
        } else {
            self.scroll = 0;
        }
        self.markDirty();
    }

    fn handleApprovalInput(self: *App) void {
        self.approval.mutex.lock();
        const pending = self.approval.pending;
        self.approval.mutex.unlock();
        if (!pending) return;

        const key = self.term.readKey() catch return;
        switch (key) {
            .char => |ch| {
                if (ch == 'y' or ch == 'Y') self.resolveApproval(true);
                if (ch == 'n' or ch == 'N') self.resolveApproval(false);
            },
            .enter => self.resolveApproval(true),
            .escape => self.resolveApproval(false),
            else => {},
        }
    }

    fn resolveApproval(self: *App, approved: bool) void {
        self.approval.mutex.lock();
        if (self.approval.pending) {
            self.approval.approved = approved;
            self.approval.decided = true;
            self.approval.pending = false;
            self.approval.cond.signal();
        }
        self.approval.mutex.unlock();
    }

    fn submitInput(self: *App) !void {
        self.mutex.lock();
        if (self.agent_busy or self.input.items.len == 0) {
            self.mutex.unlock();
            return;
        }
        const raw = try self.allocator.dupe(u8, self.input.items);
        self.input.clearRetainingCapacity();
        self.cursor = 0;
        self.history_pos = null;
        self.history.append(self.allocator, self.allocator.dupe(u8, raw) catch raw) catch {};
        self.mutex.unlock();

        const cmd = commands.parseSlashCommand(raw);
        if (cmd != .not_command) {
            self.allocator.free(raw);
            try self.dispatchCommand(cmd);
            return;
        }

        try self.extractFileMentions(raw);

        try self.pushLine(.user, raw);
        const intent = try self.allocator.dupe(u8, raw);
        try self.startAgent(intent, null);
    }

    fn dispatchCommand(self: *App, cmd: commands.Command) !void {
        switch (cmd) {
            .not_command => {},
            .wipe_history => {
                self.mutex.lock();
                self.freeLines();
                self.scroll = 0;
                self.markDirty();
                self.mutex.unlock();
            },
            .policy => {
                self.mutex.lock();
                self.tool_policy = self.tool_policy.next();
                const label = self.tool_policy.label();
                self.markDirty();
                self.mutex.unlock();
                var buf: [96]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Tool policy: {s}", .{label}) catch return;
                try self.pushSystem(msg);
            },
            .mode => |mode| try self.setAgentMode(mode),
            .mode_cycle => try self.setAgentMode(commands.nextMode(self.agent_mode)),
            .context => try self.showContextManifest(),
            .diff => try self.showProposalDiff(),
            .help => try self.pushSystem(commands.helpText()),
            .exit_app => self.quit = true,
            .sessions => try self.listSessions(),
            .resume_session => |session_id| try self.resumeSession(session_id),
            .events => |session_id| try self.showEvents(session_id),
        }
    }

    fn setAgentMode(self: *App, mode: ai.tools.Mode) !void {
        self.mutex.lock();
        self.agent_mode = mode;
        self.markDirty();
        self.mutex.unlock();
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Mode: {s}", .{commands.modeLabel(mode)}) catch return;
        try self.pushSystem(msg);
    }

    fn showContextManifest(self: *App) !void {
        const explicit = self.explicitFilesSnapshot();
        defer {
            for (explicit) |f| self.allocator.free(f);
            if (explicit.len > 0) self.allocator.free(explicit);
        }

        const mode = self.agent_mode;
        const route = ai.routing.plan(.{
            .mode = mode,
            .intent = "",
            .has_active_file = self.parsed.flags.files.len > 0,
        }, .{
            .intent = null,
            .explicit_files = explicit,
            .max_bytes = if (self.parsed.flags.budget_bytes > 0) self.parsed.flags.budget_bytes else 1024 * 1024,
            .workspace_cwd = self.opened.path,
        });

        var ctx_builder = try ai.context_loader.build(self.allocator, self.io, self.opened.root, route.context);
        defer ctx_builder.deinit();

        var out = std.Io.Writer.Allocating.init(self.allocator);
        defer out.deinit();
        try ai.context_loader.renderManifestHuman(&ctx_builder, &out.writer);
        try self.pushSystem("--- context manifest ---");
        var lines = std.mem.splitScalar(u8, out.writer.buffered(), '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            try self.pushLine(.system, try self.allocator.dupe(u8, line));
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        const kb = ctx_builder.used_bytes / 1024;
        var label_buf: [128]u8 = undefined;
        const label = std.fmt.bufPrint(
            &label_buf,
            "{d} blocks {d}kB",
            .{ ctx_builder.blocks.items.len, kb },
        ) catch return;
        const owned = self.allocator.dupe(u8, label) catch return;
        self.allocator.free(self.context_label);
        self.context_label = owned;
        self.markDirty();
    }

    fn listSessions(self: *App) !void {
        var list = try workspace.sessions.listEntries(self.allocator, self.io, self.opened.root);
        defer list.deinit();
        if (list.items.len == 0) {
            try self.pushSystem("No saved sessions");
            return;
        }
        try self.pushSystem("Sessions (newest last):");
        for (list.items) |entry| {
            var buf: [512]u8 = undefined;
            const line = std.fmt.bufPrint(
                &buf,
                "  {s}  \"{s}\"  ({d})",
                .{ entry.session_id, entry.intent, entry.timestamp_ms },
            ) catch continue;
            try self.pushLine(.system, try self.allocator.dupe(u8, line));
        }
        try self.pushSystem("Use /resume <session_id> to load");
    }

    fn resumeSession(self: *App, session_id_opt: ?[]const u8) !void {
        const session_id = blk: {
            if (session_id_opt) |id| break :blk try self.allocator.dupe(u8, id);
            var list = try workspace.sessions.listEntries(self.allocator, self.io, self.opened.root);
            defer list.deinit();
            if (list.items.len == 0) {
                try self.pushSystem("No sessions to resume");
                return;
            }
            const latest = list.items[list.items.len - 1];
            break :blk try self.allocator.dupe(u8, latest.session_id);
        };
        defer self.allocator.free(session_id);

        var doc = workspace.sessions.loadSession(self.allocator, self.io, self.opened.root, session_id) catch |err| {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Resume failed: {s}", .{@errorName(err)}) catch "Resume failed";
            try self.pushSystem(msg);
            return;
        };
        defer workspace.sessions.deinitSession(self.allocator, &doc);

        self.mutex.lock();
        self.freeLines();
        for (self.conversation.items) |turn| self.allocator.free(turn.content);
        self.conversation.clearRetainingCapacity();
        if (self.resume_session_id) |old| self.allocator.free(old);
        self.resume_session_id = self.allocator.dupe(u8, doc.session_id) catch null;
        self.scroll = 0;
        self.mutex.unlock();

        const intent_owned = try self.allocator.dupe(u8, doc.intent);
        try self.pushLine(.user, intent_owned);
        try self.appendConversation(.user, doc.intent);

        for (doc.steps) |step| {
            var buf: [1024]u8 = undefined;
            const clipped = if (step.summary.len > 700) step.summary[0..700] else step.summary;
            const line = std.fmt.bufPrint(&buf, "step {d}: [{s}] {s}", .{ step.index, step.kind, clipped }) catch continue;
            try self.pushLine(.tool, try self.allocator.dupe(u8, line));
        }

        if (doc.proposal_path.len > 0) {
            try self.setPendingProposal(doc.proposal_path);
        }

        var msg_buf: [256]u8 = undefined;
        const loaded = std.fmt.bufPrint(
            &msg_buf,
            "Loaded session {s} [{s}]",
            .{ doc.session_id, doc.execution_state },
        ) catch return;
        try self.pushSystem(loaded);

        if (workspace.sessions.isResumableExecutionState(doc.execution_state)) {
            try self.pushSystem("Resuming interrupted agent...");
            const intent = try self.allocator.dupe(u8, doc.intent);
            try self.startAgent(intent, doc.session_id);
        }
    }

    /// Parse @path tokens and register them as explicit context files, like the
    /// IDE scope picker. Non-@ words stay part of the intent.
    fn extractFileMentions(self: *App, text: []const u8) !void {
        var it = std.mem.tokenizeScalar(u8, text, ' ');
        while (it.next()) |token| {
            if (token.len < 2 or token[0] != '@') continue;
            const path = token[1..];
            var already = false;
            self.mutex.lock();
            for (self.session_files.items) |existing| {
                if (std.mem.eql(u8, existing, path)) already = true;
            }
            if (!already) {
                const owned = self.allocator.dupe(u8, path) catch {
                    self.mutex.unlock();
                    continue;
                };
                self.session_files.append(self.allocator, owned) catch {};
            }
            self.mutex.unlock();
            if (!already) {
                var buf: [512]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "+ context: @{s}", .{path}) catch continue;
                try self.pushLine(.system, try self.allocator.dupe(u8, msg));
            }
        }
    }

    fn explicitFilesSnapshot(self: *App) [][]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const base = self.parsed.flags.files;
        const total = base.len + self.session_files.items.len;
        if (total == 0) return &.{};
        const out = self.allocator.alloc([]const u8, total) catch return &.{};
        var i: usize = 0;
        for (base) |f| {
            out[i] = self.allocator.dupe(u8, f) catch "";
            i += 1;
        }
        for (self.session_files.items) |f| {
            out[i] = self.allocator.dupe(u8, f) catch "";
            i += 1;
        }
        return out;
    }

    fn startAgent(self: *App, intent: []const u8, resume_id: ?[]const u8) !void {
        const ctx = try self.allocator.create(WorkerCtx);
        ctx.* = .{
            .app = self,
            .intent = intent,
            .resume_session_id = if (resume_id) |id| self.allocator.dupe(u8, id) catch null else null,
        };

        self.mutex.lock();
        self.agent_busy = true;
        self.stream_line_index = null;
        self.markDirty();
        self.mutex.unlock();

        self.worker = try std.Thread.spawn(.{}, workerMain, .{ctx});
    }

    fn workerDone(self: *App, ctx: *WorkerCtx, result: WorkerResult) void {
        self.allocator.free(ctx.intent);
        self.allocator.destroy(ctx);

        self.mutex.lock();
        self.agent_busy = false;
        self.worker = null;
        self.markDirty();
        self.mutex.unlock();

        switch (result) {
            .ok => |payload| {
                self.mutex.lock();
                if (self.last_session_id) |old| self.allocator.free(old);
                if (payload.session_id.len > 0) {
                    self.last_session_id = self.allocator.dupe(u8, payload.session_id) catch null;
                } else {
                    self.last_session_id = null;
                }
                self.mutex.unlock();
                if (payload.response_text) |text| {
                    self.finalizeStreamedResponse(text) catch {};
                    self.appendConversation(.agent, text) catch {};
                }
                if (payload.proposal_rel) |prop| {
                    self.setPendingProposal(prop) catch {};
                }
                payload.deinit(self.allocator);
            },
            .err => |message| {
                self.pushLine(.failure, message) catch {
                    self.allocator.free(message);
                };
            },
        }
        self.refreshStatus() catch {};
    }

    fn appendConversation(self: *App, role: ai.conversation.Role, content: []const u8) !void {
        const owned = try self.allocator.dupe(u8, content);
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.conversation.append(self.allocator, .{ .role = role, .content = owned });
    }

    fn pushLine(self: *App, kind: LineKind, text: []u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.lines.append(self.allocator, .{ .kind = kind, .text = text });
        self.scroll = std.math.maxInt(usize);
        self.markDirty();
    }

    fn finalizeStreamedResponse(self: *App, text: []const u8) !void {
        const owned = try self.allocator.dupe(u8, text);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stream_line_index) |idx| {
            if (idx < self.lines.items.len) {
                self.allocator.free(self.lines.items[idx].text);
                self.lines.items[idx].text = owned;
                self.lines.items[idx].kind = .agent;
            } else {
                self.allocator.free(owned);
            }
            self.stream_line_index = null;
        } else {
            try self.lines.append(self.allocator, .{ .kind = .agent, .text = owned });
            self.scroll = std.math.maxInt(usize);
        }
        self.markDirty();
    }

    fn onStreamChunk(self: *App, chunk: []const u8) void {
        if (chunk.len == 0) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stream_line_index) |idx| {
            if (idx < self.lines.items.len) {
                const line = &self.lines.items[idx];
                const new_len = line.text.len + chunk.len;
                const grown = self.allocator.realloc(line.text, new_len) catch return;
                @memcpy(grown[line.text.len..], chunk);
                line.text = grown;
                self.markDirty();
                return;
            }
        }
        const owned = self.allocator.dupe(u8, chunk) catch return;
        self.lines.append(self.allocator, .{ .kind = .agent, .text = owned }) catch {
            self.allocator.free(owned);
            return;
        };
        self.stream_line_index = self.lines.items.len - 1;
        self.scroll = std.math.maxInt(usize);
        self.markDirty();
    }

    fn setPendingProposal(self: *App, prop: []const u8) !void {
        const owned = try self.allocator.dupe(u8, prop);
        self.mutex.lock();
        if (self.pending_proposal) |old| self.allocator.free(old);
        self.pending_proposal = owned;
        self.mutex.unlock();
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "Proposal ready: {s} — press d=diff, a=apply, n=dismiss",
            .{prop},
        );
        try self.pushLine(.system, msg);
    }

    fn dismissPendingProposal(self: *App) void {
        self.mutex.lock();
        if (self.pending_proposal) |prop| {
            self.allocator.free(prop);
            self.pending_proposal = null;
        }
        self.mutex.unlock();
        self.pushSystem("Proposal dismissed") catch {};
    }

    fn showProposalDiff(self: *App) !void {
        const prop_rel = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            break :blk if (self.pending_proposal) |prop| prop else return;
        };

        var proposal = try workspace_cmd.loadProposal(self.allocator, self.io, self.opened, prop_rel);
        defer proposal.deinit();
        const edit = proposal.workspaceEdit();
        try edit.validate();

        var out = std.Io.Writer.Allocating.init(self.allocator);
        defer out.deinit();
        try workspace.preview.renderDiff(self.allocator, self.io, self.opened.root, edit, &out.writer);
        try self.pushSystem("--- diff preview ---");
        var lines = std.mem.splitScalar(u8, out.writer.buffered(), '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            try self.pushLine(.system, try self.allocator.dupe(u8, line));
        }
    }

    const EventsQuery = struct {
        session_id: ?[]const u8 = null,
        tail: usize = 0,
        type_filter: ?[]const u8 = null,
    };

    fn parseEventsArgs(args: ?[]const u8) EventsQuery {
        var query = EventsQuery{};
        const raw = args orelse return query;
        var it = std.mem.tokenizeScalar(u8, raw, ' ');
        while (it.next()) |token| {
            if (std.mem.eql(u8, token, "--tail")) {
                if (it.next()) |value| query.tail = std.fmt.parseInt(usize, value, 10) catch 0;
            } else if (std.mem.eql(u8, token, "--type")) {
                if (it.next()) |value| query.type_filter = value;
            } else if (!std.mem.startsWith(u8, token, "-") and query.session_id == null) {
                query.session_id = token;
            }
        }
        return query;
    }

    fn showEvents(self: *App, args: ?[]const u8) !void {
        const query = parseEventsArgs(args);

        // Toggle off when already showing and no explicit args were given.
        if (args == null and self.show_events) {
            self.mutex.lock();
            self.show_events = false;
            self.markDirty();
            self.mutex.unlock();
            return;
        }

        const session_id = blk: {
            if (query.session_id) |id| break :blk id;
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.last_session_id) |id| break :blk id;
            if (self.resume_session_id) |id| break :blk id;
            break :blk "";
        };
        if (session_id.len == 0) {
            try self.pushSystem("No session id yet. Run the agent or /resume first, or use /events <session_id>.");
            return;
        }

        const body = workspace.sessions.readEvents(self.allocator, self.io, self.opened.root, session_id) catch {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "No event log for {s}", .{session_id}) catch "No event log";
            try self.pushSystem(msg);
            return;
        };
        defer self.allocator.free(body);

        self.mutex.lock();
        self.freeEventsLines();
        self.show_events = true;
        self.events_scroll = 0;
        self.mutex.unlock();

        var header_buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "--- session events: {s}{s}{s} ---", .{
            session_id,
            if (query.type_filter != null) " type=" else "",
            query.type_filter orelse "",
        }) catch "--- session events ---";
        try self.pushEventsLine(.system, try self.allocator.dupe(u8, header));

        // Collect matching rendered lines, then apply tail if requested.
        var rendered_lines: std.ArrayList([]u8) = .empty;
        defer rendered_lines.deinit(self.allocator);
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len == 0) continue;
            if (query.type_filter) |want| {
                if (!eventTypeMatches(trimmed, want)) continue;
            }
            const rendered = renderEventPreview(self.allocator, trimmed) catch continue;
            rendered_lines.append(self.allocator, rendered) catch {
                self.allocator.free(rendered);
                continue;
            };
        }

        const total = rendered_lines.items.len;
        const start = if (query.tail > 0 and total > query.tail) total - query.tail else 0;
        if (start > 0) {
            var skip_buf: [64]u8 = undefined;
            const skip_msg = std.fmt.bufPrint(&skip_buf, "… {d} earlier events hidden (--tail {d})", .{ start, query.tail }) catch "… earlier events hidden";
            try self.pushEventsLine(.system, try self.allocator.dupe(u8, skip_msg));
        }
        for (rendered_lines.items, 0..) |rendered, idx| {
            if (idx < start) {
                self.allocator.free(rendered);
                continue;
            }
            try self.pushEventsLine(.tool, rendered);
        }
        if (total == 0) try self.pushEventsLine(.system, try self.allocator.dupe(u8, "(no matching events)"));
        self.markDirty();
    }

    fn eventTypeMatches(line: []const u8, want: []const u8) bool {
        var needle_buf: [96]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "\"type\":\"{s}\"", .{want}) catch return false;
        return std.mem.indexOf(u8, line, needle) != null;
    }

    fn pushEventsLine(self: *App, kind: LineKind, text: []u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.events_lines.append(self.allocator, .{ .kind = kind, .text = text }) catch {
            self.allocator.free(text);
            return;
        };
        self.events_scroll = std.math.maxInt(usize);
    }

    fn renderEventPreview(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return allocator.dupe(u8, line);
        const obj = parsed.value.object;
        const type_str = jsonStr(obj, "type");
        if (std.mem.eql(u8, type_str, "session_started")) {
            return std.fmt.allocPrint(allocator, "session_started  intent={s}", .{jsonStr(obj, "intent")});
        }
        if (std.mem.eql(u8, type_str, "context_manifest_built")) {
            return std.fmt.allocPrint(allocator, "context_manifest  used_bytes={d} blocks={d}", .{ jsonInt(obj, "used_bytes"), jsonInt(obj, "blocks") });
        }
        if (std.mem.eql(u8, type_str, "tool_call")) {
            return std.fmt.allocPrint(allocator, "[{d}] tool_call  {s}  ({s})", .{ jsonInt(obj, "step"), jsonStr(obj, "tool"), jsonStr(obj, "reason") });
        }
        if (std.mem.eql(u8, type_str, "tool_result")) {
            const clipped = clip(jsonStr(obj, "summary"), 220);
            return std.fmt.allocPrint(allocator, "[{d}] tool_result  {s}  {s}", .{ jsonInt(obj, "step"), jsonStr(obj, "kind"), clipped });
        }
        if (std.mem.eql(u8, type_str, "proposal_created")) {
            return std.fmt.allocPrint(allocator, "proposal_created  {s}", .{jsonStr(obj, "proposal_path")});
        }
        if (std.mem.eql(u8, type_str, "validation_started")) {
            return std.fmt.allocPrint(allocator, "validation_started  attempt={d}", .{jsonInt(obj, "attempt")});
        }
        if (std.mem.eql(u8, type_str, "validation_result")) {
            const passed = if (obj.get("passed")) |v| (v == .bool and v.bool) else false;
            return std.fmt.allocPrint(allocator, "validation_result  attempt={d} passed={}", .{ jsonInt(obj, "attempt"), passed });
        }
        if (std.mem.eql(u8, type_str, "run_completed")) {
            return std.fmt.allocPrint(allocator, "run_completed  steps={d} repairs={d}", .{ jsonInt(obj, "steps"), jsonInt(obj, "repair_attempts") });
        }
        if (type_str.len > 0) return allocator.dupe(u8, type_str);
        return allocator.dupe(u8, line);
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

    fn clip(s: []const u8, max: usize) []const u8 {
        return if (s.len > max) s[0..max] else s;
    }

    fn applyPendingProposal(self: *App) !void {
        const prop_rel = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            const prop = self.pending_proposal orelse return;
            break :blk try self.allocator.dupe(u8, prop);
        };
        defer self.allocator.free(prop_rel);

        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        const code = workspace_cmd.applyProposal(self.allocator, self.io, self.opened, prop_rel, &writer, false) catch 2;
        if (code == 0) {
            self.dismissPendingProposal();
            const msg = try std.fmt.allocPrint(self.allocator, "Applied {s}", .{prop_rel});
            try self.pushLine(.system, msg);
            try self.refreshStatus();
        } else {
            try self.pushSystem("Apply failed");
        }
    }

    fn pushSystem(self: *App, text: []const u8) !void {
        try self.pushLine(.system, try self.allocator.dupe(u8, text));
    }

    fn showLastToolReview(self: *App) !void {
        const Snapshot = struct { kind: []u8, text: []u8 };
        const snap: ?Snapshot = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            const text = self.last_tool_review orelse break :blk null;
            const kind = self.last_tool_review_kind orelse "tool";
            const kind_copy = try self.allocator.dupe(u8, kind);
            errdefer self.allocator.free(kind_copy);
            const text_copy = try self.allocator.dupe(u8, text);
            break :blk .{
                .kind = kind_copy,
                .text = text_copy,
            };
        };
        if (snap) |review| {
            defer self.allocator.free(review.kind);
            defer self.allocator.free(review.text);
            const header = try std.fmt.allocPrint(self.allocator, "--- full {s} output ---", .{review.kind});
            try self.pushLine(.tool, header);
            var lines = std.mem.splitScalar(u8, review.text, '\n');
            var shown: usize = 0;
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                try self.pushLine(.tool, try self.allocator.dupe(u8, line));
                shown += 1;
                if (shown >= 240) {
                    try self.pushLine(.tool, try self.allocator.dupe(u8, "… truncated review at 240 lines"));
                    break;
                }
            }
        } else {
            try self.pushSystem("No collapsed tool output to review yet");
        }
    }

    fn freeLines(self: *App) void {
        for (self.lines.items) |line| self.allocator.free(line.text);
        self.lines.clearRetainingCapacity();
    }

    fn freeEventsLines(self: *App) void {
        for (self.events_lines.items) |line| self.allocator.free(line.text);
        self.events_lines.clearRetainingCapacity();
    }

    fn refreshStatus(self: *App) !void {
        const branch_text = blk: {
            if (try workspace.git_diff.currentBranch(self.allocator, self.opened.path)) |name| {
                break :blk name;
            }
            break :blk try self.allocator.dupe(u8, "no branch");
        };

        const changed = try workspace.git_diff.listChangedPaths(self.allocator, self.opened.path, 8);
        defer workspace.git_diff.freePaths(self.allocator, changed);
        const edited = try std.fmt.allocPrint(self.allocator, "{d} edited", .{changed.len});

        self.mutex.lock();
        self.allocator.free(self.edited_label);
        self.allocator.free(self.branch_label);
        self.edited_label = edited;
        self.branch_label = branch_text;
        self.mutex.unlock();
    }

    fn refreshContextLabel(self: *App, intent: []const u8) void {
        const explicit = self.explicitFilesSnapshot();
        defer {
            for (explicit) |f| self.allocator.free(f);
            if (explicit.len > 0) self.allocator.free(explicit);
        }

        const route = ai.routing.plan(.{
            .mode = self.agent_mode,
            .intent = intent,
            .has_active_file = self.parsed.flags.files.len > 0,
        }, .{
            .intent = intent,
            .explicit_files = explicit,
            .max_bytes = if (self.parsed.flags.budget_bytes > 0) self.parsed.flags.budget_bytes else 1024 * 1024,
            .workspace_cwd = self.opened.path,
        });

        var ctx_builder = ai.context_loader.build(self.allocator, self.io, self.opened.root, route.context) catch return;
        defer ctx_builder.deinit();

        var label_buf: [128]u8 = undefined;
        const kb = ctx_builder.used_bytes / 1024;
        const label = std.fmt.bufPrint(
            &label_buf,
            "{d} blocks {d}kB",
            .{ ctx_builder.blocks.items.len, kb },
        ) catch return;

        self.mutex.lock();
        defer self.mutex.unlock();
        const owned = self.allocator.dupe(u8, label) catch return;
        self.allocator.free(self.context_label);
        self.context_label = owned;
    }

    fn shouldAutoApprove(self: *App, policy: ai.tool_registry.Policy) bool {
        return switch (self.tool_policy) {
            .run_everything => true,
            .ask_each_time => policy.approval == .automatic,
            .agent_default => blk: {
                if (policy.approval == .automatic) break :blk true;
                if (policy.approval == .review) break :blk true;
                if (policy.approval == .every_time and policy.risk != .high) break :blk true;
                break :blk false;
            },
        };
    }

    fn waitForApproval(self: *App, tool_name: []const u8, args_json: []const u8, policy: ai.tool_registry.Policy) bool {
        if (self.shouldAutoApprove(policy)) return true;

        self.approval.mutex.lock();
        self.approval.pending = true;
        self.approval.decided = false;
        self.approval.approved = false;
        self.approval.risk = policy.risk;
        const tool_len = @min(tool_name.len, self.approval.tool_name.len);
        @memcpy(self.approval.tool_name[0..tool_len], tool_name[0..tool_len]);
        self.approval.tool_name_len = tool_len;
        const args_len = @min(args_json.len, self.approval.args_preview.len);
        @memcpy(self.approval.args_preview[0..args_len], args_json[0..args_len]);
        self.approval.args_preview_len = args_len;
        self.approval.mutex.unlock();

        var msg_buf: [512]u8 = undefined;
        const prompt = std.fmt.bufPrint(&msg_buf, "Approval required: {s} [{s}]", .{
            tool_name,
            @tagName(policy.risk),
        }) catch tool_name;
        self.pushLine(.system, self.allocator.dupe(u8, prompt) catch return false) catch {};

        self.approval.mutex.lock();
        while (!self.approval.decided) self.approval.cond.wait(&self.approval.mutex);
        const approved = self.approval.approved;
        self.approval.mutex.unlock();
        return approved;
    }

    fn onStepBegin(self: *App, index: u32, tool_name: []const u8, args_json: []const u8) void {
        self.mutex.lock();
        const len = @min(tool_name.len, self.active_tool.len);
        @memcpy(self.active_tool[0..len], tool_name[0..len]);
        self.active_tool_len = len;
        self.active_tool_running = true;
        self.markDirty();
        self.mutex.unlock();

        var buf: [256]u8 = undefined;
        var args_buf: [160]u8 = undefined;
        const args_preview = compactArgs(&args_buf, args_json);
        const line = if (args_preview.len > 0)
            std.fmt.bufPrint(&buf, "$ {s} {s}  step {d}", .{ tool_name, args_preview, index }) catch return
        else
            std.fmt.bufPrint(&buf, "$ {s}  step {d}", .{ tool_name, index }) catch return;
        self.pushLine(.tool, self.allocator.dupe(u8, line) catch return) catch {};
    }

    fn onStepDone(self: *App, index: u32, kind: []const u8, summary: []const u8) void {
        _ = index;
        self.mutex.lock();
        self.active_tool_running = false;
        self.active_tool_len = 0;
        if (self.last_tool_review) |old| self.allocator.free(old);
        if (self.last_tool_review_kind) |old| self.allocator.free(old);
        self.last_tool_review = self.allocator.dupe(u8, summary) catch null;
        self.last_tool_review_kind = self.allocator.dupe(u8, kind) catch null;
        self.markDirty();
        self.mutex.unlock();

        var buf: [1024]u8 = undefined;
        const first = firstNonEmptyLine(summary);
        const line_count = countNonEmptyLines(summary);
        const clipped = if (first.len > 420) first[0..420] else first;
        const line = if (line_count > 4)
            std.fmt.bufPrint(&buf, "ok {s} · {d} output lines hidden · ctrl+r to review · {s}", .{ kind, line_count, clipped }) catch return
        else
            std.fmt.bufPrint(&buf, "ok {s} · {s}", .{ kind, clipped }) catch return;
        self.pushLine(.tool, self.allocator.dupe(u8, line) catch return) catch {};
        self.refreshStatus() catch {};
    }

    fn firstNonEmptyLine(text: []const u8) []const u8 {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len > 0) return trimmed;
        }
        return "";
    }

    fn countNonEmptyLines(text: []const u8) usize {
        var count: usize = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (std.mem.trim(u8, line, &std.ascii.whitespace).len > 0) count += 1;
        }
        return count;
    }

    fn compactArgs(buf: []u8, args_json: []const u8) []const u8 {
        const trimmed = std.mem.trim(u8, args_json, &std.ascii.whitespace);
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "{}")) return "";
        var out_len: usize = 0;
        var last_space = false;
        for (trimmed) |c| {
            const is_space = std.ascii.isWhitespace(c);
            if (is_space and last_space) continue;
            const next = if (is_space) ' ' else c;
            if (out_len >= buf.len) break;
            buf[out_len] = next;
            out_len += 1;
            last_space = is_space;
        }
        if (out_len > 120 and buf.len >= 123) {
            @memcpy(buf[120..123], "...");
            return buf[0..123];
        }
        return buf[0..out_len];
    }

    fn colorForLine(kind: LineKind, text: []const u8) []const u8 {
        if (text.len > 0 and text[0] == '+') return term.Style.bright_green;
        if (text.len > 0 and text[0] == '-') return term.Style.bright_red;
        if (std.mem.startsWith(u8, text, "Edited ")) return term.Style.bright_yellow;
        if (std.mem.startsWith(u8, text, "$ ")) return term.Style.bright_yellow;
        if (std.mem.startsWith(u8, text, "ok ")) return term.Style.bright_green;
        if (std.mem.startsWith(u8, text, "↻ ")) return term.Style.magenta;
        return switch (kind) {
            .user => term.Style.bright_yellow,
            .agent => term.Style.green,
            .tool => term.Style.yellow,
            .system => term.Style.dim,
            .failure => term.Style.red,
        };
    }

    fn bgForLine(text: []const u8) ?[]const u8 {
        if (text.len > 0 and text[0] == '+') return term.Style.bg_green;
        if (text.len > 0 and text[0] == '-') return term.Style.bg_red;
        return null;
    }

    fn decorateLine(allocator: std.mem.Allocator, kind: LineKind, text: []const u8) ![]u8 {
        return switch (kind) {
            .user => std.fmt.allocPrint(allocator, "› {s}", .{text}),
            .failure => std.fmt.allocPrint(allocator, "× {s}", .{text}),
            else => allocator.dupe(u8, text),
        };
    }

    fn getToolAction(tool_name: []const u8) []const u8 {
        if (std.mem.eql(u8, tool_name, "read_file")) return "Reading file";
        if (std.mem.eql(u8, tool_name, "search")) return "Searching files";
        if (std.mem.eql(u8, tool_name, "codebase_search")) return "Semantic search";
        if (std.mem.eql(u8, tool_name, "run_command")) return "Running command";
        if (std.mem.eql(u8, tool_name, "propose_edit")) return "Proposing edit";
        if (std.mem.eql(u8, tool_name, "apply_proposal")) return "Applying proposal";
        if (std.mem.eql(u8, tool_name, "fetch_url")) return "Fetching URL";
        if (std.mem.eql(u8, tool_name, "list_tree")) return "Listing directory";
        if (std.mem.eql(u8, tool_name, "remember")) return "Remembering context";
        if (std.mem.eql(u8, tool_name, "undo")) return "Undoing changes";
        if (std.mem.eql(u8, tool_name, "show_context")) return "Checking context";
        return tool_name;
    }

    fn render(self: *App) void {
        self.terminal_size = self.term.size();
        const size = self.terminal_size;
        const show_commands = self.input.items.len > 0 and self.input.items[0] == '/';
        var filtered: [ALL_COMMANDS.len][]const u8 = undefined;
        var filtered_len: u16 = 0;

        if (show_commands) {
            filtered_len = @intCast(self.getFilteredCommands(&filtered));
            if (filtered_len > 0 and self.command_index >= filtered_len) {
                self.command_index = filtered_len - 1;
            }
        }

        const footer_rows: u16 = 5 + filtered_len;
        if (size.rows <= footer_rows + 2) return;
        const chat_rows = size.rows - footer_rows;

        self.frame.begin();

        var wrapped_cache: std.ArrayList([]const u8) = .empty;
        defer {
            for (wrapped_cache.items) |line| self.allocator.free(line);
            wrapped_cache.deinit(self.allocator);
        }

        var display_lines: std.ArrayList(struct { kind: LineKind, text: []const u8 }) = .empty;
        defer display_lines.deinit(self.allocator);

        const width = @max(20, @as(usize, size.cols) - 2);
        const source_lines = if (self.show_events) self.events_lines.items else self.lines.items;
        const source_scroll_ptr: *usize = if (self.show_events) &self.events_scroll else &self.scroll;

        for (source_lines) |line| {
            const decorated = decorateLine(self.allocator, line.kind, line.text) catch continue;
            defer self.allocator.free(decorated);
            const wrapped = term.wrapLines(self.allocator, decorated, width) catch continue;
            defer term.freeLines(self.allocator, wrapped);
            for (wrapped) |part| {
                const owned = self.allocator.dupe(u8, part) catch continue;
                wrapped_cache.append(self.allocator, owned) catch {
                    self.allocator.free(owned);
                    continue;
                };
                display_lines.append(self.allocator, .{ .kind = line.kind, .text = owned }) catch {};
            }
        }

        if (self.agent_busy) {
            var busy_buf: [128]u8 = undefined;
            const status_line = blk: {
                if (self.active_tool_running and self.active_tool_len > 0) {
                    break :blk std.fmt.bufPrint(&busy_buf, "⣻ {s}...", .{getToolAction(self.active_tool[0..self.active_tool_len])}) catch "⣻ Working...";
                }
                break :blk std.fmt.bufPrint(&busy_buf, "⣻ Thinking...", .{}) catch "⣻ Thinking...";
            };
            if (self.allocator.dupe(u8, status_line)) |owned_status| {
                wrapped_cache.append(self.allocator, owned_status) catch self.allocator.free(owned_status);
                display_lines.append(self.allocator, .{ .kind = .system, .text = owned_status }) catch {};
            } else |_| {}
        }

        const total = display_lines.items.len;
        const max_scroll = if (total > chat_rows) total - chat_rows else 0;
        if (source_scroll_ptr.* > max_scroll) source_scroll_ptr.* = max_scroll;
        const start = if (total > chat_rows) total - chat_rows - source_scroll_ptr.* else 0;
        const end = @min(total, start + chat_rows);

        var row: u16 = 1;
        var scratch: [512]u8 = undefined;
        for (display_lines.items[start..end]) |line| {
            const color = colorForLine(line.kind, line.text);
            const clipped = term.truncateEnd(&scratch, line.text, @intCast(size.cols - 1));
            self.frame.moveTo(row, 1);
            if (self.term.use_color) self.frame.appendSlice(color) catch {};
            if (self.term.use_color) {
                if (bgForLine(line.text)) |bg| self.frame.appendSlice(bg) catch {};
            }
            self.frame.appendSlice(clipped) catch {};
            if (clipped.len < size.cols) {
                self.frame.data.appendNTimes(self.allocator, ' ', size.cols - clipped.len) catch {};
            }
            self.frame.appendSlice("\x1b[K") catch {};
            if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
            row += 1;
        }
        while (row <= chat_rows) : (row += 1) {
            self.frame.writeRow(row, size.cols, "");
        }

        const input_top_row = chat_rows + 1;
        const input_row = chat_rows + 2;

        if (show_commands) {
            for (filtered[0..filtered_len], 0..) |cmd, i| {
                const cmd_row = input_row + 1 + @as(u16, @intCast(i));
                self.frame.moveTo(cmd_row, 1);

                if (i == self.command_index) {
                    if (self.term.use_color) self.frame.appendSlice(term.Style.cyan) catch {};
                    if (self.term.use_color) self.frame.appendSlice(term.Style.invert) catch {};
                    self.frame.appendSlice(" > ") catch {};
                    self.frame.appendSlice(cmd) catch {};
                    if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
                } else {
                    if (self.term.use_color) self.frame.appendSlice(term.Style.dim) catch {};
                    self.frame.appendSlice("   ") catch {};
                    self.frame.appendSlice(cmd) catch {};
                    if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
                }
                self.frame.appendSlice("\x1b[K") catch {};
            }
        }

        const status_row = input_row + filtered_len + 1;
        const action_row = status_row + 1;
        self.frame.writeRow(size.rows, size.cols, "");

        var status_buf: [1024]u8 = undefined;
        var folder_scratch: [256]u8 = undefined;
        const folder = term.truncateEnd(&folder_scratch, self.folder_label, 24);
        const tool_indicator = blk: {
            if (self.active_tool_running and self.active_tool_len > 0) {
                break :blk self.active_tool[0..self.active_tool_len];
            }
            break :blk "-";
        };

        var input_line: [576]u8 = undefined;
        var composer_title: [256]u8 = undefined;
        const title = std.fmt.bufPrint(&composer_title, "╭─ Message Forge  ·  @file / @codebase / slash commands", .{}) catch "╭─ Message Forge";
        if (self.term.use_color) self.frame.appendSlice(term.Style.bg_input) catch {};
        if (self.term.use_color) self.frame.appendSlice(term.Style.dim) catch {};
        self.frame.writeRow(input_top_row, size.cols, term.truncateEnd(&scratch, title, @intCast(size.cols - 1)));
        if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};

        const prompt = if (self.agent_busy) " … " else " → ";
        const prompt_w: usize = 3;
        const avail = size.cols - @min(size.cols, prompt_w + 1);
        const input_view = term.truncateEnd(&scratch, self.input.items, @intCast(avail));
        const placeholder = if (self.input.items.len == 0 and !self.agent_busy) "Add a follow-up" else input_view;
        const input_text = std.fmt.bufPrint(&input_line, "{s}{s}", .{ prompt, placeholder }) catch prompt;
        if (self.term.use_color) self.frame.appendSlice(term.Style.bg_input) catch {};
        if (self.term.use_color and self.input.items.len == 0 and !self.agent_busy) self.frame.appendSlice(term.Style.dim) catch {};
        self.frame.writeRow(input_row, size.cols, input_text);
        if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};

        const status = std.fmt.bufPrint(
            &status_buf,
            "mode:{s} · tool:{s} · model:{s} · ctx:{s}",
            .{
                commands.modeLabel(self.agent_mode),
                tool_indicator,
                self.model_label,
                self.context_label,
            },
        ) catch "";
        if (self.term.use_color) self.frame.appendSlice(term.Style.dim) catch {};
        self.frame.writeRow(status_row, size.cols, term.truncateEnd(&folder_scratch, status, @intCast(size.cols - 1)));
        if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};

        const action_label = self.tool_policy.label();
        const bottom = std.fmt.bufPrint(
            &status_buf,
            "1 task  Auto · {s} · {s} · {s}",
            .{ self.edited_label, folder, self.branch_label },
        ) catch "";
        if (self.term.use_color) self.frame.appendSlice(term.Style.blue) catch {};
        self.frame.writeRow(action_row, size.cols, term.truncateEnd(&folder_scratch, bottom, @intCast(size.cols - 1)));
        if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
        const action_text = if (self.focus_action)
            std.fmt.bufPrint(&status_buf, "[{s} ▶]", .{action_label}) catch action_label
        else
            std.fmt.bufPrint(&status_buf, " {s} ", .{action_label}) catch action_label;
        const action_col: u16 = if (@as(usize, size.cols) > action_text.len + 1)
            @intCast(size.cols - action_text.len)
        else
            1;
        self.frame.moveTo(action_row, action_col);
        if (self.term.use_color) self.frame.appendSlice(term.Style.magenta) catch {};
        if (self.focus_action and self.term.use_color) self.frame.appendSlice(term.Style.invert) catch {};
        self.frame.appendSlice(action_text) catch {};
        if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};

        self.approval.mutex.lock();
        const pending = self.approval.pending;
        if (pending) {
            var approve_buf: [512]u8 = undefined;
            const tool = self.approval.tool_name[0..self.approval.tool_name_len];
            const preview = self.approval.args_preview[0..@min(self.approval.args_preview_len, 120)];
            const approve_line = std.fmt.bufPrint(
                &approve_buf,
                "Allow {s}? [y/N] {s}",
                .{ tool, preview },
            ) catch "Allow tool? [y/N]";
            if (self.term.use_color) self.frame.appendSlice(term.Style.magenta) catch {};
            self.frame.writeRow(input_row -| 1, size.cols, term.truncateEnd(&folder_scratch, approve_line, @intCast(size.cols - 1)));
            if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
        }
        self.approval.mutex.unlock();

        // Place the real terminal cursor at the input caret, then reveal it.
        if (!self.agent_busy and !pending) {
            const caret_col: u16 = @intCast(@min(
                @as(usize, size.cols),
                prompt_w + @min(self.cursor, avail) + 1,
            ));
            self.frame.moveTo(input_row, caret_col);
            self.frame.appendSlice("\x1b[?25h") catch {};
        } else {
            self.frame.appendSlice("\x1b[?25l") catch {};
        }

        self.frame.flush();
    }
};

const WorkerResult = union(enum) {
    ok: OkPayload,
    err: []u8,

    const OkPayload = struct {
        response_text: ?[]const u8,
        proposal_rel: ?[]const u8,
        session_id: []const u8,

        fn deinit(self: OkPayload, allocator: std.mem.Allocator) void {
            if (self.response_text) |text| allocator.free(text);
            if (self.proposal_rel) |prop| allocator.free(prop);
            allocator.free(self.session_id);
        }
    };
};

const WorkerCtx = struct {
    app: *App,
    intent: []const u8,
    resume_session_id: ?[]u8 = null,
};

fn workerMain(ctx: *WorkerCtx) void {
    const app = ctx.app;
    const intent = ctx.intent;
    const resume_id = ctx.resume_session_id;
    defer if (resume_id) |id| app.allocator.free(id);

    if (resume_id == null) {
        app.appendConversation(.user, intent) catch {};
    }
    app.refreshContextLabel(intent);

    const parsed = app.parsed;
    var provider_opts = ai_workflow.agentProviderOptionsFromFlags(parsed.flags, intent);
    provider_opts.stream_callback = streamBridge;
    provider_opts.stream_context = app;
    const max_steps = if (parsed.flags.max_steps > 0) parsed.flags.max_steps else 8;
    var cancel_token = app.cancel_scope.token();

    var conversation_snapshot: []ai.conversation.Turn = &.{};
    app.mutex.lock();
    if (app.conversation.items.len > 0) {
        conversation_snapshot = app.allocator.alloc(ai.conversation.Turn, app.conversation.items.len) catch &.{};
        for (app.conversation.items, 0..) |turn, i| {
            conversation_snapshot[i] = .{
                .role = turn.role,
                .content = app.allocator.dupe(u8, turn.content) catch "",
            };
        }
    }
    app.mutex.unlock();
    defer {
        for (conversation_snapshot) |turn| app.allocator.free(turn.content);
        if (conversation_snapshot.len > 0) app.allocator.free(conversation_snapshot);
    }

    const explicit_files = app.explicitFilesSnapshot();
    defer {
        for (explicit_files) |f| app.allocator.free(f);
        if (explicit_files.len > 0) app.allocator.free(explicit_files);
    }

    const agent_config = ai.agent.Config{
        .max_steps = max_steps,
        .provider_options = provider_opts,
        .mode = app.agent_mode,
        .capability_profile = capabilityForMode(app.agent_mode, parsed.flags),
        .workspace_cwd = app.opened.path,
        .explicit_files = explicit_files,
        .conversation = conversation_snapshot,
        .surface = .cli,
        .cancel_token = &cancel_token,
        .max_repair_attempts = if (provider_opts.kind == .fake) 0 else 2,
        .approve_every_time_tools = false,
        .approval_callback = approvalBridge,
        .approval_context = app,
        .step_begin_callback = stepBeginBridge,
        .step_begin_context = app,
        .step_callback = stepBridge,
        .step_context = app,
        .turn_callback = turnBridge,
        .turn_context = app,
        .progress_callback = progressBridge,
        .progress_context = app,
    };

    const result: ai.agent.Result = blk: {
        const run_result = if (resume_id) |session_id|
            ai.agent.resumeSession(
                app.allocator,
                app.io,
                app.environ_map,
                app.opened.root,
                session_id,
                agent_config,
            )
        else
            ai.agent.run(
                app.allocator,
                app.io,
                app.environ_map,
                app.opened.root,
                intent,
                agent_config,
            );
        break :blk run_result catch |err| {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Agent error: {s}", .{@errorName(err)}) catch "Agent error";
            app.workerDone(ctx, .{ .err = app.allocator.dupe(u8, msg) catch return });
            return;
        };
    };

    const payload = WorkerResult.OkPayload{
        .response_text = if (result.response_text) |text| app.allocator.dupe(u8, text) catch null else null,
        .proposal_rel = if (result.proposal_rel) |prop| app.allocator.dupe(u8, prop) catch null else null,
        .session_id = app.allocator.dupe(u8, result.session_id) catch app.allocator.dupe(u8, "") catch "",
    };
    var mutable = result;
    ai.agent.deinitResult(app.allocator, &mutable);
    app.workerDone(ctx, .{ .ok = payload });
}

fn streamBridge(context: ?*anyopaque, chunk: []const u8) void {
    const app: *App = @ptrCast(@alignCast(context.?));
    app.onStreamChunk(chunk);
}

fn approvalBridge(context: ?*anyopaque, tool_name: []const u8, args_json: []const u8, policy: ai.tool_registry.Policy) bool {
    const app: *App = @ptrCast(@alignCast(context.?));
    return app.waitForApproval(tool_name, args_json, policy);
}

fn stepBeginBridge(context: ?*anyopaque, step: ai.agent.StepBegin) void {
    const app: *App = @ptrCast(@alignCast(context.?));
    app.onStepBegin(step.index, step.tool_name, step.args_json);
}

fn stepBridge(context: ?*anyopaque, step: ai.agent.Step) void {
    const app: *App = @ptrCast(@alignCast(context.?));
    app.onStepDone(step.index, step.kind, step.summary);
}

fn turnBridge(context: ?*anyopaque, next_step_index: u32) void {
    const app: *App = @ptrCast(@alignCast(context.?));
    var buf: [96]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "↻ call llm  next tool step {d}", .{next_step_index}) catch return;
    app.pushLine(.tool, app.allocator.dupe(u8, line) catch return) catch {};
}

fn progressBridge(context: ?*anyopaque, phase: ai.progress.Phase) void {
    const app: *App = @ptrCast(@alignCast(context.?));
    const label = switch (phase) {
        .context_built => "Context built",
        .planning => "Planning...",
        .plan_ready => "Plan ready",
        .sending => "Thinking...",
        .streaming => "Generating...",
        .parsing => "Parsing response...",
        .repairing => "Repairing...",
        .proposal_ready => "Proposal ready",
    };
    var buf: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "● {s}", .{label}) catch return;
    app.pushLine(.system, app.allocator.dupe(u8, line) catch return) catch {};
}

fn defaultModel(kind: ai.provider_factory.Kind) []const u8 {
    return switch (kind) {
        .ollama => "qwen2.5-coder:7b",
        .gemini => "gemini-2.5-flash",
        .fake => "fake",
        .auto => "auto",
    };
}

fn parseMode(value: ?[]const u8) ai.tools.Mode {
    if (value) |mode| {
        if (std.mem.eql(u8, mode, "plan")) return .plan;
        if (std.mem.eql(u8, mode, "ask")) return .ask;
    }
    return .agent;
}

fn capabilityForMode(mode: ai.tools.Mode, flags: args_mod.GlobalFlags) ai.tools.CapabilityProfile {
    if (flags.capability) |value| {
        if (std.mem.eql(u8, value, "read_only")) return .read_only;
        if (std.mem.eql(u8, value, "propose_and_task")) return .propose_and_task;
        return .propose;
    }
    return ai.tools.profileForMode(mode);
}

fn capabilityFromFlags(flags: args_mod.GlobalFlags) ai.tools.CapabilityProfile {
    return capabilityForMode(modeFromFlags(flags), flags);
}

fn modeFromFlags(flags: args_mod.GlobalFlags) ai.tools.Mode {
    if (flags.mode) |mode| return parseMode(mode);
    return .agent;
}

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    parsed: args_mod.CliArgs,
) !u8 {
    if (builtin.os.tag == .windows) return error.UnsupportedPlatform;

    var opened = try workspace_cmd.OpenedWorkspace.open(allocator, io, parsed);
    defer opened.close(io);

    var scope = try cancel_scope_mod.Scope.init(allocator);
    defer scope.deinit();

    var terminal = try term.Terminal.init(!parsed.flags.no_color);
    defer terminal.deinit();

    var app = try App.init(allocator, io, environ_map, opened, parsed, terminal, scope);
    defer app.deinit();

    return app.run();
}
