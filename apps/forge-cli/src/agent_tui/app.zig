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
const cli_config = @import("../config.zig");
const editor = @import("forge-editor");
const commands = @import("commands.zig");
const events_render = @import("../events_render.zig");

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

const default_context_budget_bytes: usize = 8 * 1024 * 1024;

fn contextBudgetBytes(flags: args_mod.GlobalFlags) usize {
    return if (flags.budget_bytes > 0) flags.budget_bytes else default_context_budget_bytes;
}

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
    session_grant: bool = false,
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
    show_timeline: bool = false,
    scan_summary: ?@import("forge-workspace").tree.ScanSummary = null,
    explorer_scroll_y: usize = 0,
    cli_config: cli_config.Config = .{},
    show_explorer: bool = false,
    show_editor: bool = false,
    editor_buffer: ?*editor.Buffer = null,
    focus_explorer: bool = false,
    timeline_lines: std.ArrayList(ChatLine) = .empty,
    timeline_scroll: usize = 0,
    terminal_size: term.Terminal.Size = .{ .rows = 25, .cols = 80 },
    active_tool: [96]u8 = undefined,
    active_tool_len: usize = 0,
    active_tool_running: bool = false,
    active_progress: [96]u8 = undefined,
    active_progress_len: usize = 0,
    last_tool_review: ?[]u8 = null,
    last_tool_review_kind: ?[]u8 = null,
    command_index: usize = 0,
    session_grants: ai.session_grant.SessionGrants,

    const ALL_COMMANDS = [_][]const u8{ "/clear", "/policy", "/mode", "/context", "/diff", "/events", "/timeline", "/resume", "/sessions", "/mock", "/help", "/quit", "/exit" };

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ_map: ?*const std.process.Environ.Map,
        opened: workspace_cmd.OpenedWorkspace,
        parsed: args_mod.CliArgs,
        terminal: term.Terminal,
        cancel_scope: cancel_scope_mod.Scope,
    ) !App {
        const provider_opts = ai_workflow.agentProviderOptionsFromFlags(allocator, parsed.flags, "interactive", io, opened.root);
        const model = try std.fmt.allocPrint(allocator, "{s}/{s}", .{
            provider_opts.options.provider_name,
            provider_opts.options.model orelse "auto",
        });

        const folder = try workspaceDisplayNameAlloc(allocator, environ_map, opened.path);

        const loaded_config = cli_config.loadConfig(allocator, environ_map, io);
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
            .session_grants = ai.session_grant.SessionGrants.init(allocator, parsed.flags.auto_approve),
        };
        if (parsed.flags.mode) |mode_name| {
            if (commands.parseModeName(mode_name)) |mode| app.agent_mode = mode;
        }
        try app.refreshStatus();
        try app.pushStartupIntro();
        app.terminal_size = terminal.size();
        app.cli_config = loaded_config;
        app.show_explorer = loaded_config.show_explorer;
        app.show_editor = loaded_config.show_editor;
        return app;
    }

    pub fn deinit(self: *App) void {
        if (self.worker) |thread| thread.join();
        self.freeLines();
        self.freeEventsLines();
        self.freeTimelineLines();
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
        self.session_grants.deinit();
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
                } else if (self.input.items.len == 0) {
                    self.focus_explorer = !self.focus_explorer;
                    self.markDirty();
                }
                self.mutex.unlock();
            },
            .escape => {
                self.mutex.lock();
                if (self.show_events) self.show_events = false;
                if (self.show_timeline) self.show_timeline = false;
                self.focus_action = false;
                self.markDirty();
                self.mutex.unlock();
            },
            .enter => {
                self.mutex.lock();
                if (self.focus_explorer) {
                    if (self.scan_summary) |s| {
                        if (self.explorer_scroll_y < s.entries.len) {
                            const entry = s.entries[self.explorer_scroll_y];
                            if (entry.kind == .file) {
                                if (self.editor_buffer) |buf| {
                                    buf.deinit();
                                    self.allocator.destroy(buf);
                                }
                                self.editor_buffer = self.allocator.create(editor.Buffer) catch null;
                                if (self.editor_buffer) |buf| {
                                    buf.* = editor.Buffer.init(self.allocator) catch unreachable;
                                    const abs_path = std.fs.path.join(self.allocator, &.{ self.opened.path, entry.path }) catch "";
                                    if (abs_path.len > 0) {
                                        defer self.allocator.free(abs_path);
                                        if (std.Io.Dir.openFile(std.Io.Dir.cwd(), self.io, abs_path, .{})) |*file| {
                                            defer file.close(self.io);
                                            if (file.stat(self.io)) |stat| {
                                                const size: usize = @intCast(stat.size);
                                                if (size > 0 and size < 10 * 1024 * 1024) {
                                                    if (self.allocator.alloc(u8, size)) |text| {
                                                        defer self.allocator.free(text);
                                                        if (file.readPositionalAll(self.io, text, 0)) |_| {
                                                            buf.loadFromSlice(text) catch {};
                                                            self.show_editor = true;
                                                        } else |_| {}
                                                    } else |_| {}
                                                }
                                            } else |_| {}
                                        } else |_| {}
                                    }
                                }
                            }
                        }
                    }
                    self.markDirty();
                    self.mutex.unlock();
                    return;
                }
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
                if (self.cursor > 0) self.cursor -= 1;
                self.markDirty();
                self.mutex.unlock();
            },
            .right => {
                self.mutex.lock();
                if (self.cursor < self.input.items.len) {
                    self.cursor += 1;
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
                if (self.focus_explorer) {
                    if (self.explorer_scroll_y > 0) self.explorer_scroll_y -= 1;
                    self.markDirty();
                    return;
                }
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
                if (self.focus_explorer) {
                    if (self.scan_summary) |s| {
                        if (self.explorer_scroll_y + 1 < s.entries.len) self.explorer_scroll_y += 1;
                    }
                    self.markDirty();
                    return;
                }
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
                if (ch == 'y' or ch == 'Y') self.resolveApproval(true, false);
                if (ch == 'n' or ch == 'N') self.resolveApproval(false, false);
                if (ch == 's' or ch == 'S') self.resolveApproval(true, true);
            },
            .enter => self.resolveApproval(true, false),
            .escape => self.resolveApproval(false, false),
            else => {},
        }
    }

    fn resolveApproval(self: *App, approved: bool, session: bool) void {
        self.approval.mutex.lock();
        if (self.approval.pending) {
            self.approval.approved = approved;
            self.approval.session_grant = session;
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
            .mock => try self.loadMockTranscript(),
            .help => try self.pushSystem(commands.helpText()),
            .exit_app => self.quit = true,
            .sessions => try self.listSessions(),
            .resume_session => |session_id| try self.resumeSession(session_id),
            .events => |session_id| try self.showEvents(session_id),
            .timeline => try self.showTimeline(),
        }
    }

    fn showTimeline(self: *App) !void {
        const session_id_opt = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.last_session_id) |id| break :blk self.allocator.dupe(u8, id) catch null;
            if (self.resume_session_id) |id| break :blk self.allocator.dupe(u8, id) catch null;
            break :blk null;
        };
        defer if (session_id_opt) |id| self.allocator.free(id);

        self.mutex.lock();
        self.show_timeline = !self.show_timeline;
        if (self.show_timeline) self.show_events = false;
        self.timeline_scroll = 0;
        self.markDirty();
        const should_load = self.show_timeline and self.timeline_lines.items.len == 0;
        self.mutex.unlock();

        if (should_load) {
            const session_id = session_id_opt orelse return;
            try self.loadTimelineFromSession(session_id);
        }
    }

    fn loadTimelineFromSession(self: *App, session_id: []const u8) !void {
        var doc = workspace.sessions.loadSession(self.allocator, self.io, session_id) catch {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "No timeline for {s}", .{session_id}) catch "No timeline";
            try self.pushTimelineLine(.system, try self.allocator.dupe(u8, msg));
            return;
        };
        defer workspace.sessions.deinitSession(self.allocator, &doc);

        var header_buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "--- task timeline: {s} ---", .{session_id}) catch "--- task timeline ---";
        try self.pushTimelineLine(.system, try self.allocator.dupe(u8, header));

        if (doc.task_ledger_json.len > 0) {
            const rendered = ai.task_ledger.formatTimelineFromJson(self.allocator, doc.task_ledger_json, 80) catch null;
            if (rendered) |text| {
                defer self.allocator.free(text);
                var lines = std.mem.splitScalar(u8, text, '\n');
                var count: usize = 0;
                while (lines.next()) |line| {
                    if (line.len == 0) continue;
                    count += 1;
                    try self.pushTimelineLine(.tool, try self.allocator.dupe(u8, line));
                }
                if (count > 0) return;
            }
        }

        for (doc.steps) |step| {
            var buf: [512]u8 = undefined;
            const summary = if (step.summary.len > 260) step.summary[0..260] else step.summary;
            const line = std.fmt.bufPrint(&buf, "step {d}: {s} · {s}", .{ step.index, step.kind, summary }) catch continue;
            try self.pushTimelineLine(.tool, try self.allocator.dupe(u8, line));
        }
        if (doc.steps.len == 0) try self.pushTimelineLine(.system, try self.allocator.dupe(u8, "(no timeline data)"));
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

    fn loadMockTranscript(self: *App) !void {
        self.mutex.lock();
        self.freeLines();
        self.scroll = 0;
        self.markDirty();
        self.mutex.unlock();

        try self.pushStartupIntro();
        try self.pushLine(.user, try self.allocator.dupe(u8, "fix the memory leak in the websocket connection"));
        try self.pushLine(.agent, try self.allocator.dupe(u8, "Thinking..."));
        try self.pushLine(.agent, try self.allocator.dupe(u8, "> Reading src/services/socket.ts"));
        try self.pushLine(.agent, try self.allocator.dupe(u8, "> Analyzing useEffect cleanup dependencies"));
        try self.pushLine(.agent, try self.allocator.dupe(u8, "! Found missing disconnect call in cleanup function"));
        try self.pushLine(.agent, try self.allocator.dupe(u8, "I found the issue. The WebSocket connection isn't being closed when the component unmounts. Here's the fix:"));
        try self.pushLine(.agent, try self.allocator.dupe(u8, ""));
        try self.pushLine(.tool, try self.allocator.dupe(u8, "› Reading src/services/socket.ts lines 1-80 · step 1"));
        try self.pushLine(.tool, try self.allocator.dupe(u8, "✓ Read · src/services/socket.ts lines 1-80"));
        try self.pushLine(.tool, try self.allocator.dupe(u8, "› Searching \"socket.on|disconnect\" in src/**/*.ts · step 2"));
        try self.pushLine(.tool, try self.allocator.dupe(u8, "✓ Search · 3 hits in src/services/socket.ts"));
        try self.pushLine(.tool, try self.allocator.dupe(u8, "› Editing src/services/socket.ts · close WebSocket on cleanup · step 3"));
        try self.pushLine(.agent, try self.allocator.dupe(u8, "src/services/socket.ts"));
        try self.pushLine(.agent, try self.allocator.dupe(u8, ""));
        try self.pushLine(.agent, try self.allocator.dupe(u8, "useEffect(() => {"));
        try self.pushLine(.agent, try self.allocator.dupe(u8, "  const socket = connect(url);"));
        try self.pushLine(.agent, try self.allocator.dupe(u8, "  socket.on('message', handleMessage);"));
        try self.pushLine(.agent, try self.allocator.dupe(u8, "  return () => {"));
        try self.pushLine(.agent, try self.allocator.dupe(u8, "-   socket.off('message', handleMessage);"));
        try self.pushLine(.agent, try self.allocator.dupe(u8, "+   socket.off('message', handleMessage);"));
        try self.pushLine(.agent, try self.allocator.dupe(u8, "+   socket.disconnect();"));
        try self.pushLine(.agent, try self.allocator.dupe(u8, "  };"));
        try self.pushLine(.agent, try self.allocator.dupe(u8, "}, [url]);"));
        try self.pushLine(.agent, try self.allocator.dupe(u8, ""));
        try self.pushLine(.tool, try self.allocator.dupe(u8, "✓ Edit · 2 additions, 1 deletion · close WebSocket on cleanup"));
        try self.pushLine(.agent, try self.allocator.dupe(u8, "✓ Applied fix to src/services/socket.ts"));
    }

    fn showContextManifest(self: *App) !void {
        const explicit = self.explicitFilesSnapshot();
        defer {
            for (explicit) |f| self.allocator.free(f);
            if (explicit.len > 0) self.allocator.free(explicit);
        }

        const mode = self.agent_mode;
        const route = ai.route_resolver.resolveHeuristic(.{
            .mode = mode,
            .intent = "",
            .has_active_file = self.parsed.flags.files.len > 0,
        }, .{
            .intent = null,
            .explicit_files = explicit,
            .max_bytes = contextBudgetBytes(self.parsed.flags),
            .workspace_cwd = self.opened.path,
        }).route;

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
        var list = try workspace.sessions.listEntries(self.allocator, self.io, self.opened.path);
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
            var list = try workspace.sessions.listEntries(self.allocator, self.io, self.opened.path);
            defer list.deinit();
            if (list.items.len == 0) {
                try self.pushSystem("No sessions to resume");
                return;
            }
            const latest = list.items[list.items.len - 1];
            break :blk try self.allocator.dupe(u8, latest.session_id);
        };
        defer self.allocator.free(session_id);

        var doc = workspace.sessions.loadSession(self.allocator, self.io, session_id) catch |err| {
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
        if (doc.task_ledger_json.len > 0) {
            const stats = ai.task_ledger.statsFromJson(self.allocator, doc.task_ledger_json) catch null;
            if (stats) |ledger| {
                var buf: [256]u8 = undefined;
                const line = std.fmt.bufPrint(
                    &buf,
                    "Task ledger: phase={s} entries={d} reads={d} edits={d} blockers={d}",
                    .{ @tagName(ledger.phase), ledger.entries, ledger.file_reads, ledger.file_edits, ledger.blockers },
                ) catch "Task ledger loaded";
                try self.pushLine(.system, try self.allocator.dupe(u8, line));
            }
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
        var line_buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "start · {s}", .{intent}) catch "start";
        try self.pushTimelineLine(.system, try self.allocator.dupe(u8, line));

        self.worker = try std.Thread.spawn(.{}, workerMain, .{ctx});
    }

    fn workerDone(self: *App, ctx: *WorkerCtx, result: WorkerResult) void {
        self.allocator.free(ctx.intent);
        self.allocator.destroy(ctx);

        self.mutex.lock();
        self.agent_busy = false;
        self.active_progress_len = 0;
        self.stream_line_index = null;
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
        self.scroll = 0;
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
            self.scroll = 0;
        }
        self.markDirty();
    }

    fn onStreamChunk(self: *App, chunk: []const u8) void {
        // Agent worker delivers the final answer via workerDone; intermediate LLM
        // token streams during tool turns would append to stale line indices and
        // appear above already-printed tool steps.
        if (self.agent_busy) return;
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
        self.scroll = 0;
        self.markDirty();
    }

    fn setPendingProposal(self: *App, prop: []const u8) !void {
        const owned = try self.allocator.dupe(u8, prop);
        self.mutex.lock();
        if (self.pending_proposal) |old| self.allocator.free(old);
        self.pending_proposal = owned;
        self.mutex.unlock();

        try self.pushSystem("--- proposed changes ---");
        try self.showProposalDiffFor(prop);

        const msg = try std.fmt.allocPrint(
            self.allocator,
            "Proposal: {s} — green + added, red - removed. Press a=apply to write files, n=dismiss",
            .{prop},
        );
        try self.pushLine(.system, msg);

        if (self.parsed.flags.yes or self.tool_policy == .run_everything) {
            try self.applyPendingProposal();
        }
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
        try self.showProposalDiffFor(prop_rel);
    }

    fn showProposalDiffFor(self: *App, prop_rel: []const u8) !void {
        var proposal = try workspace_cmd.loadProposal(self.allocator, self.io, self.opened, prop_rel);
        defer proposal.deinit();
        const edit = proposal.workspaceEdit();
        try edit.validate();

        var out = std.Io.Writer.Allocating.init(self.allocator);
        defer out.deinit();
        try workspace.preview.renderDiff(self.allocator, self.io, self.opened.root, edit, &out.writer);

        var lines = std.mem.splitScalar(u8, out.writer.buffered(), '\n');
        var shown: usize = 0;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            try self.pushLine(.system, try self.allocator.dupe(u8, line));
            shown += 1;
            if (shown >= 160) {
                try self.pushSystem("... diff truncated (use /diff or `forge diff` for full output)");
                break;
            }
        }
    }

    const EventsQuery = struct {
        session_id: ?[]const u8 = null,
        render: events_render.Query = .{},
    };

    fn parseEventsArgs(args: ?[]const u8) EventsQuery {
        var query = EventsQuery{};
        const raw = args orelse return query;
        var it = std.mem.tokenizeScalar(u8, raw, ' ');
        while (it.next()) |token| {
            if (std.mem.eql(u8, token, "--tail")) {
                if (it.next()) |value| query.render.tail = std.fmt.parseInt(usize, value, 10) catch 0;
            } else if (std.mem.eql(u8, token, "--type")) {
                if (it.next()) |value| query.render.type_filter = value;
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

        const body = workspace.sessions.readEvents(self.allocator, self.io, session_id) catch {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "No event log for {s}", .{session_id}) catch "No event log";
            try self.pushSystem(msg);
            return;
        };
        defer self.allocator.free(body);

        self.mutex.lock();
        self.freeEventsLines();
        self.show_events = true;
        self.show_timeline = false;
        self.events_scroll = 0;
        self.mutex.unlock();

        var header_buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "--- session events: {s}{s}{s} ---", .{
            session_id,
            if (query.render.type_filter != null) " type=" else "",
            query.render.type_filter orelse "",
        }) catch "--- session events ---";
        try self.pushEventsLine(.system, try self.allocator.dupe(u8, header));

        // Collect matching rendered lines, then apply tail if requested.
        var rendered_lines: std.ArrayList([]u8) = .empty;
        defer rendered_lines.deinit(self.allocator);
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len == 0) continue;
            if (query.render.type_filter) |want| {
                if (!events_render.eventTypeMatches(trimmed, want)) continue;
            }
            const rendered = events_render.renderPreviewAlloc(self.allocator, trimmed) catch continue;
            rendered_lines.append(self.allocator, rendered) catch {
                self.allocator.free(rendered);
                continue;
            };
        }

        const total = rendered_lines.items.len;
        const start = if (query.render.tail > 0 and total > query.render.tail) total - query.render.tail else 0;
        if (start > 0) {
            var skip_buf: [64]u8 = undefined;
            const skip_msg = std.fmt.bufPrint(&skip_buf, "… {d} earlier events hidden (--tail {d})", .{ start, query.render.tail }) catch "… earlier events hidden";
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

    fn pushEventsLine(self: *App, kind: LineKind, text: []u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.events_lines.append(self.allocator, .{ .kind = kind, .text = text }) catch {
            self.allocator.free(text);
            return;
        };
        self.events_scroll = 0;
    }

    fn pushTimelineLine(self: *App, kind: LineKind, text: []u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.timeline_lines.append(self.allocator, .{ .kind = kind, .text = text }) catch {
            self.allocator.free(text);
            return;
        };
        if (self.timeline_lines.items.len > 500) {
            const old = self.timeline_lines.orderedRemove(0);
            self.allocator.free(old.text);
        }
        self.timeline_scroll = 0;
        self.markDirty();
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
            const msg = try std.fmt.allocPrint(self.allocator, "✓ Applied {s}", .{prop_rel});
            try self.pushLine(.system, msg);
            try self.refreshStatus();
        } else {
            try self.pushSystem("Apply failed");
        }
    }

    fn pushSystem(self: *App, text: []const u8) !void {
        try self.pushLine(.system, try self.allocator.dupe(u8, text));
    }

    fn sessionIdForResume(self: *App) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.last_session_id) |id| return self.allocator.dupe(u8, id) catch null;
        if (self.resume_session_id) |id| return self.allocator.dupe(u8, id) catch null;
        return null;
    }

    fn printResumeHintToStdout(self: *App, io: std.Io) !void {
        const session_id = self.sessionIdForResume() orelse return;
        defer self.allocator.free(session_id);
        var buf: [320]u8 = undefined;
        var file_writer = std.Io.File.Writer.init(.stdout(), io, &buf);
        const writer = &file_writer.interface;
        try writer.print("Resume: forge agent --conversation={s} (or forge agent -c {s})\n", .{ session_id, session_id });
        try writer.flush();
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

    fn freeTimelineLines(self: *App) void {
        for (self.timeline_lines.items) |line| self.allocator.free(line.text);
        self.timeline_lines.clearRetainingCapacity();
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

    const PromptContextSummary = struct {
        blocks: usize,
        files: usize,
        used_bytes: usize,
    };

    fn pushStartupIntro(self: *App) !void {
        try self.pushSystem("FORGE Coding Assistant initialized.");

        var line_buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(
            &line_buf,
            "Workspace ready: {s} · {s} · prompt context builds after you ask",
            .{
                commands.modeLabel(self.agent_mode),
                self.model_label,
            },
        ) catch "Workspace ready";
        try self.pushSystem(line);
    }

    fn refreshContextLabel(self: *App, intent: []const u8) ?PromptContextSummary {
        const explicit = self.explicitFilesSnapshot();
        defer {
            for (explicit) |f| self.allocator.free(f);
            if (explicit.len > 0) self.allocator.free(explicit);
        }
        var embedding = ai_workflow.embeddingOptionsFromFlags(self.allocator, self.parsed.flags, self.io, self.opened.root);
        defer embedding.deinit(self.allocator);

        const route = ai.route_resolver.resolveHeuristic(.{
            .mode = self.agent_mode,
            .intent = intent,
            .has_active_file = self.parsed.flags.files.len > 0,
        }, .{
            .intent = intent,
            .explicit_files = explicit,
            .max_bytes = contextBudgetBytes(self.parsed.flags),
            .workspace_cwd = self.opened.path,
            .embedding = embedding.options,
        }).route;

        var ctx_builder = ai.context_loader.build(self.allocator, self.io, self.opened.root, route.context) catch return null;
        defer ctx_builder.deinit();

        var files: usize = 0;
        for (ctx_builder.blocks.items) |block| {
            if (block.block_type == .file or block.block_type == .recent) files += 1;
        }

        var label_buf: [128]u8 = undefined;
        const label = std.fmt.bufPrint(
            &label_buf,
            "{d} files {d} blocks {d}kB",
            .{ files, ctx_builder.blocks.items.len, ctx_builder.used_bytes / 1024 },
        ) catch return null;
        const owned = self.allocator.dupe(u8, label) catch return null;
        self.mutex.lock();
        self.allocator.free(self.context_label);
        self.context_label = owned;
        self.mutex.unlock();

        return .{
            .blocks = ctx_builder.blocks.items.len,
            .files = files,
            .used_bytes = ctx_builder.used_bytes,
        };
    }

    fn promptPrefix(self: *const App, buf: []u8) ![]const u8 {
        const folder = self.folder_label;
        if (std.mem.eql(u8, self.branch_label, "no branch")) {
            return std.fmt.bufPrint(buf, "➜ {s} ", .{folder});
        }
        return std.fmt.bufPrint(buf, "➜ {s} git:({s}) ", .{ folder, self.branch_label });
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
        if (self.session_grants.isGranted(tool_name, policy)) return true;

        self.approval.mutex.lock();
        self.approval.pending = true;
        self.approval.decided = false;
        self.approval.approved = false;
        self.approval.session_grant = false;
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
        const session = self.approval.session_grant;
        self.approval.mutex.unlock();

        if (approved and session) {
            self.session_grants.grant(tool_name, .session) catch {};
            var grant_buf: [128]u8 = undefined;
            const grant_msg = std.fmt.bufPrint(&grant_buf, "Granted session auto-approval for {s}", .{tool_name}) catch return approved;
            self.pushLine(.system, self.allocator.dupe(u8, grant_msg) catch return approved) catch {};
        }

        return approved;
    }

    fn onStepBegin(self: *App, index: u32, tool_name: []const u8, args_json: []const u8) void {
        self.mutex.lock();
        const len = @min(tool_name.len, self.active_tool.len);
        @memcpy(self.active_tool[0..len], tool_name[0..len]);
        self.active_tool_len = len;
        self.active_tool_running = true;
        self.stream_line_index = null;
        self.active_progress_len = 0;
        self.markDirty();
        self.mutex.unlock();

        var buf: [512]u8 = undefined;
        const line = self.formatToolBegin(&buf, tool_name, args_json, index);
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
        const label = toolDoneLabel(kind);
        const line = if (line_count > 4)
            std.fmt.bufPrint(&buf, "✓ {s} · {d} output lines hidden · ctrl+r to review · {s}", .{ label, line_count, clipped }) catch return
        else if (clipped.len > 0)
            std.fmt.bufPrint(&buf, "✓ {s} · {s}", .{ label, clipped }) catch return
        else
            std.fmt.bufPrint(&buf, "✓ {s}", .{label}) catch return;
        self.pushLine(.tool, self.allocator.dupe(u8, line) catch return) catch {};
        self.refreshStatus() catch {};
    }

    fn formatToolBegin(self: *App, buf: []u8, tool_name: []const u8, args_json: []const u8, index: u32) []const u8 {
        if (std.mem.eql(u8, tool_name, "read_file")) {
            if (ai.tool_args.parseReadFileArgs(self.allocator, args_json)) |args| {
                defer self.allocator.free(args.path);
                if (args.start_line != null and args.end_line != null) {
                    return std.fmt.bufPrint(buf, "› Reading {s} lines {d}-{d} · step {d}", .{ args.path, args.start_line.?, args.end_line.?, index }) catch "› Reading file";
                }
                return std.fmt.bufPrint(buf, "› Reading {s} · step {d}", .{ args.path, index }) catch "› Reading file";
            } else |_| {}
        }

        if (std.mem.eql(u8, tool_name, "search")) {
            if (ai.tool_args.parseSearchArgs(self.allocator, args_json)) |args| {
                defer {
                    self.allocator.free(args.pattern);
                    self.allocator.free(args.path);
                    if (args.glob) |glob| self.allocator.free(glob);
                }
                const scope = args.glob orelse args.path;
                return std.fmt.bufPrint(buf, "› Searching \"{s}\" in {s} · step {d}", .{ args.pattern, scope, index }) catch "› Searching files";
            } else |_| {}
        }

        if (std.mem.eql(u8, tool_name, "codebase_search")) {
            if (ai.tool_args.parseCodebaseQuery(self.allocator, args_json)) |query| {
                defer self.allocator.free(query);
                return std.fmt.bufPrint(buf, "› Semantic search \"{s}\" · step {d}", .{ query, index }) catch "› Semantic search";
            } else |_| {}
        }

        if (std.mem.eql(u8, tool_name, "list_tree")) {
            if (ai.tool_args.parseListTreeArgs(self.allocator, args_json)) |args| {
                defer self.allocator.free(args.path);
                return std.fmt.bufPrint(buf, "› Listing {s} depth {d} · step {d}", .{ args.path, args.depth, index }) catch "› Listing directory";
            } else |_| {}
        }

        if (std.mem.eql(u8, tool_name, "run_command")) {
            if (ai.tool_args.parseRunCommand(self.allocator, args_json)) |command| {
                defer self.allocator.free(command);
                return std.fmt.bufPrint(buf, "› Running `{s}` · step {d}", .{ command, index }) catch "› Running command";
            } else |_| {}
        }

        if (std.mem.eql(u8, tool_name, "replace_file_content") or std.mem.eql(u8, tool_name, "propose_edit")) {
            if (formatEditToolBegin(buf, args_json, index)) |line| return line;
        }

        var args_buf: [160]u8 = undefined;
        const args_preview = compactArgs(&args_buf, args_json);
        const action = getToolAction(tool_name);
        if (args_preview.len > 0) {
            return std.fmt.bufPrint(buf, "› {s} {s} · step {d}", .{ action, args_preview, index }) catch action;
        }
        return std.fmt.bufPrint(buf, "› {s} · step {d}", .{ action, index }) catch action;
    }

    fn formatEditToolBegin(buf: []u8, args_json: []const u8, index: u32) ?[]const u8 {
        const Args = struct {
            path: ?[]const u8 = null,
            summary: ?[]const u8 = null,
            start_line: ?usize = null,
            end_line: ?usize = null,
        };
        var parsed = std.json.parseFromSlice(Args, std.heap.page_allocator, args_json, .{ .ignore_unknown_fields = true }) catch return null;
        defer parsed.deinit();
        const path = parsed.value.path orelse return null;
        if (parsed.value.summary) |summary| {
            return std.fmt.bufPrint(buf, "› Editing {s} · {s} · step {d}", .{ path, summary, index }) catch null;
        }
        if (parsed.value.start_line != null and parsed.value.end_line != null) {
            return std.fmt.bufPrint(buf, "› Editing {s} lines {d}-{d} · step {d}", .{ path, parsed.value.start_line.?, parsed.value.end_line.?, index }) catch null;
        }
        return std.fmt.bufPrint(buf, "› Editing {s} · step {d}", .{ path, index }) catch null;
    }

    fn toolDoneLabel(kind: []const u8) []const u8 {
        if (std.mem.eql(u8, kind, "read_file")) return "Read";
        if (std.mem.eql(u8, kind, "search")) return "Search";
        if (std.mem.eql(u8, kind, "codebase_search")) return "Semantic search";
        if (std.mem.eql(u8, kind, "list_tree")) return "Tree";
        if (std.mem.eql(u8, kind, "run_command")) return "Run";
        if (std.mem.eql(u8, kind, "replace_file_content")) return "Write";
        if (std.mem.eql(u8, kind, "propose_edit")) return "Edit";
        if (std.mem.eql(u8, kind, "apply_proposal")) return "Apply";
        return kind;
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
        if (std.mem.startsWith(u8, text, "FORGE Coding Assistant initialized.")) return term.Style.gray;
        if (std.mem.startsWith(u8, text, "Context: ")) return term.Style.gray;
        if (std.mem.startsWith(u8, text, "Edited ")) return term.Style.bright_yellow;
        if (std.mem.startsWith(u8, text, "› ")) return term.Style.gray;
        if (std.mem.startsWith(u8, text, "$ ")) return term.Style.bright_yellow;
        if (std.mem.startsWith(u8, text, "ok ") or std.mem.startsWith(u8, text, "✓ ")) return term.Style.bright_green;
        if (std.mem.startsWith(u8, text, "↻ ")) return term.Style.magenta;
        return switch (kind) {
            .user => term.Style.white,
            .agent => term.Style.green,
            .tool => term.Style.yellow,
            .system => term.Style.gray,
            .failure => term.Style.red,
        };
    }

    fn bgForLine(text: []const u8) ?[]const u8 {
        if (text.len > 0 and text[0] == '+') return term.Style.bg_green;
        if (text.len > 0 and text[0] == '-') return term.Style.bg_red;
        return null;
    }

    fn decorateLine(self: *const App, kind: LineKind, text: []const u8) ![]u8 {
        return switch (kind) {
            .user => self.formatPromptLine(text),
            .failure => std.fmt.allocPrint(self.allocator, "× {s}", .{text}),
            else => self.allocator.dupe(u8, text),
        };
    }

    fn formatPromptLine(self: *const App, text: []const u8) ![]u8 {
        var prefix_buf: [256]u8 = undefined;
        const prefix = try self.promptPrefix(&prefix_buf);
        return std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, text });
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

        self.approval.mutex.lock();
        const pending = self.approval.pending;
        var approve_buf: [512]u8 = undefined;
        const approve_line = if (pending) blk: {
            const tool = self.approval.tool_name[0..self.approval.tool_name_len];
            const preview = self.approval.args_preview[0..@min(self.approval.args_preview_len, 120)];
            const can_session = if (self.approval.risk == .high and !self.parsed.flags.auto_approve) false else true;
            if (can_session) {
                break :blk std.fmt.bufPrint(
                    &approve_buf,
                    "Allow {s}? [y/N/s(ession)] {s}",
                    .{ tool, preview },
                ) catch "Allow tool? [y/N/s]";
            } else {
                break :blk std.fmt.bufPrint(
                    &approve_buf,
                    "Allow {s}? [y/N] {s}",
                    .{ tool, preview },
                ) catch "Allow tool? [y/N]";
            }
        } else "";
        self.approval.mutex.unlock();

        const approval_rows: u16 = if (pending) 1 else 0;
        const footer_rows: u16 = filtered_len + approval_rows;
        if (size.rows <= footer_rows + 1) return;
        const chat_rows = size.rows - footer_rows;

        self.frame.begin();

        var wrapped_cache: std.ArrayList([]const u8) = .empty;
        defer {
            for (wrapped_cache.items) |line| self.allocator.free(line);
            wrapped_cache.deinit(self.allocator);
        }

        var display_lines: std.ArrayList(struct { kind: LineKind, text: []const u8 }) = .empty;
        defer display_lines.deinit(self.allocator);

        var block_states: std.ArrayList(u8) = .empty;
        defer block_states.deinit(self.allocator);
        // 0: none, 1: thinking, 2: diff

        const explorer_width: u16 = if (self.show_explorer) self.cli_config.explorer_width else 0;
        const remaining_cols: u16 = if (self.show_explorer) size.cols - explorer_width - 1 else size.cols;
        const editor_width: u16 = if (self.show_editor) remaining_cols / 2 else 0;
        const chat_cols: u16 = if (self.show_editor) remaining_cols - editor_width - 1 else remaining_cols;

        const editor_x: u16 = if (self.show_explorer) explorer_width + 2 else 1;
        const chat_x: u16 = if (self.show_editor) editor_x + editor_width + 1 else editor_x;
        const width = @max(20, @as(usize, chat_cols) - 2);
        const source_lines = if (self.show_timeline)
            self.timeline_lines.items
        else if (self.show_events)
            self.events_lines.items
        else
            self.lines.items;
        const source_scroll_ptr: *usize = if (self.show_timeline)
            &self.timeline_scroll
        else if (self.show_events)
            &self.events_scroll
        else
            &self.scroll;

        var current_block: u8 = 0;

        for (source_lines) |line| {
            if (line.kind == .agent) {
                if (line.text.len > 0 and (line.text[0] == '>' or line.text[0] == '!')) {
                    current_block = 1;
                } else if (current_block == 1 and line.text.len > 0 and line.text[0] != '>' and line.text[0] != '!' and !std.mem.startsWith(u8, line.text, "Thinking")) {
                    current_block = 0;
                } else if (std.mem.startsWith(u8, line.text, "```")) {
                    current_block = if (current_block == 2) 0 else 2;
                }
            }

            const decorated = self.decorateLine(line.kind, line.text) catch continue;
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
                const block_state: u8 = if (line.kind == .tool) 1 else current_block;
                block_states.append(self.allocator, block_state) catch {};
            }
        }

        if (self.agent_busy) {
            var thinking_buf: [128]u8 = undefined;
            const status_line = self.liveThinkingLabel(&thinking_buf);
            if (self.allocator.dupe(u8, status_line)) |owned_status| {
                wrapped_cache.append(self.allocator, owned_status) catch self.allocator.free(owned_status);
                display_lines.append(self.allocator, .{ .kind = .agent, .text = owned_status }) catch {};
                block_states.append(self.allocator, 0) catch {};
            } else |_| {}
        } else if (!self.show_events and !self.show_timeline) {
            if (self.formatPromptLine(self.input.items)) |owned_prompt| {
                wrapped_cache.append(self.allocator, owned_prompt) catch self.allocator.free(owned_prompt);
                display_lines.append(self.allocator, .{ .kind = .user, .text = owned_prompt }) catch {};
                block_states.append(self.allocator, 0) catch {};
            } else |_| {}
        }

        const total = display_lines.items.len;
        const max_scroll = if (total > chat_rows) total - chat_rows else 0;
        if (source_scroll_ptr.* > max_scroll) source_scroll_ptr.* = max_scroll;
        const start = if (total > chat_rows) total - chat_rows - source_scroll_ptr.* else 0;
        const end = @min(total, start + chat_rows);

        var row: u16 = 1;
        var scratch: [512]u8 = undefined;
        var live_prompt_row: ?u16 = null;
        for (display_lines.items[start..end], start..) |line, i| {
            const block = block_states.items[i];
            const color = colorForLine(line.kind, line.text);

            const padding: usize = if (block > 0) 2 else 0;
            const content_cols = chat_cols - 1 - padding * 2;
            const clipped = term.truncateEnd(&scratch, line.text, @intCast(content_cols));

            self.frame.moveTo(row, chat_x);

            // Left padding
            if (padding > 0) {
                if (self.term.use_color) self.frame.appendSlice(term.Style.bg_block) catch {};
                self.frame.data.appendNTimes(self.allocator, ' ', padding) catch {};
            }

            if (line.kind == .user) {
                if (!self.agent_busy and !self.show_events and !self.show_timeline and i + 1 == total) live_prompt_row = row;
                var prefix_buf: [256]u8 = undefined;
                const prefix = self.promptPrefix(&prefix_buf) catch "";
                const prefix_part = if (std.mem.startsWith(u8, clipped, prefix)) prefix else "";
                if (self.term.use_color) self.frame.appendSlice(term.Style.green) catch {};
                self.frame.appendSlice(prefix_part) catch {};
                if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
                if (padding > 0 and self.term.use_color) self.frame.appendSlice(term.Style.bg_block) catch {};
                if (self.term.use_color) self.frame.appendSlice(term.Style.white) catch {};
                self.frame.appendSlice(clipped[prefix_part.len..]) catch {};
            } else if (std.mem.startsWith(u8, clipped, "Thinking")) {
                if (self.term.use_color) self.frame.appendSlice(term.Style.blue) catch {};
                self.frame.appendSlice(clipped) catch {};
            } else {
                if (self.term.use_color) self.frame.appendSlice(color) catch {};
                if (self.term.use_color) {
                    if (bgForLine(line.text)) |bg| {
                        self.frame.appendSlice(bg) catch {};
                    } else if (padding > 0) {
                        self.frame.appendSlice(term.Style.bg_block) catch {};
                    }
                }
                self.frame.appendSlice(clipped) catch {};
            }

            // Right padding and fill
            if (clipped.len < content_cols) {
                if (self.term.use_color) {
                    if (bgForLine(line.text)) |bg| {
                        self.frame.appendSlice(bg) catch {};
                    } else if (padding > 0) {
                        self.frame.appendSlice(term.Style.bg_block) catch {};
                    }
                }
                self.frame.data.appendNTimes(self.allocator, ' ', content_cols - clipped.len + padding) catch {};
            } else if (padding > 0) {
                if (self.term.use_color) {
                    if (bgForLine(line.text)) |bg| {
                        self.frame.appendSlice(bg) catch {};
                    } else {
                        self.frame.appendSlice(term.Style.bg_block) catch {};
                    }
                }
                self.frame.data.appendNTimes(self.allocator, ' ', padding) catch {};
            }

            self.frame.appendSlice("\x1b[K") catch {};
            if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
            row += 1;
        }
        while (row <= chat_rows) : (row += 1) {
            self.frame.moveTo(row, chat_x);
            self.frame.data.appendNTimes(self.allocator, ' ', chat_cols) catch {};
        }

        var footer_row = chat_rows + 1;

        if (show_commands) {
            for (filtered[0..filtered_len], 0..) |cmd, i| {
                const cmd_row = footer_row + @as(u16, @intCast(i));
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
            footer_row += filtered_len;
        }

        if (pending) {
            var folder_scratch: [256]u8 = undefined;
            if (self.term.use_color) self.frame.appendSlice(term.Style.magenta) catch {};
            self.frame.writeRow(footer_row, size.cols, term.truncateEnd(&folder_scratch, approve_line, @intCast(size.cols - 1)));
            if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
            footer_row += 1;
        }

        // Place the real terminal cursor at the input caret, then reveal it.
        if (!self.agent_busy and !pending and live_prompt_row != null) {
            var prompt_buf: [512]u8 = undefined;
            const prompt_prefix = self.promptPrefix(&prompt_buf) catch "➜ project ";
            const prefix_cols = term.displayWidth(prompt_prefix);
            const avail = if (@as(usize, size.cols) > prefix_cols + 1) @as(usize, size.cols) - prefix_cols - 1 else 0;
            const cursor_cols = @min(
                avail,
                term.displayWidth(self.input.items[0..@min(self.cursor, self.input.items.len)]),
            );
            const caret_col: u16 = @intCast(@min(
                @as(usize, size.cols),
                prefix_cols + cursor_cols + 1,
            ));
            self.frame.moveTo(live_prompt_row.?, caret_col);
            self.frame.appendSlice("\x1b[?25h") catch {};
        } else {
            self.frame.appendSlice("\x1b[?25l") catch {};
        }

        if (self.show_editor) {
            var b_row: u16 = 1;
            while (b_row <= size.rows) : (b_row += 1) {
                self.frame.moveTo(b_row, editor_x + editor_width);
                if (self.term.use_color) self.frame.appendSlice(term.Style.dim) catch {};
                self.frame.appendSlice("│") catch {};
                if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
            }

            var e_row: u16 = 1;
            self.frame.moveTo(e_row, editor_x);
            if (!self.focus_explorer) {
                if (self.term.use_color) self.frame.appendSlice(term.Style.invert) catch {};
                if (self.term.use_color) self.frame.appendSlice(term.Style.green) catch {};
                self.frame.appendSlice(" EDITOR ") catch {};
            } else {
                if (self.term.use_color) self.frame.appendSlice(term.Style.invert) catch {};
                if (self.term.use_color) self.frame.appendSlice(term.Style.dim) catch {};
                self.frame.appendSlice(" EDITOR ") catch {};
            }
            if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
            e_row += 1;

            if (self.editor_buffer) |buf| {
                const max_lines = chat_rows - 1;
                const total_lines = buf.lines.items.len;
                const start_idx = 0; // TODO: scroll_y
                const end_idx = @min(start_idx + max_lines, total_lines);
                for (buf.lines.items[start_idx..end_idx], start_idx..) |line, i| {
                    _ = i;
                    self.frame.moveTo(e_row, editor_x);
                    var scratch_line: [512]u8 = undefined;
                    const clipped = term.truncateEnd(&scratch_line, line.items, editor_width);
                    self.frame.appendSlice(clipped) catch {};
                    e_row += 1;
                }
            }
        }

        if (self.show_explorer) {
            var b_row: u16 = 1;
            while (b_row <= size.rows) : (b_row += 1) {
                self.frame.moveTo(b_row, explorer_width + 1);
                if (self.term.use_color) self.frame.appendSlice(term.Style.dim) catch {};
                self.frame.appendSlice("│") catch {};
                if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
            }
            if (self.scan_summary) |s| {
                var e_row: u16 = 1;
                self.frame.moveTo(e_row, 1);
                if (self.focus_explorer) {
                    if (self.term.use_color) self.frame.appendSlice(term.Style.invert) catch {};
                    if (self.term.use_color) self.frame.appendSlice(term.Style.green) catch {};
                    self.frame.appendSlice(" EXPLORER (Focused) ") catch {};
                } else {
                    if (self.term.use_color) self.frame.appendSlice(term.Style.invert) catch {};
                    if (self.term.use_color) self.frame.appendSlice(term.Style.dim) catch {};
                    self.frame.appendSlice(" EXPLORER ") catch {};
                }
                if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
                e_row += 1;
                const max_items = if (chat_rows > 1) chat_rows - 1 else 0;
                const total_items = s.entries.len;
                const start_idx = @min(self.explorer_scroll_y, total_items);
                const end_idx = @min(start_idx + max_items, total_items);
                for (s.entries[start_idx..end_idx], start_idx..) |entry, i| {
                    self.frame.moveTo(e_row, 1);
                    var buf: [256]u8 = undefined;
                    const name = std.fs.path.basename(entry.path);
                    const prefix = if (entry.kind == .directory) "▸ " else "  ";
                    const line = std.fmt.bufPrint(&buf, "{s}{s}", .{ prefix, name }) catch "";
                    var scratch2: [512]u8 = undefined;
                    const clipped = term.truncateEnd(&scratch2, line, explorer_width);

                    const is_selected = (i == self.explorer_scroll_y) and self.focus_explorer;
                    if (is_selected) {
                        if (self.term.use_color) self.frame.appendSlice(term.Style.invert) catch {};
                    }
                    self.frame.appendSlice(clipped) catch {};
                    if (clipped.len < explorer_width) {
                        self.frame.data.appendNTimes(self.allocator, ' ', explorer_width - clipped.len) catch {};
                    }
                    if (is_selected) {
                        if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
                    }
                    e_row += 1;
                }
            }
        }
        self.frame.flush();
    }

    fn liveThinkingLabel(self: *const App, buf: []u8) []const u8 {
        const progress = self.active_progress[0..self.active_progress_len];
        if (progress.len > 0 and !std.mem.startsWith(u8, progress, "Thinking")) return progress;

        const now_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        const dots: usize = @intCast(@mod(@divTrunc(now_ms, 320), 3) + 1);
        return std.fmt.bufPrint(buf, "Thinking{s}", .{"..."[0..dots]}) catch "Thinking...";
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
    app.pushLine(.system, app.allocator.dupe(u8, "Building prompt context...") catch return) catch {};

    const parsed = app.parsed;
    var provider_opts = ai_workflow.agentProviderOptionsFromFlags(app.allocator, parsed.flags, intent, app.io, app.opened.root);
    provider_opts.options.stream_callback = streamBridge;
    provider_opts.options.stream_context = app;
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
    var embedding = ai_workflow.embeddingOptionsFromFlags(app.allocator, parsed.flags, app.io, app.opened.root);
    defer embedding.deinit(app.allocator);

    const agent_config = ai.agent.Config{
        .max_steps = max_steps,
        .context_max_bytes = contextBudgetBytes(parsed.flags),
        .embedding = embedding.options,
        .provider_options = provider_opts.options,
        .mode = app.agent_mode,
        .capability_profile = capabilityForMode(app.agent_mode, parsed.flags),
        .auto_capability = parsed.flags.capability == null and app.agent_mode == .agent,
        .workspace_cwd = app.opened.path,
        .explicit_files = explicit_files,
        .conversation = conversation_snapshot,
        .surface = .cli,
        .cancel_token = &cancel_token,
        .max_repair_attempts = if (std.mem.eql(u8, provider_opts.options.provider_name, "fake")) 0 else 2,
        .approve_every_time_tools = false,
        .approval_callback = approvalBridge,
        .approval_context = app,
        .step_begin_callback = stepBeginBridge,
        .step_begin_context = app,
        .step_callback = stepBridge,
        .step_context = app,
        .turn_callback = turnBridge,
        .turn_context = app,
        .compaction_callback = compactionBridge,
        .compaction_context = app,
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
            const msg = agentErrorMessage(app.allocator, err) catch {
                app.workerDone(ctx, .{ .err = app.allocator.dupe(u8, "Agent error") catch return });
                return;
            };
            app.workerDone(ctx, .{ .err = msg });
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

fn agentErrorMessage(allocator: std.mem.Allocator, err: ai.agent.AgentError) ![]u8 {
    const text: []const u8 = switch (err) {
        error.ProviderFailed => "Agent error: LLM provider failed (timeout, malformed response, or context too long). Try again, use a shorter request, or run `forge agent resume <session_id>`.",
        error.ContextLengthExceeded => "Agent error: compacted context is still too long for the model. Resume, reduce attachments, or switch to a larger-context model.",
        error.NetworkError => "Agent error: cannot reach Ollama. Check `ollama serve` and OLLAMA_HOST.",
        error.StepLimitReached => "Agent error: step limit reached; compact checkpoint saved. Resume the session or increase --max-steps.",
        error.DuplicateLoop => "Agent error: agent repeated the same tool calls. Give a more specific file/symbol or use /resume.",
        error.NoProgress => "Agent error: no progress after broad searches. Point to a specific file or task.",
        else => return std.fmt.allocPrint(allocator, "Agent error: {s}", .{@errorName(err)}),
    };
    return allocator.dupe(u8, text);
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
    var buf: [512]u8 = undefined;
    const args = if (step.args_json.len > 220) step.args_json[0..220] else step.args_json;
    const line = std.fmt.bufPrint(&buf, "#{d} call {s} {s}", .{ step.index, step.tool_name, args }) catch return;
    app.pushTimelineLine(.tool, app.allocator.dupe(u8, line) catch return) catch {};
}

fn stepBridge(context: ?*anyopaque, step: ai.agent.Step) void {
    const app: *App = @ptrCast(@alignCast(context.?));
    app.onStepDone(step.index, step.kind, step.summary);
    var buf: [512]u8 = undefined;
    const summary = if (step.summary.len > 260) step.summary[0..260] else step.summary;
    const line = std.fmt.bufPrint(&buf, "#{d} done {s} · {s}", .{ step.index, step.kind, summary }) catch return;
    app.pushTimelineLine(.tool, app.allocator.dupe(u8, line) catch return) catch {};
}

fn turnBridge(context: ?*anyopaque, next_step_index: u32) void {
    const app: *App = @ptrCast(@alignCast(context.?));
    var buf: [96]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "turn · next step {d}", .{next_step_index}) catch "turn";
    app.pushTimelineLine(.agent, app.allocator.dupe(u8, line) catch return) catch {};
    app.mutex.lock();
    app.stream_line_index = null;
    const label = "Thinking...";
    const len = @min(label.len, app.active_progress.len);
    @memcpy(app.active_progress[0..len], label[0..len]);
    app.active_progress_len = len;
    app.markDirty();
    app.mutex.unlock();
}

fn compactionBridge(context: ?*anyopaque, reason: []const u8, before_bytes: usize, after_bytes: usize, step_index: u32, attempt: u8) void {
    const app: *App = @ptrCast(@alignCast(context.?));
    var buf: [192]u8 = undefined;
    const line = std.fmt.bufPrint(
        &buf,
        "Compacted context: {s} · step {d} · attempt {d} · {d}kB -> {d}kB",
        .{ reason, step_index, attempt, before_bytes / 1024, after_bytes / 1024 },
    ) catch return;
    app.pushLine(.system, app.allocator.dupe(u8, line) catch return) catch {};
    app.pushTimelineLine(.system, app.allocator.dupe(u8, line) catch return) catch {};
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

    switch (phase) {
        .context_built => {
            app.mutex.lock();
            app.active_progress_len = 0;
            app.markDirty();
            app.mutex.unlock();
            app.pushLine(.system, app.allocator.dupe(u8, "Context ready. Retrieval and tool evidence will appear below.") catch return) catch {};
            app.pushTimelineLine(.system, app.allocator.dupe(u8, "context · ready") catch return) catch {};
        },
        .plan_ready, .proposal_ready => {
            var buf: [64]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "● {s}", .{label}) catch return;
            app.pushLine(.system, app.allocator.dupe(u8, line) catch return) catch {};
            app.pushTimelineLine(.system, app.allocator.dupe(u8, line) catch return) catch {};
        },
        .planning, .sending, .streaming, .parsing, .repairing => {
            app.mutex.lock();
            const len = @min(label.len, app.active_progress.len);
            @memcpy(app.active_progress[0..len], label[0..len]);
            app.active_progress_len = len;
            app.markDirty();
            app.mutex.unlock();
            var buf: [96]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "phase · {s}", .{label}) catch return;
            app.pushTimelineLine(.system, app.allocator.dupe(u8, line) catch return) catch {};
        },
    }
}

fn workspaceDisplayNameAlloc(
    allocator: std.mem.Allocator,
    environ_map: ?*const std.process.Environ.Map,
    workspace_path: []const u8,
) ![]u8 {
    if (std.mem.eql(u8, workspace_path, ".") or workspace_path.len == 0) {
        if (environ_map) |env| {
            if (env.get("PWD")) |pwd| {
                const base = std.fs.path.basename(pwd);
                if (base.len > 0 and !std.mem.eql(u8, base, ".")) {
                    return allocator.dupe(u8, base);
                }
            }
        }
    }

    const base = std.fs.path.basename(workspace_path);
    if (base.len > 0 and !std.mem.eql(u8, base, ".")) return allocator.dupe(u8, base);
    return allocator.dupe(u8, "workspace");
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
    workspace_cmd.scheduleSemanticIndex(allocator, io, environ_map, opened);

    var scope = try cancel_scope_mod.Scope.init(allocator);
    defer scope.deinit();

    var terminal = try term.Terminal.init(!parsed.flags.no_color);

    var app = try App.init(allocator, io, environ_map, opened, parsed, terminal, scope);
    defer app.deinit();

    if (parsed.flags.conversation) |session_id| {
        try app.resumeSession(session_id);
    }

    const code = try app.run();
    app.printResumeHintToStdout(io) catch {};
    terminal.deinit();
    return code;
}
