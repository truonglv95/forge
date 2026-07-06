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
        try app.pushSystem("Forge agent — Enter send | Tab policy | @file context | d diff a apply | Ctrl+C cancel/quit");
        app.showRecentSession();
        return app;
    }

    fn showRecentSession(self: *App) void {
        var list = workspace.sessions.listEntries(self.allocator, self.io, self.opened.root) catch return;
        defer list.deinit();
        if (list.items.len == 0) return;
        const latest = list.items[list.items.len - 1];
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &buf,
            "Last session {s}: \"{s}\" — resume with `forge agent resume {s}`",
            .{ latest.session_id, latest.intent, latest.session_id },
        ) catch return;
        self.pushLine(.system, self.allocator.dupe(u8, msg) catch return) catch {};
    }

    pub fn deinit(self: *App) void {
        if (self.worker) |thread| thread.join();
        self.freeLines();
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
        self.frame.deinit();
        self.approval.cond.deinit();
        self.approval.mutex.deinit();
        self.mutex.deinit();
    }

    pub fn run(self: *App) !u8 {
        self.cancel_scope.installSigint();
        while (!self.quit) {
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
            .tab => {
                self.mutex.lock();
                if (self.focus_action) {
                    self.tool_policy = self.tool_policy.next();
                } else {
                    self.focus_action = true;
                }
                self.markDirty();
                self.mutex.unlock();
            },
            .escape => {
                self.mutex.lock();
                self.focus_action = false;
                self.markDirty();
                self.mutex.unlock();
            },
            .enter => try self.submitInput(),
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
                self.cursor = 0;
                self.markDirty();
                self.mutex.unlock();
            },
            .end, .ctrl_e => {
                self.mutex.lock();
                self.cursor = self.input.items.len;
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
            .ctrl_w => {
                self.mutex.lock();
                self.deleteWordBackward();
                self.markDirty();
                self.mutex.unlock();
            },
            .up => self.recallHistory(-1),
            .down => self.recallHistory(1),
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
        if (self.history.items.len == 0) {
            if (direction < 0 and self.scroll > 0) self.scroll -= 1;
            if (direction > 0) self.scroll += 1;
            self.markDirty();
            return;
        }
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

        try self.extractFileMentions(raw);

        try self.pushLine(.user, raw);
        const intent = try self.allocator.dupe(u8, raw);
        try self.startAgent(intent);
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

    fn startAgent(self: *App, intent: []const u8) !void {
        const ctx = try self.allocator.create(WorkerCtx);
        ctx.* = .{
            .app = self,
            .intent = intent,
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
                self.pushLine(.failure, message) catch {};
                self.allocator.free(message);
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

    fn freeLines(self: *App) void {
        for (self.lines.items) |line| self.allocator.free(line.text);
        self.lines.clearRetainingCapacity();
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
        const mode = parseMode(self.parsed.flags.mode);
        const route = ai.routing.plan(.{
            .mode = mode,
            .intent = intent,
            .has_active_file = self.parsed.flags.files.len > 0,
        }, .{
            .intent = intent,
            .explicit_files = self.parsed.flags.files,
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

    fn onStepBegin(self: *App, index: u32, tool_name: []const u8) void {
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "step {d}: {s}…", .{ index, tool_name }) catch return;
        self.pushLine(.tool, self.allocator.dupe(u8, line) catch return) catch {};
    }

    fn onStepDone(self: *App, index: u32, kind: []const u8, summary: []const u8) void {
        _ = index;
        var buf: [1024]u8 = undefined;
        const clipped = if (summary.len > 700) summary[0..700] else summary;
        const line = std.fmt.bufPrint(&buf, "[{s}] {s}", .{ kind, clipped }) catch return;
        self.pushLine(.tool, self.allocator.dupe(u8, line) catch return) catch {};
        self.refreshStatus() catch {};
    }

    fn render(self: *App) void {
        const size = self.term.size();
        const footer_rows: u16 = 3;
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
        for (self.lines.items) |line| {
            const wrapped = term.wrapLines(self.allocator, line.text, width) catch continue;
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

        const total = display_lines.items.len;
        const max_scroll = if (total > chat_rows) total - chat_rows else 0;
        if (self.scroll > max_scroll) self.scroll = max_scroll;
        const start = if (total > chat_rows) total - chat_rows - self.scroll else 0;
        const end = @min(total, start + chat_rows);

        var row: u16 = 1;
        var scratch: [512]u8 = undefined;
        for (display_lines.items[start..end]) |line| {
            const color = switch (line.kind) {
                .user => term.Style.cyan,
                .agent => term.Style.green,
                .tool => term.Style.yellow,
                .system => term.Style.dim,
                .failure => term.Style.red,
            };
            const clipped = term.truncateEnd(&scratch, line.text, @intCast(size.cols - 1));
            self.frame.moveTo(row, 1);
            if (self.term.use_color) self.frame.appendSlice(color) catch {};
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

        const input_row = size.rows - 2;
        const status_row = size.rows - 1;
        const action_row = size.rows;

        var input_line: [576]u8 = undefined;
        const prompt = if (self.agent_busy) " … " else " > ";
        const prompt_w: usize = 3;
        const avail = size.cols - @min(size.cols, prompt_w + 1);
        const input_view = term.truncateEnd(&scratch, self.input.items, @intCast(avail));
        const input_text = std.fmt.bufPrint(&input_line, "{s}{s}", .{ prompt, input_view }) catch prompt;
        self.frame.writeRow(input_row, size.cols, input_text);

        var status_buf: [1024]u8 = undefined;
        var folder_scratch: [256]u8 = undefined;
        const folder = term.truncateEnd(&folder_scratch, self.folder_label, 28);
        const status = std.fmt.bufPrint(
            &status_buf,
            "model:{s}  ctx:{s}  {s}  {s}  {s}",
            .{ self.model_label, self.context_label, self.edited_label, folder, self.branch_label },
        ) catch "";
        if (self.term.use_color) self.frame.appendSlice(term.Style.dim) catch {};
        self.frame.writeRow(status_row, size.cols, term.truncateEnd(&folder_scratch, status, @intCast(size.cols - 1)));
        if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};

        const action_label = self.tool_policy.label();
        const action_text = if (self.focus_action)
            std.fmt.bufPrint(&status_buf, "[{s} ▶]", .{action_label}) catch action_label
        else
            std.fmt.bufPrint(&status_buf, " {s} ", .{action_label}) catch action_label;
        const action_col: u16 = if (@as(usize, size.cols) > action_text.len + 1)
            @intCast(size.cols - action_text.len)
        else
            1;
        self.frame.moveTo(action_row, action_col);
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

        fn deinit(self: OkPayload, allocator: std.mem.Allocator) void {
            if (self.response_text) |text| allocator.free(text);
            if (self.proposal_rel) |prop| allocator.free(prop);
        }
    };
};

const WorkerCtx = struct {
    app: *App,
    intent: []const u8,
};

fn workerMain(ctx: *WorkerCtx) void {
    const app = ctx.app;
    const intent = ctx.intent;

    app.appendConversation(.user, intent) catch {};
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
        .mode = modeFromFlags(parsed.flags),
        .capability_profile = capabilityFromFlags(parsed.flags),
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
        .progress_callback = progressBridge,
        .progress_context = app,
    };

    const result = ai.agent.run(
        app.allocator,
        app.io,
        app.environ_map,
        app.opened.root,
        intent,
        agent_config,
    ) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Agent error: {s}", .{@errorName(err)}) catch "Agent error";
        app.workerDone(ctx, .{ .err = app.allocator.dupe(u8, msg) catch return });
        return;
    };

    const payload = WorkerResult.OkPayload{
        .response_text = if (result.response_text) |text| app.allocator.dupe(u8, text) catch null else null,
        .proposal_rel = if (result.proposal_rel) |prop| app.allocator.dupe(u8, prop) catch null else null,
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
    app.onStepBegin(step.index, step.tool_name);
}

fn stepBridge(context: ?*anyopaque, step: ai.agent.Step) void {
    const app: *App = @ptrCast(@alignCast(context.?));
    app.onStepDone(step.index, step.kind, step.summary);
}

fn progressBridge(context: ?*anyopaque, phase: ai.progress.Phase) void {
    const app: *App = @ptrCast(@alignCast(context.?));
    var buf: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "[{s}]", .{@tagName(phase)}) catch return;
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

fn capabilityFromFlags(flags: args_mod.GlobalFlags) ai.tools.CapabilityProfile {
    const value = flags.capability orelse return ai.tools.profileForMode(.agent);
    if (std.mem.eql(u8, value, "read_only")) return .read_only;
    if (std.mem.eql(u8, value, "propose_and_task")) return .propose_and_task;
    return .propose;
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
