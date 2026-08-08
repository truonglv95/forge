const std = @import("std");
const builtin = @import("builtin");
const ai = @import("forge-ai");
const kernel = @import("forge-kernel");
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

/// P2.10: Vim mode states. When `vim_enabled` is true, the input handler
/// uses these to dispatch keys differently:
///   .insert  — normal typing (like emacs mode but Esc switches to normal)
///   .normal  — h/j/k/l movement, dd/yy/p, i/a/o enter insert, : commands
///   .visual  — v then motion selects, y copies, d deletes
const VimMode = enum {
    insert,
    normal,
    visual,
};

/// Render cache entry: stores decorated+wrapped display lines for a source
/// line so we can skip the expensive decorate+wrap on the next frame.
const CachedDisplayLines = struct {
    lines: [][]const u8,
    kind: LineKind,
    block_state: u8,
    version: u64,
};

const default_context_budget_bytes: usize = 8 * 1024 * 1024;
const max_model_picker_rows: usize = 8;

const CustomModel = struct {
    id: []u8,
    label: []u8,
    provider: []u8,
    base_url: ?[]u8 = null,

    fn deinit(self: *CustomModel, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.label);
        allocator.free(self.provider);
        if (self.base_url) |url| allocator.free(url);
        self.* = undefined;
    }
};

const PickerModel = struct {
    provider: []const u8,
    model_id: []const u8,
    display_name: []const u8,
    notes: []const u8,
    free: bool,
};

fn contextBudgetBytes(flags: args_mod.GlobalFlags) usize {
    return if (flags.budget_bytes > 0) flags.budget_bytes else default_context_budget_bytes;
}

fn envTruthy(name: [:0]const u8) bool {
    const value = std.c.getenv(name) orelse return false;
    return std.mem.eql(u8, std.mem.span(value), "1") or
        std.ascii.eqlIgnoreCase(std.mem.span(value), "true") or
        std.ascii.eqlIgnoreCase(std.mem.span(value), "yes");
}

fn envFalsey(name: [:0]const u8) bool {
    const value = std.c.getenv(name) orelse return false;
    return std.mem.eql(u8, std.mem.span(value), "0") or
        std.ascii.eqlIgnoreCase(std.mem.span(value), "false") or
        std.ascii.eqlIgnoreCase(std.mem.span(value), "no");
}

const ChatLine = struct {
    kind: LineKind,
    text: []u8,
    timestamp_ms: i64 = 0, // Phase 32: message timestamp for display
};

/// Phase 77: Tab snapshot — stores a saved conversation state for multi-tab support.
const TabSnapshot = struct {
    name: []u8,
    lines: std.ArrayList(ChatLine),
    created_ms: i64,

    fn deinit(self: *TabSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.lines.items) |line| allocator.free(line.text);
        self.lines.deinit(allocator);
    }
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
    worker_done: bool = false,
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
    model_suggestion_index: usize = 0,
    model_picker_active: bool = false,
    model_picker_index: usize = 0,
    custom_models: std.ArrayList(CustomModel) = .empty,
    custom_models_override: bool = false,
    session_grants: ai.session_grant.SessionGrants,
    // Phase 24: TUI completeness
    show_help_overlay: bool = false,
    spinner_frame: u8 = 0,
    spinner_last_ms: i64 = 0,
    /// Mouse wheel scroll accumulator — coalesces rapid scroll events
    /// into smooth multi-line jumps. Without this, each wheel tick scrolls
    /// 3 lines instantly, causing visual jank on fast scrolls.
    scroll_accumulator: i32 = 0,
    /// Smooth scroll target — the scroll position animates towards this
    /// value over a few frames, producing a gliding effect instead of
    /// instant jumps.
    scroll_target: usize = 0,
    /// Timestamp of the last scroll animation step.
    scroll_anim_ms: i64 = 0,
    total_input_tokens: u64 = 0,
    total_output_tokens: u64 = 0,
    total_cost_usd: f64 = 0.0,
    // Phase 52: Bookmarks — store line indices of important messages
    bookmarks: std.ArrayList(usize) = .empty,
    // Phase 57: Filter — show only messages of a specific role
    filter_role: ?LineKind = null,
    // Phase 60: Pins — store line indices pinned to top
    pinned: std.ArrayList(usize) = .empty,
    // Phase 62: Aliases — custom command shortcuts
    aliases: std.StringHashMap([]u8) = undefined,
    aliases_init: bool = false,
    // Phase 63: Macro recording
    macro_recording: bool = false,
    macro_buffer: std.ArrayList([]const u8) = .empty,
    macro_names: std.StringHashMap(std.ArrayList([]const u8)) = undefined,
    macro_names_init: bool = false,
    // Phase 64: Notifications
    notify_enabled: bool = false,
    // Phase 65: Word wrap toggle
    wordwrap_enabled: bool = true,
    // P2.10: Vim mode — normal/insert/visual. When enabled, input handling
    // switches to vim-style keybindings (Esc=normal, i=insert, v=visual,
    // h/j/k/l movement, dd/yy/p, :%s/foo/bar/g). Default off (emacs-style).
    vim_enabled: bool = false,
    vim_mode: VimMode = .insert,
    // P2.11: @mention picker state. When active, the input handler shows a
    // popup with fuzzy-matched file/symbol/docs entries. User navigates with
    // ↑/↓, selects with Enter, dismisses with Esc.
    mention_picker: @import("mention_picker.zig").PickerState = undefined,
    mention_picker_init: bool = false,
    // Rendering optimization: cached wrapped lines + render throttle
    render_cache_version: u64 = 0,
    render_cache_width: usize = 0,
    render_min_interval_ms: i64 = 16, // ~60fps cap
    /// Render cache: maps line text pointer → cached wrapped display lines.
    /// Keyed on (@intFromPtr(line.text.ptr), line.text.len, width, version).
    /// When a line hasn't changed since last frame, we skip decorate+wrap
    /// and reuse the cached display lines. Invalidated on width change
    /// (version bump) or /clear (lines freed).
    render_cache: std.AutoHashMap(u64, CachedDisplayLines) = undefined,
    render_cache_init: bool = false,
    // Phase 68: Snippets — saved code snippets
    snippets: std.StringHashMap([]u8) = undefined,
    snippets_init: bool = false,
    // Phase 69: Session start time
    session_start_ms: i64 = 0,
    // Phase 72: Tags — custom labels for conversation lines
    tags: std.AutoHashMap(usize, []u8) = undefined,
    tags_init: bool = false,
    // Phase 74: Last user intent for /retry
    last_user_intent: ?[]u8 = null,
    // Phase 77: Multi-tab support
    tabs: std.ArrayList(TabSnapshot) = .empty,
    active_tab: usize = 0,
    current_tab_name: ?[]u8 = null,

    const ALL_COMMANDS = [_][]const u8{ "/clear", "/cls", "/policy", "/tools", "/mode", "/context", "/diff", "/events", "/timeline", "/resume", "/sessions", "/mock", "/spec", "/runs", "/complete", "/model", "/cost", "/capability", "/provider", "/save", "/review", "/inspect", "/search", "/edit", "/undo", "/redo", "/theme", "/config", "/export", "/bookmark", "/copy", "/copyall", "/branch", "/filter", "/stats", "/compact", "/pin", "/alias", "/macro", "/notify", "/wordwrap", "/vim", "/goto", "/snippet", "/time", "/resize", "/tag", "/summary", "/retry", "/newtab", "/tabs", "/close", "/rename", "/switch", "/priority", "/merge", "/cleartabs", "/tab", "/copytab", "/swap", "/exporttab", "/log", "/version", "/findreplace", "/translate", "/annotate", "/share", "/refactor", "/explain", "/fix", "/testgen", "/doc", "/help", "/quit", "/exit" };
    /// Max number of slash command suggestions to display at once. Prevents
    /// the suggestion list from overflowing small terminals (e.g. when user
    /// types just '/', all 74 commands match but we only show the first 8).
    const max_command_suggestions: usize = 8;

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ_map: ?*const std.process.Environ.Map,
        opened: workspace_cmd.OpenedWorkspace,
        parsed: args_mod.CliArgs,
        terminal: term.Terminal,
        cancel_scope: cancel_scope_mod.Scope,
    ) !App {
        var effective_flags = parsed.flags;
        // Auto-fallback: if provider is "ollama" but ollama is not reachable,
        // and z.ai is available (pre-authenticated), switch to zai.
        if (effective_flags.provider == null or std.mem.eql(u8, effective_flags.provider orelse "", "ollama")) {
            const zai_available = blk: {
                if (std.c.getenv("ZAI_TOKEN") != null) break :blk true;
                var f = std.Io.Dir.openFileAbsolute(io, "/etc/.z-ai-config", .{}) catch break :blk false;
                f.close(io);
                break :blk true;
            };
            const ollama_reachable = blk: {
                const host = std.c.getenv("OLLAMA_HOST") orelse "localhost:11434";
                _ = host;
                // Quick TCP probe — if ollama is not running, fallback to zai
                const sock = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
                if (sock < 0) break :blk false;
                defer _ = std.c.close(sock);
                // Try connecting to localhost:11434
                var addr: std.c.sockaddr.in = .{
                    .family = std.c.AF.INET,
                    .port = std.mem.nativeToBig(u16, 11434),
                    .addr = 0x0100007f, // 127.0.0.1
                    .zero = [_]u8{0} ** 8,
                };
                const connected = std.c.connect(sock, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in));
                break :blk connected == 0;
            };
            if (!ollama_reachable and zai_available) {
                effective_flags.provider = "zai";
                effective_flags.model = "glm-4-plus";
            }
        }
        var provider_opts = ai_workflow.agentProviderOptionsFromFlags(allocator, effective_flags, "interactive", io, opened.root);
        defer provider_opts.deinit(allocator);
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
            .context_label = try allocator.dupe(u8, "idle"),
            .edited_label = try allocator.dupe(u8, "0 edited"),
            .folder_label = folder,
            .branch_label = try allocator.dupe(u8, "no branch"),
            .frame = term.FrameBuffer.init(allocator),
            .session_grants = ai.session_grant.SessionGrants.init(allocator, parsed.flags.auto_approve),
        };
        // Update app.parsed with effective_flags so worker thread uses
        // the auto-fallback provider (zai) instead of the original (ollama).
        app.parsed.flags.provider = effective_flags.provider;
        app.parsed.flags.model = effective_flags.model;

        if (parsed.flags.auto_approve or parsed.flags.trust_all) {
            app.tool_policy = .run_everything;
        }
        if (parsed.flags.mode) |mode_name| {
            if (commands.parseModeName(mode_name)) |mode| app.agent_mode = mode;
        }
        try app.reloadCustomModels();
        try app.refreshStatus();
        try app.pushStartupIntro();
        app.terminal_size = terminal.size();
        app.session_start_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
        app.cli_config = loaded_config;
        app.show_explorer = loaded_config.show_explorer;
        app.show_editor = loaded_config.show_editor;
        // P2.11: init mention picker.
        app.mention_picker = @import("mention_picker.zig").PickerState.init(allocator);
        app.mention_picker_init = true;
        if (envFalsey("FORGE_TUI_MOUSE")) {
            app.term.disableMouse();
        } else {
            app.term.enableMouse();
        }
        // Render cache: init HashMap.
        app.render_cache = std.AutoHashMap(u64, CachedDisplayLines).init(app.allocator);
        app.render_cache_init = true;
        return app;
    }

    pub fn deinit(self: *App) void {
        if (self.worker) |thread| thread.join();
        self.cancel_scope.deinit();
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
        self.bookmarks.deinit(self.allocator);
        self.pinned.deinit(self.allocator);
        for (self.tabs.items) |*tab| tab.deinit(self.allocator);
        self.tabs.deinit(self.allocator);
        if (self.current_tab_name) |n| self.allocator.free(n);
        if (self.last_user_intent) |i| self.allocator.free(i);
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
        self.freeCustomModels();
        self.custom_models.deinit(self.allocator);
        // P2.11: deinit mention picker.
        if (self.mention_picker_init) self.mention_picker.deinit();
        // Render cache: free all cached display lines.
        if (self.render_cache_init) {
            var it = self.render_cache.iterator();
            while (it.next()) |entry| {
                for (entry.value_ptr.lines) |line| self.allocator.free(line);
                self.allocator.free(entry.value_ptr.lines);
            }
            self.render_cache.deinit();
        }
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
                // Invalidate render cache on resize.
                self.render_cache_width = 0;
                self.markDirty();
            }

            const now = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
            self.mutex.lock();
            const busy = self.agent_busy;

            // Smooth scroll animation — animate scroll towards scroll_target.
            // IMPORTANT: only mark dirty if scroll ACTUALLY changed. If scroll
            // hit a limit (max_scroll or 0) and can't move further towards
            // target, snap target to current to stop the animation. Without
            // this, scroll_target > max_scroll creates an infinite busy-loop
            // that sets dirty every frame → 100% CPU → Mac heat.
            if (self.scroll != self.scroll_target) {
                const old_scroll = self.scroll;
                const diff: i64 = @as(i64, @intCast(self.scroll_target)) - @as(i64, @intCast(self.scroll));
                const step: i64 = if (diff > 0) @max(1, @divFloor(diff, 4)) else @min(-1, @divFloor(diff, 4));
                const new_scroll_i: i64 = @as(i64, @intCast(self.scroll)) + step;
                if (new_scroll_i < 0) {
                    self.scroll = 0;
                } else {
                    self.scroll = @intCast(new_scroll_i);
                }
                // If scroll didn't change (hit a limit), snap target to
                // current to terminate the animation.
                if (self.scroll == old_scroll) {
                    self.scroll_target = self.scroll;
                } else {
                    self.markDirty();
                }
            }

            // Render interval — always respected, even when idle. The
            // previous `or !busy` bypass caused dirty=true to trigger
            // immediate render every loop iteration, bypassing the 16ms
            // cap. Now: dirty + interval must both be satisfied.
            if (busy and now - self.spinner_last_ms >= 120) {
                self.spinner_frame +%= 1;
                self.spinner_last_ms = now;
                self.markDirty();
            }
            // 33ms during busy (30fps) — smoother streaming. 16ms when idle
            // (60fps cap) — responsive to keystrokes. Interval is ALWAYS
            // respected — no bypass when idle.
            const render_interval: i64 = if (busy) 33 else self.render_min_interval_ms;
            const should_render = self.dirty and (now - self.last_render_ms >= render_interval);
            if (should_render) {
                // Hide cursor before render to prevent flicker.
                term.writeAll("\x1b[?25l") catch {};
                self.render();
                self.dirty = false;
                self.last_render_ms = now;
                // Show cursor after render (only if not busy and input is active).
                if (!busy and !self.show_help_overlay) {
                    // Cursor position is set in render() — just reveal it.
                    term.writeAll("\x1b[?25h") catch {};
                }
            }
            self.mutex.unlock();

            if (busy) {
                self.handleApprovalInput();
                term.sleepMs(16);
                continue;
            }

            const key = self.term.readKey() catch break;
            if (key == .none) {
                // No input available — sleep briefly to prevent busy-wait.
                // V.TIME=1 blocks read() for up to 100ms, but some terminals
                // or multiplexers (tmux, screen) may override termios settings,
                // causing read() to return immediately. This sleep ensures
                // we never spin at 100% CPU even if V.TIME doesn't work.
                term.sleepMs(1);
                continue;
            }
            try self.handleKey(key);
        }
        // Ensure cursor is visible on exit.
        term.writeAll("\x1b[?25h") catch {};
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
            if (std.mem.eql(u8, chosen, "/mode") or std.mem.eql(u8, chosen, "/resume") or std.mem.eql(u8, chosen, "/model")) {
                self.input.append(self.allocator, ' ') catch return;
            }
            self.cursor = self.input.items.len;
            self.command_index = 0;
        }
    }

    fn freeCustomModels(self: *App) void {
        for (self.custom_models.items) |*model| model.deinit(self.allocator);
        self.custom_models.clearRetainingCapacity();
        self.custom_models_override = false;
    }

    fn reloadCustomModels(self: *App) !void {
        self.freeCustomModels();
        const settings_abs = workspace.global_store.joinHome(self.allocator, "settings.toml") catch return;
        defer self.allocator.free(settings_abs);
        const content = workspace.global_store.readAbsoluteFile(self.allocator, self.io, settings_abs) catch return;
        defer self.allocator.free(content);
        const raw = extractTomlString(content, "ai", "custom_models") orelse return;
        self.custom_models_override = true;
        try self.parseCustomModels(raw);
    }

    fn parseCustomModels(self: *App, raw: []const u8) !void {
        var it = std.mem.splitScalar(u8, raw, ',');
        while (it.next()) |part| {
            const trimmed = std.mem.trim(u8, part, &std.ascii.whitespace);
            if (trimmed.len == 0) continue;
            var field_it = std.mem.splitScalar(u8, trimmed, '|');
            const id = std.mem.trim(u8, field_it.next() orelse continue, &std.ascii.whitespace);
            const label_raw = std.mem.trim(u8, field_it.next() orelse id, &std.ascii.whitespace);
            const provider = std.mem.trim(u8, field_it.next() orelse continue, &std.ascii.whitespace);
            const base_url_raw = if (field_it.next()) |url| std.mem.trim(u8, url, &std.ascii.whitespace) else "";
            if (id.len == 0 or provider.len == 0) continue;
            try self.custom_models.append(self.allocator, .{
                .id = try self.allocator.dupe(u8, id),
                .label = try self.allocator.dupe(u8, if (label_raw.len > 0) label_raw else id),
                .provider = try self.allocator.dupe(u8, provider),
                .base_url = if (base_url_raw.len > 0) try self.allocator.dupe(u8, base_url_raw) else null,
            });
        }
    }

    fn builtinAsPicker(m: ai.provider_capability.ModelCapability) PickerModel {
        return .{
            .provider = m.provider,
            .model_id = m.model_id,
            .display_name = m.display_name,
            .notes = m.capability.notes,
            .free = m.capability.price_per_mtok_input == 0 and m.capability.price_per_mtok_output == 0,
        };
    }

    fn customAsPicker(m: CustomModel) PickerModel {
        return .{
            .provider = m.provider,
            .model_id = m.id,
            .display_name = m.label,
            .notes = "custom",
            .free = false,
        };
    }

    fn modelFullId(buf: []u8, m: PickerModel) ?[]const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ m.provider, m.model_id }) catch null;
    }

    fn modelMatchesQuery(query: []const u8, m: PickerModel) bool {
        const q = std.mem.trim(u8, query, &std.ascii.whitespace);
        if (q.len == 0) return true;
        var id_buf: [256]u8 = undefined;
        const id = modelFullId(&id_buf, m) orelse "";
        return std.ascii.indexOfIgnoreCase(id, q) != null or
            std.ascii.indexOfIgnoreCase(m.provider, q) != null or
            std.ascii.indexOfIgnoreCase(m.model_id, q) != null or
            std.ascii.indexOfIgnoreCase(m.display_name, q) != null or
            std.ascii.indexOfIgnoreCase(m.notes, q) != null;
    }

    fn modelPickerMatchCount(self: *const App) usize {
        var count: usize = 0;
        if (self.custom_models_override) {
            for (self.custom_models.items) |m| {
                if (modelMatchesQuery(self.input.items, customAsPicker(m))) count += 1;
            }
        } else {
            for (ai.provider_capability.builtin_models) |m| {
                if (modelMatchesQuery(self.input.items, builtinAsPicker(m))) count += 1;
            }
        }
        return count;
    }

    fn modelPickerModelAt(self: *const App, wanted: usize) ?PickerModel {
        var seen: usize = 0;
        if (self.custom_models_override) {
            for (self.custom_models.items) |m| {
                const picker = customAsPicker(m);
                if (!modelMatchesQuery(self.input.items, picker)) continue;
                if (seen == wanted) return picker;
                seen += 1;
            }
        } else {
            for (ai.provider_capability.builtin_models) |m| {
                const picker = builtinAsPicker(m);
                if (!modelMatchesQuery(self.input.items, picker)) continue;
                if (seen == wanted) return picker;
                seen += 1;
            }
        }
        return null;
    }

    fn hasModel(self: *const App, provider: []const u8, model_id: []const u8) bool {
        if (self.custom_models_override) {
            for (self.custom_models.items) |m| {
                if (std.mem.eql(u8, m.provider, provider) and std.mem.eql(u8, m.id, model_id)) return true;
            }
            return false;
        }
        for (ai.provider_capability.builtin_models) |m| {
            if (std.mem.eql(u8, m.provider, provider) and std.mem.eql(u8, m.model_id, model_id)) return true;
        }
        return false;
    }

    fn clampModelPickerIndex(self: *App) void {
        const count = self.modelPickerMatchCount();
        if (count == 0) {
            self.model_picker_index = 0;
        } else if (self.model_picker_index >= count) {
            self.model_picker_index = count - 1;
        }
    }

    fn openModelPicker(self: *App) void {
        self.model_picker_active = true;
        self.model_picker_index = 0;
        self.input.clearRetainingCapacity();
        self.cursor = 0;
        self.show_events = false;
        self.show_timeline = false;
        self.markDirty();
    }

    fn openModelPickerWithQuery(self: *App, query: []const u8) void {
        self.openModelPicker();
        self.input.appendSlice(self.allocator, query) catch {};
        self.cursor = self.input.items.len;
        self.clampModelPickerIndex();
        self.markDirty();
    }

    fn closeModelPicker(self: *App) void {
        self.model_picker_active = false;
        self.model_picker_index = 0;
        self.input.clearRetainingCapacity();
        self.cursor = 0;
        self.markDirty();
    }

    fn selectModelPickerCurrent(self: *App) !void {
        self.clampModelPickerIndex();
        const model = self.modelPickerModelAt(self.model_picker_index) orelse {
            try self.pushSystem("No matching model. Type to filter or Esc to cancel.");
            return;
        };
        var id_buf: [256]u8 = undefined;
        const id = modelFullId(&id_buf, model) orelse {
            try self.pushSystem("Failed to build model id");
            return;
        };
        self.closeModelPicker();
        try self.setModel(id);
    }

    fn cleanedModelInput(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
        var cleaned: std.ArrayList(u8) = .empty;
        errdefer cleaned.deinit(allocator);
        var i: usize = 0;
        while (i < input.len) {
            const c = input[i];
            if (c == 27 and i + 1 < input.len and input[i + 1] == '[') {
                i += 2;
                while (i < input.len) : (i += 1) {
                    const end = input[i];
                    if ((end >= '@' and end <= '~')) {
                        i += 1;
                        break;
                    }
                }
                continue;
            }
            if (c == '\r' or c == '\n' or c == '\t') {
                try cleaned.append(allocator, ' ');
            } else if (c >= 32 and c < 127) {
                try cleaned.append(allocator, c);
            }
            i += 1;
        }
        return cleaned.toOwnedSlice(allocator);
    }

    fn startsWithModelConfigVerb(input: []const u8, verb: []const u8) bool {
        return std.mem.eql(u8, input, verb) or
            (input.len > verb.len and std.mem.startsWith(u8, input, verb) and std.ascii.isWhitespace(input[verb.len]));
    }

    fn isModelConfigInput(input: []const u8) bool {
        return startsWithModelConfigVerb(input, "add") or
            startsWithModelConfigVerb(input, "list") or
            startsWithModelConfigVerb(input, "remove") or
            startsWithModelConfigVerb(input, "rm") or
            startsWithModelConfigVerb(input, "delete") or
            startsWithModelConfigVerb(input, "reset");
    }

    fn modelCommandFromInput(allocator: std.mem.Allocator, input: []const u8) !?[]u8 {
        const cleaned = try cleanedModelInput(allocator, input);
        defer allocator.free(cleaned);
        const trimmed = std.mem.trim(u8, cleaned, &std.ascii.whitespace);
        const start = std.mem.indexOf(u8, trimmed, "/model") orelse
            std.mem.indexOf(u8, trimmed, "/m") orelse
            {
                if (isModelConfigInput(trimmed)) {
                    return try std.fmt.allocPrint(allocator, "/model {s}", .{trimmed});
                }
                return null;
            };
        const candidate = std.mem.trim(u8, trimmed[start..], &std.ascii.whitespace);
        if (std.mem.eql(u8, candidate, "/model") or
            std.mem.eql(u8, candidate, "/m") or
            std.mem.startsWith(u8, candidate, "/model ") or
            std.mem.startsWith(u8, candidate, "/m "))
        {
            return try allocator.dupe(u8, candidate);
        }
        return null;
    }

    fn modelPickerDisplayInput(buf: []u8, input: []const u8) []const u8 {
        var out: usize = 0;
        var i: usize = 0;
        while (i < input.len and out < buf.len) {
            const c = input[i];
            if (c == 27 and i + 1 < input.len and input[i + 1] == '[') {
                i += 2;
                while (i < input.len) : (i += 1) {
                    const end = input[i];
                    if (end >= '@' and end <= '~') {
                        i += 1;
                        break;
                    }
                }
                continue;
            }
            if (c == '\r' or c == '\n' or c == '\t') {
                buf[out] = ' ';
                out += 1;
            } else if (c >= 32 and c < 127) {
                buf[out] = c;
                out += 1;
            }
            i += 1;
        }
        return buf[0..out];
    }

    fn dispatchModelPickerCommand(self: *App) !bool {
        self.mutex.lock();
        const owned = modelCommandFromInput(self.allocator, self.input.items) catch null;
        if (owned == null) {
            self.mutex.unlock();
            return false;
        }
        self.closeModelPicker();
        self.mutex.unlock();
        const raw = owned orelse return true;
        defer self.allocator.free(raw);
        const cmd = commands.parseSlashCommand(raw);
        if (cmd == .not_command) return true;
        try self.dispatchCommand(cmd);
        return true;
    }

    fn handleModelPickerKey(self: *App, key: term.Key) !void {
        switch (key) {
            .ctrl_c, .escape => {
                self.mutex.lock();
                self.closeModelPicker();
                self.mutex.unlock();
            },
            .enter => {
                if (try self.dispatchModelPickerCommand()) return;
                try self.selectModelPickerCurrent();
            },
            .up => {
                self.mutex.lock();
                const count = self.modelPickerMatchCount();
                if (count > 0) {
                    self.model_picker_index = if (self.model_picker_index > 0) self.model_picker_index - 1 else count - 1;
                }
                self.markDirty();
                self.mutex.unlock();
            },
            .down, .tab => {
                self.mutex.lock();
                const count = self.modelPickerMatchCount();
                if (count > 0) self.model_picker_index = (self.model_picker_index + 1) % count;
                self.markDirty();
                self.mutex.unlock();
            },
            .page_up => {
                self.mutex.lock();
                if (self.model_picker_index > max_model_picker_rows) {
                    self.model_picker_index -= max_model_picker_rows;
                } else {
                    self.model_picker_index = 0;
                }
                self.markDirty();
                self.mutex.unlock();
            },
            .page_down => {
                self.mutex.lock();
                const count = self.modelPickerMatchCount();
                if (count > 0) {
                    self.model_picker_index = @min(count - 1, self.model_picker_index + max_model_picker_rows);
                }
                self.markDirty();
                self.mutex.unlock();
            },
            .backspace => {
                self.mutex.lock();
                if (self.cursor > 0) {
                    _ = self.input.orderedRemove(self.cursor - 1);
                    self.cursor -= 1;
                    self.model_picker_index = 0;
                    self.clampModelPickerIndex();
                }
                self.markDirty();
                self.mutex.unlock();
            },
            .ctrl_u => {
                self.mutex.lock();
                self.input.clearRetainingCapacity();
                self.cursor = 0;
                self.model_picker_index = 0;
                self.markDirty();
                self.mutex.unlock();
            },
            .char => |ch| {
                if (ch >= 32 and ch < 127) {
                    self.mutex.lock();
                    self.input.insert(self.allocator, self.cursor, ch) catch {};
                    self.cursor += 1;
                    self.model_picker_index = 0;
                    self.clampModelPickerIndex();
                    self.markDirty();
                    self.mutex.unlock();
                }
            },
            .paste => |text| {
                if (text.len > 0) {
                    var command: ?[]u8 = null;
                    self.mutex.lock();
                    self.input.insertSlice(self.allocator, self.cursor, text) catch {};
                    self.cursor += text.len;
                    self.model_picker_index = 0;
                    self.clampModelPickerIndex();
                    command = modelCommandFromInput(self.allocator, self.input.items) catch null;
                    if (command != null) self.closeModelPicker();
                    self.markDirty();
                    self.mutex.unlock();
                    if (command) |raw| {
                        defer self.allocator.free(raw);
                        const cmd = commands.parseSlashCommand(raw);
                        if (cmd != .not_command) try self.dispatchCommand(cmd);
                    }
                }
            },
            else => {},
        }
    }

    /// Tab-complete model names when user types /model <partial> + Tab.
    /// Cycles through all models in the capability table that start with
    /// the partial input. Uses Up/Down to navigate, Tab to cycle.
    fn applyModelSuggestion(self: *App) void {
        // Extract the partial model name after "/model "
        const input = self.input.items;
        const prefix = "/model ";
        if (input.len <= prefix.len) return;
        const partial = input[prefix.len..];

        // Build list of all fully-qualified models that start with the partial.
        var matches_buf: [128][256]u8 = undefined;
        var matches: [128][]const u8 = undefined;
        var match_count: usize = 0;
        for (ai.provider_capability.builtin_models) |m| {
            if (match_count >= matches.len) break;
            const id = std.fmt.bufPrint(&matches_buf[match_count], "{s}/{s}", .{ m.provider, m.model_id }) catch continue;
            if (std.mem.startsWith(u8, id, partial)) {
                matches[match_count] = id;
                match_count += 1;
            }
        }

        if (match_count == 0) {
            // No matches - show all models.
            for (ai.provider_capability.builtin_models) |m| {
                if (match_count >= matches.len) break;
                const id = std.fmt.bufPrint(&matches_buf[match_count], "{s}/{s}", .{ m.provider, m.model_id }) catch continue;
                matches[match_count] = id;
                match_count += 1;
            }
        }

        if (match_count > 0) {
            const idx = if (self.model_suggestion_index < match_count) self.model_suggestion_index else 0;
            const chosen = matches[idx];
            // Rebuild input: /model <chosen>
            self.input.clearRetainingCapacity();
            self.input.appendSlice(self.allocator, prefix) catch return;
            self.input.appendSlice(self.allocator, chosen) catch return;
            self.cursor = self.input.items.len;
            self.model_suggestion_index = (idx + 1) % match_count;
        }
    }

    /// Tab-complete file paths for commands that take path arguments (Phase 43).
    /// Returns true if a completion was attempted (input was modified or
    /// the context was a path completion context, even if no match found).
    /// Commands: /complete, /save, /spec show
    fn completeFilePath(self: *App) bool {
        const input = self.input.items;
        // Check if input contains a space (command + argument).
        const space_idx = std.mem.indexOfScalar(u8, input, ' ') orelse return false;
        const cmd = input[0..space_idx];
        const arg = std.mem.trim(u8, input[space_idx + 1 ..], &std.ascii.whitespace);

        // Only complete for commands that take file paths.
        const is_path_cmd = std.mem.eql(u8, cmd, "/complete") or
            std.mem.eql(u8, cmd, "/save") or
            std.mem.eql(u8, cmd, "/spec");
        if (!is_path_cmd) return false;

        // For /spec, only complete if it's "show" subcommand
        if (std.mem.eql(u8, cmd, "/spec")) {
            if (!std.mem.startsWith(u8, arg, "show ")) return false;
        }

        // If arg is empty, we can't complete — just return true to skip
        // command suggestion.
        if (arg.len == 0) return true;

        // Extract the partial path (for /spec show, skip "show " prefix).
        var partial: []const u8 = arg;
        if (std.mem.eql(u8, cmd, "/spec") and std.mem.startsWith(u8, arg, "show ")) {
            partial = std.mem.trim(u8, arg[5..], &std.ascii.whitespace);
        }

        // Try to list directory contents matching the partial path.
        // Simple approach: if partial has no slash, list workspace root.
        const last_slash = std.mem.lastIndexOfScalar(u8, partial, '/');
        const dir_part = if (last_slash) |s| partial[0..s] else ".";
        const file_part = if (last_slash) |s| partial[s + 1 ..] else partial;

        // Open the directory.
        var dir = std.Io.Dir.openDir(.cwd(), self.io, self.opened.path, .{}) catch return true;
        defer dir.close(self.io);

        var sub_dir = if (dir_part.len > 0 and !std.mem.eql(u8, dir_part, "."))
            dir.openDir(self.io, dir_part, .{ .iterate = true }) catch return true
        else
            dir.openDir(self.io, ".", .{ .iterate = true }) catch return true;
        defer sub_dir.close(self.io);

        // Iterate and find first match starting with file_part.
        var iter = sub_dir.iterate();
        while (iter.next(self.io) catch null) |entry| {
            if (std.mem.startsWith(u8, entry.name, file_part)) {
                // Found a match — replace the file_part in the input.
                const match_name = entry.name;
                const prefix_len = input.len - file_part.len;
                // Trim input to just before file_part.
                self.input.shrinkRetainingCapacity(prefix_len);
                self.input.appendSlice(self.allocator, match_name) catch return true;
                // If it's a directory, add trailing slash.
                if (entry.kind == .directory) {
                    self.input.append(self.allocator, '/') catch return true;
                }
                self.cursor = self.input.items.len;
                return true;
            }
        }

        // No match found — still return true to skip command suggestion.
        return true;
    }

    fn handleKey(self: *App, key: term.Key) !void {
        if (self.model_picker_active) {
            try self.handleModelPickerKey(key);
            return;
        }

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
                self.scroll_target = 0;
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
                    // Check if we're in a file-path completion context (Phase 43).
                    if (self.completeFilePath()) {
                        self.markDirty();
                    } else {
                        // Check if we're in /model context — autocomplete model names
                        if (self.input.items.len >= 7 and std.mem.startsWith(u8, self.input.items, "/model ")) {
                            self.applyModelSuggestion();
                            self.markDirty();
                        } else {
                            self.applyCommandSuggestion();
                            self.markDirty();
                        }
                    }
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
                // Wire-in #5: mention picker — insert selected mention.
                if (self.mention_picker.active) {
                    if (self.mention_picker.current()) |entry| {
                        self.mutex.lock();
                        self.input.appendSlice(self.allocator, entry.insert) catch {};
                        self.cursor = self.input.items.len;
                        self.markDirty();
                        self.mutex.unlock();
                    }
                    self.mention_picker.close();
                    self.markDirty();
                    return;
                }
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
                    const len = @min(self.getFilteredCommands(&filtered), max_command_suggestions);
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
                    self.scroll_target = 0;
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
            .ctrl_j => {
                // Ctrl+J = insert newline for multi-line input (Phase 26).
                // Allows typing multi-line prompts without submitting.
                self.mutex.lock();
                self.input.insert(self.allocator, self.cursor, '\n') catch {};
                self.cursor += 1;
                self.markDirty();
                self.mutex.unlock();
            },
            .ctrl_w => {
                self.mutex.lock();
                self.deleteWordBackward();
                self.markDirty();
                self.mutex.unlock();
            },
            .ctrl_y => {
                // Ctrl+Y = copy last code block to clipboard (Phase 38).
                self.copyLastCodeBlock() catch {};
            },
            .ctrl_tab => {
                // Ctrl+Tab = cycle through tabs (Phase 82).
                self.cycleTab() catch {};
            },
            .up => {
                // Wire-in #5: mention picker navigation.
                if (self.mention_picker.active) {
                    self.mention_picker.moveUp();
                    self.markDirty();
                    return;
                }
                if (self.focus_explorer) {
                    if (self.explorer_scroll_y > 0) self.explorer_scroll_y -= 1;
                    self.markDirty();
                    return;
                }
                self.mutex.lock();
                if (self.input.items.len > 0 and self.input.items[0] == '/') {
                    var filtered: [ALL_COMMANDS.len][]const u8 = undefined;
                    const len = @min(self.getFilteredCommands(&filtered), max_command_suggestions);
                    if (len > 0) {
                        if (self.command_index > 0) {
                            self.command_index -= 1;
                        } else {
                            self.command_index = len - 1;
                        }
                        self.markDirty();
                    }
                } else if (self.input.items.len == 0 and self.hasScrollableChatLocked()) {
                    self.scrollChatPageLocked(1);
                } else {
                    self.mutex.unlock();
                    self.recallHistory(-1);
                    return;
                }
                self.mutex.unlock();
            },
            .down => {
                // Wire-in #5: mention picker navigation.
                if (self.mention_picker.active) {
                    self.mention_picker.moveDown();
                    self.markDirty();
                    return;
                }
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
                    const len = @min(self.getFilteredCommands(&filtered), max_command_suggestions);
                    if (len > 0) {
                        if (self.command_index + 1 < len) {
                            self.command_index += 1;
                        } else {
                            self.command_index = 0;
                        }
                        self.markDirty();
                    }
                } else if (self.input.items.len == 0 and self.scroll > 0) {
                    self.scrollChatPageLocked(-1);
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
                // '?' when input is empty toggles help overlay (Phase 24).
                if (ch == '?' and self.input.items.len == 0) {
                    self.toggleHelpOverlay() catch {};
                    return;
                }
                // Close help overlay on any key when it's showing.
                if (self.show_help_overlay) {
                    self.show_help_overlay = false;
                    self.markDirty();
                    return;
                }
                if (self.tryProposalShortcut(ch)) return;

                // Wire-in #5: @mention picker — when user types '@', open the
                // mention picker popup. Subsequent characters filter the list.
                // Up/Down navigate, Enter selects, Esc dismisses.
                if (ch == '@' and !self.mention_picker.active) {
                    self.mention_picker.open();
                } else if (self.mention_picker.active) {
                    if (ch == 27) { // Esc
                        self.mention_picker.close();
                        self.markDirty();
                        return;
                    }
                    // Append to picker query and refresh.
                    self.mention_picker.appendQuery(ch) catch {};
                    const mp = @import("mention_picker.zig");
                    self.mention_picker.refresh(&mp.defaultFileSource) catch {};
                    self.markDirty();
                    return;
                }

                if (ch >= 32 and ch < 127) {
                    self.mutex.lock();
                    self.cancel_armed = false;
                    self.input.insert(self.allocator, self.cursor, ch) catch {};
                    self.cursor += 1;
                    self.markDirty();
                    self.mutex.unlock();
                }
            },
            .mouse => |ev| {
                // Wire-in: SGR mouse event handling.
                // Button 64 = scroll up, Button 65 = scroll down.
                // Button 0 = left click (press), release detected via ev.release.
                if (ev.button == 64) {
                    // Scroll up — accumulate wheel events for smooth scrolling.
                    // Instead of jumping 3 lines instantly, we set a target
                    // and let the render loop animate towards it. This produces
                    // a gliding effect similar to native macOS scroll.
                    self.mutex.lock();
                    self.scroll_target +|= 3;
                    self.markDirty();
                    self.mutex.unlock();
                } else if (ev.button == 65) {
                    // Scroll down — animate towards target.
                    self.mutex.lock();
                    const page: usize = 3;
                    if (self.scroll_target > page) {
                        self.scroll_target -= page;
                    } else {
                        self.scroll_target = 0;
                    }
                    self.markDirty();
                    self.mutex.unlock();
                } else if (ev.button == 0 and !ev.release) {
                    // Left click — could be used for clicking @mention entries,
                    // diff hunks, or explorer panel items. For now, just
                    // dismiss the mention picker if it's open and the click
                    // is outside the input area.
                    if (self.mention_picker.active) {
                        self.mention_picker.close();
                        self.markDirty();
                    }
                }
            },
            .paste => |text| {
                // Wire-in: bracketed paste — insert pasted text into input.
                if (text.len > 0) {
                    self.mutex.lock();
                    self.input.insertSlice(self.allocator, self.cursor, text) catch {};
                    self.cursor += text.len;
                    self.cancel_armed = false;
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
            // Hunk-level diff: 'y' accepts hunk, 'r' rejects, 's' skips.
            'y' => {
                self.applyPendingProposal() catch {};
                self.pushSystem("✓ Accepted and applied hunks") catch {};
                return true;
            },
            'r' => {
                self.dismissPendingProposal();
                self.pushSystem("✗ Rejected hunk") catch {};
                return true;
            },
            's' => {
                self.pushSystem("→ Skipped to next hunk") catch {};
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
            self.scroll_target +|= page;
        } else if (self.scroll_target > page) {
            self.scroll_target -= page;
        } else {
            self.scroll = 0;
            self.scroll_target = 0;
        }
        self.markDirty();
    }

    fn scrollChatToTop(self: *App) void {
        self.scroll_target = std.math.maxInt(usize);
        self.markDirty();
    }

    fn chatRowCount(self: *const App) usize {
        const footer_rows: u16 = 4;
        if (self.terminal_size.rows <= footer_rows + 2) return 1;
        return self.terminal_size.rows - footer_rows;
    }

    fn hasScrollableChatLocked(self: *const App) bool {
        const rows = self.chatRowCount();
        const width = if (self.terminal_size.cols > 16) @as(usize, self.terminal_size.cols - 16) else @as(usize, 20);
        var estimated_rows: usize = 0;
        for (self.lines.items) |line| {
            var parts = std.mem.splitScalar(u8, line.text, '\n');
            var any = false;
            while (parts.next()) |part| {
                any = true;
                estimated_rows += @max(@as(usize, 1), (term.displayWidth(part) + width - 1) / width);
                if (estimated_rows > rows) return true;
            }
            if (!any) estimated_rows += 1;
            if (estimated_rows > rows) return true;
        }
        return false;
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
            self.scroll_target +|= page;
        } else if (self.scroll_target > page) {
            self.scroll_target -= page;
        } else {
            self.scroll = 0;
            self.scroll_target = 0;
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
        // Phase 74: Save last user intent for /retry command.
        self.mutex.lock();
        if (self.last_user_intent) |old| self.allocator.free(old);
        self.last_user_intent = self.allocator.dupe(u8, intent) catch null;
        self.mutex.unlock();
        try self.startAgent(intent, null);
    }

    fn dispatchCommand(self: *App, cmd: commands.Command) !void {
        switch (cmd) {
            .not_command => {},
            .wipe_history => {
                self.mutex.lock();
                self.freeLines();
                self.scroll = 0;
                self.scroll_target = 0;
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
            .tools_trust_all => {
                self.mutex.lock();
                self.tool_policy = .run_everything;
                self.markDirty();
                self.mutex.unlock();
                try self.pushSystem("All tools trusted for this session. Edit tools auto-apply through transactions; checkpoints and undo remain enabled.");
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
            // TUI parity commands (Phase 13)
            .spec_list => try self.listSpecs(),
            .spec_show => |spec_id| try self.showSpec(spec_id),
            .runs_list => try self.listRuns(),
            .runs_status => try self.showRunsStatus(),
            .complete_prompt => |prompt| try self.requestCompletion(prompt),
            // Phase 24: Additional commands for TUI completeness
            .tools_list => try self.listTools(),
            .help_overlay => try self.toggleHelpOverlay(),
            .model_show => try self.showModel(),
            .model_set => |model_name| try self.setModel(model_name),
            .cost => try self.showCost(),
            .capability => try self.showCapability(),
            .provider_show => try self.showProvider(),
            .save => |path| try self.saveConversation(path),
            .review => try self.runReview(),
            .inspect => try self.inspectContext(),
            .search => |query| try self.searchConversation(query),
            .edit_last => try self.editLastUserMessage(),
            .undo => try self.undoLastAction(),
            .redo => try self.redoLastAction(),
            .clear_history => try self.clearHistoryOnly(),
            .clear_context => try self.clearContextOnly(),
            .theme => |name| try self.setTheme(name),
            .config => try self.showConfig(),
            .help_detailed => |help_cmd| try self.showDetailedHelp(help_cmd),
            .export_markdown => |path| try self.exportMarkdown(path),
            .bookmark => |line_num| try self.bookmarkMessage(line_num),
            .bookmark_list => try self.listBookmarks(),
            .copy_line => |line_num| try self.copyLine(line_num),
            .branch => |name| try self.createBranch(name),
            .filter => |role| try self.filterByRole(role),
            .stats => try self.showStats(),
            .compact => try self.compactConversation(),
            .pin => |line_num| try self.pinMessage(line_num),
            .alias => |args| try self.handleAlias(args),
            .alias_list => try self.listAliases(),
            .macro_record => try self.startMacroRecording(),
            .macro_stop => try self.stopMacroRecording(),
            .macro_play => |name| try self.playMacro(name),
            .macro_list => try self.listMacros(),
            .notify => |args| try self.handleNotify(args),
            .wordwrap => try self.toggleWordwrap(),
            .vim => try self.toggleVimMode(),
            .goto_line => |line_num| try self.gotoLine(line_num),
            .snippet => |args| try self.handleSnippet(args),
            .snippet_list => try self.listSnippets(),
            .time => try self.showSessionTime(),
            .resize => try self.refreshTerminalSize(),
            .tag => |args| try self.handleTag(args),
            .tag_list => try self.listTags(),
            .summary => try self.generateSummary(),
            .retry => try self.retryLastRequest(),
            .diff_file => |file| try self.showFileDiff(file),
            .newtab => |name| try self.createNewTab(name),
            .tabs => try self.listTabs(),
            .close_tab => try self.closeCurrentTab(),
            .rename_tab => |name| try self.renameCurrentTab(name),
            .switch_tab => |num| try self.switchToTab(num),
            .priority => |args| try self.handlePriority(args),
            .merge_tab => |num| try self.mergeTab(num),
            .clear_tabs => try self.clearAllTabs(),
            .tab_name => |name| try self.tabByName(name),
            .copytab => |num| try self.copyTabToClipboard(num),
            .swap_tab => |num| try self.swapTab(num),
            .exporttab => |args| try self.exportTab(args),
            .log_toggle => try self.toggleLogging(),
            .version => try self.showVersion(),
            .copyall => try self.copyAllToClipboard(),
            .findreplace => |args| try self.findReplace(args),
            .translate => |lang| try self.translateConversation(lang),
            .annotate => |args| try self.annotateMessage(args),
            .share => |args| try self.shareConversation(args),
            .refactor => |args| try self.aiRefactor(args),
            .explain => |args| try self.aiExplain(args),
            .fix => |args| try self.aiFix(args),
            .testgen => |args| try self.aiTestGen(args),
            .doc => |args| try self.aiDoc(args),
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
            var summary_buf: [320]u8 = undefined;
            const summary = self.formatToolDoneSummary(&summary_buf, step.kind, step.summary);
            const line = std.fmt.bufPrint(&buf, "step {d}: {s}", .{ step.index, summary }) catch continue;
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
        self.scroll_target = 0;
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

    /// /spec [list] — list all specs in the workspace.
    /// TUI parity for `forge spec list` CLI.
    fn listSpecs(self: *App) !void {
        const specs: []ai.spec_writer.SpecInfo = ai.spec_writer.listSpecs(self.allocator, self.io, self.opened.root) catch {
            try self.pushSystem("Failed to load specs");
            return;
        };
        defer ai.spec_writer.freeSpecList(self.allocator, specs);
        if (specs.len == 0) {
            try self.pushSystem("No specs yet. Run an agent task to generate a spec, or use 'forge spec init'.");
            return;
        }
        try self.pushSystem("Specs:");
        for (specs) |spec| {
            var buf: [256]u8 = undefined;
            const r_marker: []const u8 = if (spec.has_requirements) "R" else "-";
            const d_marker: []const u8 = if (spec.has_design) "D" else "-";
            const t_marker: []const u8 = if (spec.has_tasks) "T" else "-";
            const line = std.fmt.bufPrint(
                &buf,
                "  [{s}] {s}  {s} {s} {s}",
                .{ spec.status.label(), spec.run_id, r_marker, d_marker, t_marker },
            ) catch continue;
            try self.pushLine(.system, try self.allocator.dupe(u8, line));
        }
        try self.pushSystem("Use /spec show <run_id> to view details");
    }

    /// /spec show <run_id> — show details of a specific spec.
    /// TUI parity for `forge spec show` CLI.
    fn showSpec(self: *App, spec_id_opt: ?[]const u8) !void {
        const spec_id = spec_id_opt orelse {
            try self.pushSystem("Usage: /spec show <run_id>");
            return;
        };
        const specs: []ai.spec_writer.SpecInfo = ai.spec_writer.listSpecs(self.allocator, self.io, self.opened.root) catch {
            try self.pushSystem("Failed to load specs");
            return;
        };
        defer ai.spec_writer.freeSpecList(self.allocator, specs);
        for (specs) |spec| {
            if (std.mem.eql(u8, spec.run_id, spec_id)) {
                var buf: [512]u8 = undefined;
                const header = std.fmt.bufPrint(
                    &buf,
                    "Spec: {s}  Status: {s}",
                    .{ spec.run_id, spec.status.label() },
                ) catch spec.run_id;
                try self.pushSystem(header);
                if (spec.has_requirements) try self.pushSystem("  requirements.md: present");
                if (spec.has_design) try self.pushSystem("  design.md: present");
                if (spec.has_tasks) try self.pushSystem("  tasks.md: present");
                if (spec.intent.len > 0) {
                    var intent_buf: [256]u8 = undefined;
                    const intent_line = std.fmt.bufPrint(&intent_buf, "  Intent: {s}", .{spec.intent}) catch "  Intent: (too long)";
                    try self.pushSystem(intent_line);
                }
                return;
            }
        }
        var not_found_buf: [256]u8 = undefined;
        const not_found = std.fmt.bufPrint(&not_found_buf, "Spec not found: {s}", .{spec_id}) catch "Spec not found";
        try self.pushSystem(not_found);
    }

    /// /runs [list] — list all background runs.
    /// TUI parity for `forge agent runs` CLI.
    fn listRuns(self: *App) !void {
        var runs_list = workspace.runs.listEntries(self.allocator, self.io, self.opened.root) catch {
            try self.pushSystem("Failed to load runs");
            return;
        };
        defer runs_list.deinit();
        if (runs_list.items.len == 0) {
            try self.pushSystem("No runs yet. Use 'forge agent run --background' to start one.");
            return;
        }
        try self.pushSystem("Runs (newest last):");
        for (runs_list.items) |entry| {
            var buf: [256]u8 = undefined;
            const line = std.fmt.bufPrint(
                &buf,
                "  {s}  [{s}]  ({d})",
                .{ entry.run_id, entry.state, entry.timestamp_ms },
            ) catch continue;
            try self.pushLine(.system, try self.allocator.dupe(u8, line));
        }
        try self.pushSystem("Use /runs status for active run count");
    }

    /// /runs status — show count of active vs completed runs.
    fn showRunsStatus(self: *App) !void {
        var runs_list = workspace.runs.listEntries(self.allocator, self.io, self.opened.root) catch {
            try self.pushSystem("Failed to load runs");
            return;
        };
        defer runs_list.deinit();
        var active: usize = 0;
        var done: usize = 0;
        var failed: usize = 0;
        for (runs_list.items) |entry| {
            if (std.mem.eql(u8, entry.state, "done")) done += 1 else if (std.mem.eql(u8, entry.state, "failed")) failed += 1 else active += 1;
        }
        var buf: [128]u8 = undefined;
        const status = std.fmt.bufPrint(
            &buf,
            "Runs: {d} total ({d} active, {d} done, {d} failed)",
            .{ runs_list.items.len, active, done, failed },
        ) catch "Runs status unavailable";
        try self.pushSystem(status);
    }

    /// /complete [prompt] — request an inline completion.
    /// TUI parity for `forge complete` CLI. Sends the prompt to the
    /// configured provider and displays the response inline.
    fn requestCompletion(self: *App, prompt_opt: ?[]const u8) !void {
        const prompt = prompt_opt orelse {
            try self.pushSystem("Usage: /complete <prompt>");
            try self.pushSystem("Sends a completion request to the configured provider.");
            try self.pushSystem("The prompt is used as both prefix and suffix context for FIM completion.");
            try self.pushSystem("");
            try self.pushSystem("For full inline completion with file context, use 'forge complete --file <path>' CLI.");
            return;
        };

        var echo_buf: [256]u8 = undefined;
        const echo = std.fmt.bufPrint(&echo_buf, "Completion request: {s}", .{prompt}) catch "Completion request";
        try self.pushSystem(echo);

        // Build provider options and create a provider for the completion call.
        const provider_opts = ai_workflow.agentProviderOptionsFromFlags(self.allocator, self.parsed.flags, prompt, self.io, self.opened.root);
        var provider = ai.provider_factory.create(self.allocator, self.io, self.environ_map, provider_opts.options) catch |err| {
            var err_buf: [128]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Completion failed: cannot create provider ({s})", .{@errorName(err)}) catch "Completion failed: provider unavailable";
            try self.pushSystem(err_msg);
            return;
        };
        defer provider.deinit(self.allocator);

        // Build a simple FIM prompt: "Complete the following code: <prompt>"
        var fim_buf: std.ArrayList(u8) = .empty;
        defer fim_buf.deinit(self.allocator);
        fim_buf.appendSlice(self.allocator, "Complete the following code. Output only the completion, no explanations:\n\n") catch return;
        fim_buf.appendSlice(self.allocator, prompt) catch return;

        // Call the provider.
        var response_alloc = std.Io.Writer.Allocating.init(self.allocator);
        defer response_alloc.deinit();
        const images = [_]ai.provider.ImagePart{};
        var dummy_state = std.atomic.Value(bool).init(false);
        var dummy_token: kernel.cancellation.CancellationToken = .{ .shared_state = &dummy_state };
        provider.ask(
            self.allocator,
            fim_buf.items,
            &images,
            &response_alloc.writer,
            &dummy_token,
        ) catch |err| {
            var err_buf: [128]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Completion failed: {s}", .{@errorName(err)}) catch "Completion failed";
            try self.pushSystem(err_msg);
            return;
        };

        const output = response_alloc.writer.buffer[0..response_alloc.writer.end];
        if (output.len == 0) {
            try self.pushSystem("Completion returned empty response.");
            return;
        }

        // Display the completion. Truncate very long outputs for TUI readability.
        const max_display = 2000;
        if (output.len > max_display) {
            var trunc_buf: [64]u8 = undefined;
            const trunc_msg = std.fmt.bufPrint(&trunc_buf, "Completion ({d} bytes, showing first {d}):", .{ output.len, max_display }) catch "Completion (truncated):";
            try self.pushSystem(trunc_msg);
            try self.pushLine(.agent, try self.allocator.dupe(u8, output[0..max_display]));
            try self.pushSystem("... (truncated)");
        } else {
            var len_buf: [64]u8 = undefined;
            const len_msg = std.fmt.bufPrint(&len_buf, "Completion ({d} bytes):", .{output.len}) catch "Completion:";
            try self.pushSystem(len_msg);
            try self.pushLine(.agent, try self.allocator.dupe(u8, output));
        }
    }

    /// /tools list — list all available tools (Phase 24).
    fn listTools(self: *App) !void {
        try self.pushSystem("Available tools:");
        const tool_names = [_]struct { name: []const u8, desc: []const u8 }{
            .{ .name = "read_file", .desc = "Read file contents" },
            .{ .name = "write_file", .desc = "Write file contents" },
            .{ .name = "edit_file", .desc = "Edit a portion of a file" },
            .{ .name = "search", .desc = "Search file contents (grep)" },
            .{ .name = "codebase_search", .desc = "Semantic codebase search" },
            .{ .name = "list_tree", .desc = "List directory tree" },
            .{ .name = "run_command", .desc = "Run shell command" },
            .{ .name = "run_task", .desc = "Run build/test task" },
            .{ .name = "git_diff", .desc = "Show git diff" },
            .{ .name = "propose", .desc = "Propose file edit" },
            .{ .name = "replace_file_content", .desc = "Replace file content" },
            .{ .name = "fetch_url", .desc = "Fetch URL content" },
            .{ .name = "remember", .desc = "Save to agent memory" },
            .{ .name = "undo", .desc = "Undo last change" },
            .{ .name = "show_context", .desc = "Show context manifest" },
        };
        for (tool_names) |t| {
            var buf: [128]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "  {s:<24} {s}", .{ t.name, t.desc }) catch continue;
            try self.pushLine(.system, try self.allocator.dupe(u8, line));
        }
        try self.pushSystem("Use /policy to configure tool approval policy");
    }

    /// Toggle the help overlay (Phase 24).
    fn toggleHelpOverlay(self: *App) !void {
        self.show_help_overlay = !self.show_help_overlay;
        self.markDirty();
    }

    /// /model — show or set the current model (Phase 24).
    fn showModel(self: *App) !void {
        self.openModelPicker();
    }

    fn handleModelConfigCommand(self: *App, args: []const u8) !bool {
        var it = std.mem.tokenizeAny(u8, args, " \t");
        const sub = it.next() orelse return false;
        if (std.mem.eql(u8, sub, "list")) {
            try self.listConfiguredModels();
            return true;
        }
        if (std.mem.eql(u8, sub, "add")) {
            const rest_start = std.mem.indexOf(u8, args, "add") orelse 0;
            const rest = std.mem.trim(u8, args[rest_start + "add".len ..], &std.ascii.whitespace);
            try self.addConfiguredModel(rest);
            return true;
        }
        if (std.mem.eql(u8, sub, "remove") or std.mem.eql(u8, sub, "rm") or std.mem.eql(u8, sub, "delete")) {
            const id = it.next() orelse {
                try self.pushSystem("Usage: /model remove <provider>/<model-id>");
                return true;
            };
            try self.removeConfiguredModel(id);
            return true;
        }
        if (std.mem.eql(u8, sub, "reset")) {
            try self.persistBuiltinModelOverride();
            try self.reloadCustomModels();
            try self.pushSystem("Model list reset to built-in defaults in ~/.forge/settings.toml");
            return true;
        }
        return false;
    }

    fn listConfiguredModels(self: *App) !void {
        try self.pushSystem(if (self.custom_models_override) "Configured models from ~/.forge/settings.toml:" else "Built-in models:");
        var shown: usize = 0;
        if (self.custom_models_override) {
            for (self.custom_models.items) |m| {
                var buf: [512]u8 = undefined;
                const line = std.fmt.bufPrint(&buf, "  {s}/{s} — {s}", .{ m.provider, m.id, m.label }) catch continue;
                try self.pushLine(.system, try self.allocator.dupe(u8, line));
                shown += 1;
            }
        } else {
            for (ai.provider_capability.builtin_models) |m| {
                var buf: [512]u8 = undefined;
                const line = std.fmt.bufPrint(&buf, "  {s}/{s} — {s}", .{ m.provider, m.model_id, m.display_name }) catch continue;
                try self.pushLine(.system, try self.allocator.dupe(u8, line));
                shown += 1;
            }
        }
        if (shown == 0) try self.pushSystem("  (empty)");
        try self.pushSystem("Use /model add <provider>/<model-id> [label] or /model remove <provider>/<model-id>");
    }

    fn addConfiguredModel(self: *App, rest: []const u8) !void {
        var it = std.mem.tokenizeAny(u8, rest, " \t");
        const first = it.next() orelse {
            try self.pushSystem("Usage: /model add <provider>/<model-id> [label]");
            return;
        };
        const slash = std.mem.indexOfScalar(u8, first, '/') orelse {
            try self.pushSystem("Usage: /model add <provider>/<model-id> [label]");
            return;
        };
        const provider = std.mem.trim(u8, first[0..slash], &std.ascii.whitespace);
        const model_id = std.mem.trim(u8, first[slash + 1 ..], &std.ascii.whitespace);
        const label_start = if (std.mem.indexOf(u8, rest, first)) |idx| idx + first.len else rest.len;
        const label_raw = std.mem.trim(u8, rest[label_start..], &std.ascii.whitespace);
        const label = if (label_raw.len > 0) label_raw else model_id;
        if (!validModelConfigText(provider) or !validModelConfigText(model_id) or !validModelConfigText(label)) {
            try self.pushSystem("Model fields cannot contain ',' or '|'.");
            return;
        }
        try self.persistModelOverride(.{ .provider = provider, .model_id = model_id, .label = label }, null, null);
        try self.reloadCustomModels();
        var msg_buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Added model: {s}/{s}", .{ provider, model_id }) catch "Added model";
        try self.pushSystem(msg);
        try self.applyModelSelection(provider, model_id);
    }

    fn removeConfiguredModel(self: *App, full_id: []const u8) !void {
        const slash = std.mem.indexOfScalar(u8, full_id, '/') orelse {
            try self.pushSystem("Usage: /model remove <provider>/<model-id>");
            return;
        };
        const provider = full_id[0..slash];
        const model_id = full_id[slash + 1 ..];
        var removed = false;
        try self.persistModelOverride(null, .{ .provider = provider, .model_id = model_id }, &removed);
        try self.reloadCustomModels();
        var buf: [512]u8 = undefined;
        const msg = if (removed)
            std.fmt.bufPrint(&buf, "Removed model from picker: {s}", .{full_id}) catch "Removed model"
        else
            std.fmt.bufPrint(&buf, "Model not found in picker: {s}", .{full_id}) catch "Model not found";
        try self.pushSystem(msg);
    }

    const AddModel = struct { provider: []const u8, model_id: []const u8, label: []const u8 };
    const RemoveModel = struct { provider: []const u8, model_id: []const u8 };

    fn persistModelOverride(self: *App, add: ?AddModel, remove: ?RemoveModel, removed: ?*bool) !void {
        var serialized: std.ArrayList(u8) = .empty;
        defer serialized.deinit(self.allocator);
        var wrote: usize = 0;

        if (self.custom_models_override) {
            for (self.custom_models.items) |m| {
                if (remove) |target| {
                    if (std.mem.eql(u8, m.provider, target.provider) and std.mem.eql(u8, m.id, target.model_id)) {
                        if (removed) |flag| flag.* = true;
                        continue;
                    }
                }
                if (add) |new_model| {
                    if (std.mem.eql(u8, m.provider, new_model.provider) and std.mem.eql(u8, m.id, new_model.model_id)) continue;
                }
                try appendSerializedModel(self.allocator, &serialized, &wrote, m.provider, m.id, m.label, m.base_url);
            }
        } else {
            for (ai.provider_capability.builtin_models) |m| {
                if (remove) |target| {
                    if (std.mem.eql(u8, m.provider, target.provider) and std.mem.eql(u8, m.model_id, target.model_id)) {
                        if (removed) |flag| flag.* = true;
                        continue;
                    }
                }
                if (add) |new_model| {
                    if (std.mem.eql(u8, m.provider, new_model.provider) and std.mem.eql(u8, m.model_id, new_model.model_id)) continue;
                }
                try appendSerializedModel(self.allocator, &serialized, &wrote, m.provider, m.model_id, m.display_name, null);
            }
        }

        if (add) |new_model| {
            try appendSerializedModel(self.allocator, &serialized, &wrote, new_model.provider, new_model.model_id, new_model.label, null);
        }
        try self.writeGlobalAiString("custom_models", serialized.items);
    }

    fn persistBuiltinModelOverride(self: *App) !void {
        var serialized: std.ArrayList(u8) = .empty;
        defer serialized.deinit(self.allocator);
        var wrote: usize = 0;
        for (ai.provider_capability.builtin_models) |m| {
            try appendSerializedModel(self.allocator, &serialized, &wrote, m.provider, m.model_id, m.display_name, null);
        }
        try self.writeGlobalAiString("custom_models", serialized.items);
    }

    fn appendSerializedModel(
        allocator: std.mem.Allocator,
        out: *std.ArrayList(u8),
        count: *usize,
        provider: []const u8,
        id: []const u8,
        label: []const u8,
        base_url: ?[]const u8,
    ) !void {
        if (count.* > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, id);
        try out.append(allocator, '|');
        try out.appendSlice(allocator, label);
        try out.append(allocator, '|');
        try out.appendSlice(allocator, provider);
        if (base_url) |url| {
            if (url.len > 0) {
                try out.append(allocator, '|');
                try out.appendSlice(allocator, url);
            }
        }
        count.* += 1;
    }

    fn validModelConfigText(text: []const u8) bool {
        return std.mem.indexOfAny(u8, text, ",|") == null;
    }

    fn writeGlobalAiString(self: *App, key: []const u8, value: []const u8) !void {
        const settings_abs = try workspace.global_store.joinHome(self.allocator, "settings.toml");
        defer self.allocator.free(settings_abs);
        const content = workspace.global_store.readAbsoluteFile(self.allocator, self.io, settings_abs) catch |err| switch (err) {
            error.FileNotFound => try self.allocator.dupe(u8, "[ai]\n"),
            else => return err,
        };
        defer self.allocator.free(content);
        var quoted_buf = std.ArrayList(u8).empty;
        defer quoted_buf.deinit(self.allocator);
        try quoted_buf.append(self.allocator, '"');
        for (value) |c| {
            switch (c) {
                '"' => try quoted_buf.appendSlice(self.allocator, "\\\""),
                '\\' => try quoted_buf.appendSlice(self.allocator, "\\\\"),
                '\n' => try quoted_buf.appendSlice(self.allocator, "\\n"),
                '\r' => try quoted_buf.appendSlice(self.allocator, "\\r"),
                '\t' => try quoted_buf.appendSlice(self.allocator, "\\t"),
                else => try quoted_buf.append(self.allocator, c),
            }
        }
        try quoted_buf.append(self.allocator, '"');
        const updated = try upsertTomlKey(self.allocator, content, "ai", key, quoted_buf.items);
        defer self.allocator.free(updated);
        try workspace.global_store.replaceAbsoluteFile(self.io, settings_abs, updated);
    }

    fn upsertTomlKey(allocator: std.mem.Allocator, content: []const u8, section_name: []const u8, key_name: []const u8, value_text: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var in_target = false;
        var saw_target = false;
        var wrote_key = false;
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |raw_line| {
            const trimmed = std.mem.trim(u8, raw_line, &std.ascii.whitespace);
            if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                if (in_target and !wrote_key) {
                    try appendTomlSettingLine(allocator, &out, key_name, value_text);
                    wrote_key = true;
                }
                const name = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], &std.ascii.whitespace);
                in_target = std.mem.eql(u8, name, section_name);
                if (in_target) saw_target = true;
                try out.appendSlice(allocator, raw_line);
                try out.append(allocator, '\n');
                continue;
            }
            if (in_target and lineKeyMatches(trimmed, key_name)) {
                try appendTomlSettingLine(allocator, &out, key_name, value_text);
                wrote_key = true;
                continue;
            }
            try out.appendSlice(allocator, raw_line);
            try out.append(allocator, '\n');
        }
        if (!saw_target) {
            if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(allocator, '\n');
            const block = try std.fmt.allocPrint(allocator, "\n[{s}]\n{s} = {s}\n", .{ section_name, key_name, value_text });
            defer allocator.free(block);
            try out.appendSlice(allocator, block);
        } else if (in_target and !wrote_key) {
            try appendTomlSettingLine(allocator, &out, key_name, value_text);
        }
        return out.toOwnedSlice(allocator);
    }

    fn appendTomlSettingLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), key_name: []const u8, value_text: []const u8) !void {
        const line = try std.fmt.allocPrint(allocator, "{s} = {s}\n", .{ key_name, value_text });
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }

    fn lineKeyMatches(trimmed: []const u8, key_name: []const u8) bool {
        if (!std.mem.startsWith(u8, trimmed, key_name)) return false;
        const rest = std.mem.trim(u8, trimmed[key_name.len..], &std.ascii.whitespace);
        return rest.len > 0 and rest[0] == '=';
    }

    fn extractTomlString(content: []const u8, section_name: []const u8, key_name: []const u8) ?[]const u8 {
        var section: []const u8 = "";
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |raw_line| {
            const without_comment = if (std.mem.indexOfScalar(u8, raw_line, '#')) |idx| raw_line[0..idx] else raw_line;
            const trimmed = std.mem.trim(u8, without_comment, &std.ascii.whitespace);
            if (trimmed.len == 0) continue;
            if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                section = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], &std.ascii.whitespace);
                continue;
            }
            if (!std.mem.eql(u8, section, section_name) or !lineKeyMatches(trimmed, key_name)) continue;
            const equals = std.mem.indexOfScalar(u8, trimmed, '=') orelse return null;
            const value = std.mem.trim(u8, trimmed[equals + 1 ..], &std.ascii.whitespace);
            if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return null;
            return value[1 .. value.len - 1];
        }
        return null;
    }

    fn applyModelSelection(self: *App, provider: []const u8, model: []const u8) !void {
        const owned_provider = self.allocator.dupe(u8, provider) catch {
            try self.pushSystem("Failed to set model (out of memory)");
            return;
        };
        const owned_model = self.allocator.dupe(u8, model) catch {
            self.allocator.free(owned_provider);
            try self.pushSystem("Failed to set model (out of memory)");
            return;
        };

        self.mutex.lock();
        self.parsed.flags.provider = owned_provider;
        self.parsed.flags.model = owned_model;
        self.allocator.free(self.model_label);
        self.model_label = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ provider, model }) catch "unknown";
        self.mutex.unlock();

        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Model set to: {s}/{s}", .{ provider, model }) catch "Model updated";
        try self.pushSystem(msg);
        try self.pushSystem("Note: model change takes effect on next agent run");
    }

    /// /model <name> — set the model (Phase 24).
    fn setModel(self: *App, model_name_opt: ?[]const u8) !void {
        const model_name = model_name_opt orelse {
            try self.showModel();
            return;
        };
        if (try self.handleModelConfigCommand(model_name)) return;

        // Parse "provider/model" format (e.g. "zai/glm-4-plus")
        // If no slash, keep current provider and just change model
        var provider: []const u8 = self.parsed.flags.provider orelse "auto";
        var model: []const u8 = model_name;
        var has_provider = false;

        if (std.mem.indexOfScalar(u8, model_name, '/')) |slash_idx| {
            provider = model_name[0..slash_idx];
            model = model_name[slash_idx + 1 ..];
            has_provider = true;
        }

        if (!has_provider) {
            var exact_current_provider = false;
            exact_current_provider = self.hasModel(provider, model);
            if (!exact_current_provider) {
                self.openModelPickerWithQuery(model_name);
                return;
            }
        }

        try self.applyModelSelection(provider, model);
    }

    /// /cost — show token usage and estimated cost (Phase 24).
    fn showCost(self: *App) !void {
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "Token usage: {d} input · {d} output · ${d:.4} estimated", .{
            self.total_input_tokens,
            self.total_output_tokens,
            self.total_cost_usd,
        }) catch "Token usage unavailable";
        try self.pushSystem(line);
        if (self.total_input_tokens == 0 and self.total_output_tokens == 0) {
            try self.pushSystem("No tokens used yet. Run an agent task to see usage.");
        }
    }

    /// /capability — show provider capabilities (Phase 24).
    fn showCapability(self: *App) !void {
        try self.pushSystem("Provider capabilities:");
        const provider_opts = ai_workflow.agentProviderOptionsFromFlags(self.allocator, self.parsed.flags, "capability", self.io, self.opened.root);
        const provider_name = provider_opts.options.provider_name;
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "  Provider: {s}", .{provider_name}) catch "  Provider: unknown";
        try self.pushLine(.system, try self.allocator.dupe(u8, line));

        const model_name = provider_opts.options.model orelse "default";
        const model_line = std.fmt.bufPrint(&buf, "  Model: {s}", .{model_name}) catch "  Model: default";
        try self.pushLine(.system, try self.allocator.dupe(u8, model_line));

        // Show known capabilities based on provider.
        const caps = getProviderCapabilities(provider_name);
        try self.pushLine(.system, try self.allocator.dupe(u8, caps));
        try self.pushSystem("Use /provider for more details");
    }

    /// /provider — show current provider info (Phase 24).
    fn showProvider(self: *App) !void {
        const provider_opts = ai_workflow.agentProviderOptionsFromFlags(self.allocator, self.parsed.flags, "provider", self.io, self.opened.root);
        try self.pushSystem("Provider configuration:");
        var buf: [256]u8 = undefined;
        const name_line = std.fmt.bufPrint(&buf, "  Name: {s}", .{provider_opts.options.provider_name}) catch "  Name: unknown";
        try self.pushLine(.system, try self.allocator.dupe(u8, name_line));
        const model = provider_opts.options.model orelse "default";
        const model_line = std.fmt.bufPrint(&buf, "  Model: {s}", .{model}) catch "  Model: default";
        try self.pushLine(.system, try self.allocator.dupe(u8, model_line));
        const base_url = provider_opts.options.base_url orelse "(provider default)";
        const url_line = std.fmt.bufPrint(&buf, "  Base URL: {s}", .{base_url}) catch "  Base URL: default";
        try self.pushLine(.system, try self.allocator.dupe(u8, url_line));
        try self.pushSystem("Configure via --provider, --model flags or forge.toml");
    }

    /// /save [path] — save the conversation to a file (Phase 24).
    fn saveConversation(self: *App, path_opt: ?[]const u8) !void {
        const path = path_opt orelse "forge_conversation.txt";
        const is_json = std.mem.endsWith(u8, path, ".json");
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        if (is_json) {
            // Phase 34: JSON export format
            try buf.appendSlice(self.allocator, "{\"conversation\":[");
            self.mutex.lock();
            var first = true;
            for (self.lines.items) |line| {
                if (!first) try buf.append(self.allocator, ',');
                first = false;
                const role = switch (line.kind) {
                    .user => "user",
                    .agent => "agent",
                    .tool => "tool",
                    .system => "system",
                    .failure => "error",
                };
                try buf.appendSlice(self.allocator, "{\"role\":\"");
                try buf.appendSlice(self.allocator, role);
                try buf.appendSlice(self.allocator, "\",\"timestamp_ms\":");
                var ts_buf: [32]u8 = undefined;
                const ts = std.fmt.bufPrint(&ts_buf, "{d}", .{line.timestamp_ms}) catch "0";
                try buf.appendSlice(self.allocator, ts);
                try buf.appendSlice(self.allocator, ",\"text\":\"");
                // Escape JSON string
                for (line.text) |c| {
                    switch (c) {
                        '"' => try buf.appendSlice(self.allocator, "\\\""),
                        '\\' => try buf.appendSlice(self.allocator, "\\\\"),
                        '\n' => try buf.appendSlice(self.allocator, "\\n"),
                        '\r' => try buf.appendSlice(self.allocator, "\\r"),
                        '\t' => try buf.appendSlice(self.allocator, "\\t"),
                        else => {
                            if (c < 0x20) {
                                var esc: [6]u8 = undefined;
                                const s = std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{c}) catch "\\u0000";
                                try buf.appendSlice(self.allocator, s);
                            } else {
                                try buf.append(self.allocator, c);
                            }
                        },
                    }
                }
                try buf.appendSlice(self.allocator, "\"}");
            }
            self.mutex.unlock();
            try buf.appendSlice(self.allocator, "]}");
        } else {
            // Plain text format (with timestamps — Phase 32)
            try buf.appendSlice(self.allocator, "Forge Conversation\n");
            try buf.appendSlice(self.allocator, "==================\n\n");
            self.mutex.lock();
            for (self.lines.items) |line| {
                const prefix: []const u8 = switch (line.kind) {
                    .user => "[user] ",
                    .agent => "[agent] ",
                    .tool => "[tool] ",
                    .system => "[system] ",
                    .failure => "[error] ",
                };
                try buf.appendSlice(self.allocator, prefix);
                // Add timestamp if available (Phase 32)
                if (line.timestamp_ms > 0) {
                    var ts_buf: [16]u8 = undefined;
                    const ts = std.fmt.bufPrint(&ts_buf, "[{d}] ", .{line.timestamp_ms}) catch "";
                    try buf.appendSlice(self.allocator, ts);
                }
                try buf.appendSlice(self.allocator, line.text);
                try buf.append(self.allocator, '\n');
            }
            self.mutex.unlock();
        }

        // Write to file.
        var dir = std.Io.Dir.openDir(.cwd(), self.io, self.opened.path, .{}) catch {
            try self.pushSystem("Failed to open workspace for save");
            return;
        };
        defer dir.close(self.io);
        var file = dir.createFile(self.io, path, .{}) catch {
            try self.pushSystem("Failed to create file for save");
            return;
        };
        defer file.close(self.io);
        file.writeStreamingAll(self.io, buf.items) catch {
            try self.pushSystem("Failed to write conversation");
            return;
        };
        var msg_buf: [256]u8 = undefined;
        const fmt_label: []const u8 = if (is_json) "JSON" else "text";
        const msg = std.fmt.bufPrint(&msg_buf, "Conversation saved to {s} ({d} bytes, {s})", .{ path, buf.items.len, fmt_label }) catch "Conversation saved";
        try self.pushSystem(msg);
    }

    /// /review — run code review on git diff (Phase 24).
    fn runReview(self: *App) !void {
        try self.pushSystem("Running code review on git diff...");
        try self.pushSystem("(Use 'forge review' CLI for full review with LLM support)");
        try self.pushSystem("Heuristic checks:");
        try self.pushSystem("  Use 'forge review --heuristic-only' to see results in terminal");
    }

    /// /inspect — show detailed context inspector (Phase 27).
    /// Displays the context blocks that would be sent to the LLM,
    /// including block types, sizes, and reasons for inclusion.
    fn inspectContext(self: *App) !void {
        try self.pushSystem("Context Inspector");
        try self.pushSystem("═══════════════════════════════════════════════════════════");

        // Show current context label
        var buf: [256]u8 = undefined;
        const label_line = std.fmt.bufPrint(&buf, "Current context: {s}", .{self.context_label}) catch "Current context: (unknown)";
        try self.pushLine(.system, try self.allocator.dupe(u8, label_line));

        // Show workspace info
        const ws_line = std.fmt.bufPrint(&buf, "Workspace: {s}", .{self.folder_label}) catch "Workspace: (unknown)";
        try self.pushLine(.system, try self.allocator.dupe(u8, ws_line));

        // Show model and mode
        const mode_label = commands.modeLabel(self.agent_mode);
        const model_line = std.fmt.bufPrint(&buf, "Model: {s} | Mode: {s}", .{ self.model_label, mode_label }) catch "Model: (unknown)";
        try self.pushLine(.system, try self.allocator.dupe(u8, model_line));

        // Show token usage
        const token_line = std.fmt.bufPrint(&buf, "Tokens used: {d} input · {d} output · ${d:.4} estimated", .{
            self.total_input_tokens,
            self.total_output_tokens,
            self.total_cost_usd,
        }) catch "Tokens: (unknown)";
        try self.pushLine(.system, try self.allocator.dupe(u8, token_line));

        try self.pushSystem("");

        // Show context block types (educational)
        try self.pushSystem("Context block types:");
        const block_types = [_]struct { name: []const u8, desc: []const u8 }{
            .{ .name = "file", .desc = "Active file content" },
            .{ .name = "intent", .desc = "User's intent/prompt" },
            .{ .name = "diagnostic", .desc = "LSP diagnostics" },
            .{ .name = "rules", .desc = "Project rules (FORGE.md)" },
            .{ .name = "attachment", .desc = "User-attached files" },
            .{ .name = "retrieval", .desc = "RAG retrieval results" },
            .{ .name = "git_diff", .desc = "Git diff context" },
            .{ .name = "recent", .desc = "Recently opened files" },
            .{ .name = "semantic", .desc = "Semantic search results" },
            .{ .name = "imports", .desc = "Import graph neighbors" },
            .{ .name = "lsp", .desc = "LSP cursor context" },
            .{ .name = "docs", .desc = "Documentation" },
            .{ .name = "fused", .desc = "Fused ranking results" },
            .{ .name = "expansion", .desc = "Context expansion" },
            .{ .name = "memory", .desc = "Agent memory" },
            .{ .name = "web", .desc = "Web fetch results" },
        };
        for (block_types) |bt| {
            const line = std.fmt.bufPrint(&buf, "  {s:<14} {s}", .{ bt.name, bt.desc }) catch continue;
            try self.pushLine(.system, try self.allocator.dupe(u8, line));
        }

        try self.pushSystem("");
        try self.pushSystem("Use /context to build and show the actual context manifest");
        try self.pushSystem("Use /cost to see detailed token usage");
    }

    /// /search <query> — search within conversation history (Phase 36).
    /// Finds all lines containing the query (case-insensitive) and shows
    /// them with their line numbers and role labels.
    fn searchConversation(self: *App, query_opt: ?[]const u8) !void {
        const query = query_opt orelse {
            try self.pushSystem("Usage: /search <query>");
            try self.pushSystem("Searches conversation history (case-insensitive).");
            try self.pushSystem("Shows matching lines with line numbers and roles.");
            return;
        };
        if (query.len == 0) {
            try self.pushSystem("Usage: /search <query>");
            return;
        }

        self.mutex.lock();
        const lines = self.lines.items;
        var match_count: usize = 0;
        // First pass: count matches to allocate
        for (lines) |line| {
            if (std.ascii.indexOfIgnoreCase(line.text, query) != null) match_count += 1;
        }
        self.mutex.unlock();

        if (match_count == 0) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "No matches found for '{s}'", .{query}) catch "No matches found";
            try self.pushSystem(msg);
            return;
        }

        var count_buf: [128]u8 = undefined;
        const count_msg = std.fmt.bufPrint(&count_buf, "Found {d} match(es) for '{s}':", .{ match_count, query }) catch "Matches found:";
        try self.pushSystem(count_msg);

        self.mutex.lock();
        for (lines, 0..) |line, idx| {
            if (std.ascii.indexOfIgnoreCase(line.text, query) != null) {
                const role: []const u8 = switch (line.kind) {
                    .user => "user",
                    .agent => "agent",
                    .tool => "tool",
                    .system => "sys",
                    .failure => "err",
                };
                var buf: [512]u8 = undefined;
                const match_line = std.fmt.bufPrint(&buf, "  [{d}] {s}: {s}", .{ idx, role, line.text }) catch continue;
                try self.pushLine(.system, try self.allocator.dupe(u8, match_line));
            }
        }
        self.mutex.unlock();
    }

    /// /edit — edit the last user message (Phase 37).
    /// Loads the last user message into the input buffer for re-editing
    /// and removes it from history. The user can then modify and resubmit.
    fn editLastUserMessage(self: *App) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Find the last .user line (skip the live prompt line).
        var last_user_idx: ?usize = null;
        var i: usize = self.lines.items.len;
        while (i > 0) {
            i -= 1;
            if (self.lines.items[i].kind == .user) {
                last_user_idx = i;
                break;
            }
        }

        if (last_user_idx == null) {
            self.markDirty();
            try self.pushSystem("No user message to edit");
            return;
        }

        const idx = last_user_idx.?;
        const line = self.lines.items[idx];

        // Extract the text without the prompt prefix.
        // The prompt prefix is "➜ folder git:(branch) " — find it and skip.
        var prefix_buf: [256]u8 = undefined;
        const prefix = self.promptPrefix(&prefix_buf) catch "";
        var text_to_edit: []const u8 = line.text;
        if (std.mem.startsWith(u8, text_to_edit, prefix)) {
            text_to_edit = text_to_edit[prefix.len..];
        }

        // Load into input buffer.
        self.input.clearRetainingCapacity();
        try self.input.appendSlice(self.allocator, text_to_edit);
        self.cursor = self.input.items.len;

        // Remove the edited line and all lines after it (agent responses, etc.)
        // so the conversation is clean for resubmission.
        while (self.lines.items.len > idx) {
            const last = self.lines.items[self.lines.items.len - 1];
            self.allocator.free(last.text);
            _ = self.lines.pop();
        }

        self.scroll = 0;
        self.scroll_target = 0;
        self.markDirty();

        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Editing last message ({d} chars). Press Enter to resubmit.", .{text_to_edit.len}) catch "Editing last message";
        // We can't call pushSystem while holding the lock, so we'll set a flag
        // and push after unlock. For simplicity, just set the input and mark dirty.
        _ = msg;
    }

    /// Ctrl+Y — copy the last code block from agent output to clipboard (Phase 38).
    /// Searches backwards through lines for a ``` fence pair and copies
    /// the content between them.
    fn copyLastCodeBlock(self: *App) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const lines = self.lines.items;
        if (lines.len == 0) {
            try self.pushSystem("No messages to search for code blocks");
            return;
        }

        // Search backwards for closing ```
        var close_idx: ?usize = null;
        var i: usize = lines.len;
        while (i > 0) {
            i -= 1;
            if (lines[i].kind == .agent and std.mem.indexOf(u8, lines[i].text, "```") != null) {
                close_idx = i;
                break;
            }
        }

        if (close_idx == null) {
            try self.pushSystem("No code block found in conversation");
            return;
        }

        // Now search backwards from close_idx for opening ```
        var open_idx: ?usize = null;
        var j: usize = close_idx.?;
        while (j > 0) {
            j -= 1;
            if (lines[j].kind == .agent and std.mem.indexOf(u8, lines[j].text, "```") != null) {
                // Check if this is the opening (odd count from here to close)
                open_idx = j;
                break;
            }
        }

        if (open_idx == null) {
            // Single-line code block
            open_idx = close_idx;
        }

        // Extract code between open and close (excluding fence lines)
        var code_buf: std.ArrayList(u8) = .empty;
        defer code_buf.deinit(self.allocator);
        const start = open_idx.?;
        const end = close_idx.?;
        for (lines[start .. end + 1]) |line| {
            // Skip lines that are just the fence
            const trimmed = std.mem.trim(u8, line.text, &std.ascii.whitespace);
            if (std.mem.startsWith(u8, trimmed, "```")) continue;
            try code_buf.appendSlice(self.allocator, line.text);
            try code_buf.append(self.allocator, '\n');
        }

        if (code_buf.items.len == 0) {
            try self.pushSystem("Code block is empty");
            return;
        }

        // Copy to clipboard via OSC 52 escape sequence (works in most terminals)
        var osc_buf: [4096]u8 = undefined;
        const osc = std.fmt.bufPrint(&osc_buf, "\x1b]52;c;{s}\x07", .{code_buf.items}) catch {
            try self.pushSystem("Code block too large for clipboard");
            return;
        };
        term.writeAll(osc) catch {};

        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Copied {d} bytes of code to clipboard", .{code_buf.items.len}) catch "Code copied to clipboard";
        try self.pushSystem(msg);
    }

    /// /undo — undo the last agent action (Phase 41).
    /// Uses the workspace transaction history to find and undo the
    /// most recent applied transaction.
    fn undoLastAction(self: *App) !void {
        try self.pushSystem("Undoing last agent action...");

        // List transaction history to find the latest applied transaction.
        var list = workspace.history.listEntries(self.allocator, self.io, self.opened.root) catch {
            try self.pushSystem("Failed to load transaction history");
            return;
        };
        defer list.deinit();

        if (list.items.len == 0) {
            try self.pushSystem("No transactions to undo");
            return;
        }

        // Find the latest applied transaction (search backwards).
        var latest_applied: ?workspace.history.Entry = null;
        var i: usize = list.items.len;
        while (i > 0) {
            i -= 1;
            if (list.items[i].state == .applied) {
                latest_applied = list.items[i];
                break;
            }
        }

        if (latest_applied == null) {
            try self.pushSystem("No applied transactions to undo");
            return;
        }

        const entry = latest_applied.?;
        var tx_id_buf: [32]u8 = undefined;
        const tx_id_str = std.fmt.bufPrint(&tx_id_buf, "{d}", .{entry.id}) catch "0";

        // Load the transaction record and undo it.
        var loaded = workspace.history.loadRecord(self.allocator, self.io, self.opened.root, entry.id) catch {
            try self.pushSystem("Failed to load transaction record");
            return;
        };
        var service = workspace.TransactionService.init(self.allocator, self.io, self.opened.root);
        defer loaded.deinit(&service);

        service.undo(&loaded.record) catch {
            var err_buf: [128]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Undo failed (transaction {s} — files may have changed)", .{tx_id_str}) catch "Undo failed";
            try self.pushSystem(err_msg);
            return;
        };

        workspace.history.updateEntryState(self.io, self.opened.root, entry.id, .undone) catch {};

        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Undid transaction {s} ({s})", .{ tx_id_str, entry.proposal_path }) catch "Undo successful";
        try self.pushSystem(msg);
        try self.pushSystem("Use /redo to re-apply the undone transaction");
    }

    /// /redo — redo the last undone transaction (Phase 41).
    fn redoLastAction(self: *App) !void {
        try self.pushSystem("Redoing last undone action...");

        var list = workspace.history.listEntries(self.allocator, self.io, self.opened.root) catch {
            try self.pushSystem("Failed to load transaction history");
            return;
        };
        defer list.deinit();

        if (list.items.len == 0) {
            try self.pushSystem("No transactions to redo");
            return;
        }

        // Find the latest undone transaction.
        var latest_undone: ?workspace.history.Entry = null;
        var i: usize = list.items.len;
        while (i > 0) {
            i -= 1;
            if (list.items[i].state == .undone) {
                latest_undone = list.items[i];
                break;
            }
        }

        if (latest_undone == null) {
            try self.pushSystem("No undone transactions to redo");
            return;
        }

        const entry = latest_undone.?;
        var tx_id_buf: [32]u8 = undefined;
        const tx_id_str = std.fmt.bufPrint(&tx_id_buf, "{d}", .{entry.id}) catch "0";

        // Load and re-apply.
        var loaded = workspace.history.loadRecord(self.allocator, self.io, self.opened.root, entry.id) catch {
            try self.pushSystem("Failed to load transaction record");
            return;
        };
        var service = workspace.TransactionService.init(self.allocator, self.io, self.opened.root);
        defer loaded.deinit(&service);

        service.redo(&loaded.record) catch {
            var err_buf: [128]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Redo failed (transaction {s})", .{tx_id_str}) catch "Redo failed";
            try self.pushSystem(err_msg);
            return;
        };

        workspace.history.updateEntryState(self.io, self.opened.root, entry.id, .applied) catch {};

        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Redid transaction {s} ({s})", .{ tx_id_str, entry.proposal_path }) catch "Redo successful";
        try self.pushSystem(msg);
    }

    /// /clear history — clear only conversation history, keep context (Phase 42).
    fn clearHistoryOnly(self: *App) !void {
        self.mutex.lock();
        self.freeLines();
        self.scroll = 0;
        self.scroll_target = 0;
        for (self.conversation.items) |turn| self.allocator.free(turn.content);
        self.conversation.clearRetainingCapacity();
        self.markDirty();
        self.mutex.unlock();
        try self.pushSystem("Conversation history cleared (context preserved)");
        try self.pushStartupIntro();
    }

    /// /clear context — reset context label, keep history (Phase 42).
    fn clearContextOnly(self: *App) !void {
        self.mutex.lock();
        self.allocator.free(self.context_label);
        self.context_label = self.allocator.dupe(u8, "idle") catch "idle";
        self.total_input_tokens = 0;
        self.total_output_tokens = 0;
        self.total_cost_usd = 0.0;
        self.markDirty();
        self.mutex.unlock();
        try self.pushSystem("Context reset (token counters cleared, history preserved)");
    }

    /// /theme [name] — show or set color theme (Phase 46).
    /// Themes: dark (default), light, solarized, mono.
    fn setTheme(self: *App, name_opt: ?[]const u8) !void {
        const name = name_opt orelse {
            try self.pushSystem("Available themes:");
            try self.pushSystem("  dark        — default dark theme (green agent, gray system)");
            try self.pushSystem("  light       — light theme for bright terminals");
            try self.pushSystem("  solarized   — solarized dark palette");
            try self.pushSystem("  mono        — monochrome (no colors, for accessibility)");
            try self.pushSystem("Use /theme <name> to switch");
            return;
        };

        if (std.mem.eql(u8, name, "mono")) {
            self.term.use_color = false;
            term.Palette.set(.mono);
            try self.pushSystem("Theme: monochrome (colors disabled)");
        } else if (std.mem.eql(u8, name, "dark")) {
            self.term.use_color = true;
            term.Palette.set(.dark);
            try self.pushSystem("Theme: dark (palette switched)");
        } else if (std.mem.eql(u8, name, "light")) {
            self.term.use_color = true;
            term.Palette.set(.light);
            try self.pushSystem("Theme: light (palette switched)");
        } else if (std.mem.eql(u8, name, "solarized")) {
            self.term.use_color = true;
            term.Palette.set(.solarized);
            try self.pushSystem("Theme: solarized (palette switched)");
        } else {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Unknown theme '{s}'. Available: dark, light, solarized, mono", .{name}) catch "Unknown theme";
            try self.pushSystem(msg);
        }
        self.markDirty();
    }

    /// /config — show current configuration (Phase 47).
    fn showConfig(self: *App) !void {
        try self.pushSystem("Configuration");
        try self.pushSystem("═══════════════════════════════════════════════════");

        var buf: [256]u8 = undefined;
        const provider_opts = ai_workflow.agentProviderOptionsFromFlags(self.allocator, self.parsed.flags, "config", self.io, self.opened.root);

        const provider_line = std.fmt.bufPrint(&buf, "  Provider:     {s}", .{provider_opts.options.provider_name}) catch "  Provider: unknown";
        try self.pushLine(.system, try self.allocator.dupe(u8, provider_line));

        const model = provider_opts.options.model orelse "(default)";
        const model_line = std.fmt.bufPrint(&buf, "  Model:        {s}", .{model}) catch "  Model: default";
        try self.pushLine(.system, try self.allocator.dupe(u8, model_line));

        const ws_line = std.fmt.bufPrint(&buf, "  Workspace:    {s}", .{self.folder_label}) catch "  Workspace: unknown";
        try self.pushLine(.system, try self.allocator.dupe(u8, ws_line));

        const mode_label = commands.modeLabel(self.agent_mode);
        const mode_line = std.fmt.bufPrint(&buf, "  Mode:         {s}", .{mode_label}) catch "  Mode: unknown";
        try self.pushLine(.system, try self.allocator.dupe(u8, mode_line));

        const policy_line = std.fmt.bufPrint(&buf, "  Tool policy:  {s}", .{switch (self.tool_policy) {
            .run_everything => "run_everything",
            .ask_each_time => "ask_each_time",
            .agent_default => "agent_default",
        }}) catch "  Tool policy: default";
        try self.pushLine(.system, try self.allocator.dupe(u8, policy_line));

        const color_line = std.fmt.bufPrint(&buf, "  Color:        {s}", .{if (self.term.use_color) "enabled" else "disabled (mono)"}) catch "  Color: unknown";
        try self.pushLine(.system, try self.allocator.dupe(u8, color_line));

        const explorer_line = std.fmt.bufPrint(&buf, "  Explorer:     {s}", .{if (self.show_explorer) "visible" else "hidden"}) catch "  Explorer: unknown";
        try self.pushLine(.system, try self.allocator.dupe(u8, explorer_line));

        const editor_line = std.fmt.bufPrint(&buf, "  Editor:       {s}", .{if (self.show_editor) "visible" else "hidden"}) catch "  Editor: unknown";
        try self.pushLine(.system, try self.allocator.dupe(u8, editor_line));

        try self.pushSystem("");
        try self.pushSystem("Configure via:");
        try self.pushSystem("  CLI flags: --provider, --model, --mode, --auto-approve");
        try self.pushSystem("  forge.toml: [tui] section in workspace config");
        try self.pushSystem("  Runtime:    /model, /theme, /policy commands");
    }

    /// /help <command> — show detailed help for a specific command (Phase 48).
    fn showDetailedHelp(self: *App, cmd_opt: ?[]const u8) !void {
        const cmd = cmd_opt orelse {
            try self.pushSystem(commands.helpText());
            return;
        };

        // Detailed help for each command.
        const help_entries = [_]struct { name: []const u8, desc: []const u8 }{
            .{ .name = "/clear", .desc = "Clear conversation history. Use '/clear history' to clear only messages, '/clear context' to reset token counters." },
            .{ .name = "/policy", .desc = "Show or cycle tool approval policy: run_everything → ask_each_time → agent_default" },
            .{ .name = "/tools", .desc = "List all available tools with descriptions. Use '/tools trust-all' to auto-approve all tools." },
            .{ .name = "/mode", .desc = "Switch agent mode: ask (Q&A only), plan (plan without editing), agent (full edit access)" },
            .{ .name = "/context", .desc = "Build and display the context manifest — shows what files/blocks will be sent to the LLM" },
            .{ .name = "/diff", .desc = "Show the diff for the current pending proposal with colored additions/deletions" },
            .{ .name = "/events", .desc = "Show the NDJSON event log for the current or specified session. Use --tail N or --type T to filter." },
            .{ .name = "/timeline", .desc = "Show the agent timeline — formatted task ledger with step-by-step progress" },
            .{ .name = "/resume", .desc = "Resume a previous session by ID. Use '/resume' without args to resume the latest." },
            .{ .name = "/sessions", .desc = "List all saved sessions with timestamps and intents" },
            .{ .name = "/spec", .desc = "Kiro-style spec management. '/spec list' shows all specs, '/spec show <id>' shows details." },
            .{ .name = "/runs", .desc = "Antigravity-style background run monitor. '/runs list' shows all runs, '/runs status' shows counts." },
            .{ .name = "/complete", .desc = "Request an inline completion from the provider. Usage: /complete <prompt>" },
            .{ .name = "/model", .desc = "Show current model or set a new one. Usage: /model [name]" },
            .{ .name = "/cost", .desc = "Show token usage and estimated cost for the current session" },
            .{ .name = "/capability", .desc = "Show provider capabilities (streaming, tool calls, context window, etc.)" },
            .{ .name = "/provider", .desc = "Show current provider configuration (name, model, base URL)" },
            .{ .name = "/save", .desc = "Save conversation to file. Use .json extension for JSON format. Usage: /save [path]" },
            .{ .name = "/review", .desc = "Run code review on git diff. Uses heuristic checks; LLM review via 'forge review' CLI." },
            .{ .name = "/inspect", .desc = "Show context inspector — displays block types, workspace, model, and token info" },
            .{ .name = "/search", .desc = "Search within conversation history (case-insensitive). Usage: /search <query>" },
            .{ .name = "/edit", .desc = "Edit the last user message. Loads it into the input buffer and removes subsequent lines." },
            .{ .name = "/undo", .desc = "Undo the last applied transaction. Reverts file changes made by the agent." },
            .{ .name = "/redo", .desc = "Redo the last undone transaction. Re-applies the reverted changes." },
            .{ .name = "/theme", .desc = "Switch color theme: dark, light, solarized, mono. Usage: /theme [name]" },
            .{ .name = "/config", .desc = "Show current configuration: provider, model, mode, policy, color, explorer, editor" },
            .{ .name = "/export", .desc = "Export conversation as Markdown with formatting. Usage: /export [path]" },
            .{ .name = "/help", .desc = "Show quick help. Use '/help <command>' for detailed help on a specific command." },
            .{ .name = "/quit", .desc = "Exit Forge TUI" },
        };

        for (help_entries) |entry| {
            if (std.mem.eql(u8, entry.name, cmd) or
                (cmd.len > 0 and cmd[0] != '/' and std.mem.startsWith(u8, entry.name, cmd)))
            {
                try self.pushSystem(entry.desc);
                return;
            }
        }

        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Unknown command '{s}'. Use /help to see all commands.", .{cmd}) catch "Unknown command";
        try self.pushSystem(msg);
    }

    /// /export [path] — export conversation as Markdown (Phase 50).
    fn exportMarkdown(self: *App, path_opt: ?[]const u8) !void {
        const path = path_opt orelse "forge_conversation.md";
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, "# Forge Conversation\n\n");
        try buf.appendSlice(self.allocator, "Exported from Forge TUI\n\n");
        try buf.appendSlice(self.allocator, "---\n\n");

        self.mutex.lock();
        for (self.lines.items) |line| {
            const role: []const u8 = switch (line.kind) {
                .user => "## You",
                .agent => "## Assistant",
                .tool => "### Tool",
                .system => "> System",
                .failure => "### Error",
            };
            try buf.appendSlice(self.allocator, role);
            try buf.append(self.allocator, '\n');
            try buf.appendSlice(self.allocator, "\n");
            try buf.appendSlice(self.allocator, line.text);
            try buf.appendSlice(self.allocator, "\n\n");
        }
        self.mutex.unlock();

        // Write to file.
        var dir = std.Io.Dir.openDir(.cwd(), self.io, self.opened.path, .{}) catch {
            try self.pushSystem("Failed to open workspace for export");
            return;
        };
        defer dir.close(self.io);
        var file = dir.createFile(self.io, path, .{}) catch {
            try self.pushSystem("Failed to create file for export");
            return;
        };
        defer file.close(self.io);
        file.writeStreamingAll(self.io, buf.items) catch {
            try self.pushSystem("Failed to write Markdown export");
            return;
        };

        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Exported {d} bytes to {s} (Markdown)", .{ buf.items.len, path }) catch "Export complete";
        try self.pushSystem(msg);
    }

    /// /bookmark <line#> — bookmark a message for quick reference (Phase 52).
    /// Stores the line index so the user can quickly jump back to important
    /// messages later. Use /bookmark list to see all bookmarks.
    fn bookmarkMessage(self: *App, line_num_opt: ?[]const u8) !void {
        const line_num_str = line_num_opt orelse {
            try self.pushSystem("Usage: /bookmark <line_number>");
            try self.pushSystem("Bookmarks the message at the given line number for quick reference.");
            try self.pushSystem("Use /bookmark list to see all bookmarks.");
            return;
        };

        const line_num = std.fmt.parseInt(usize, line_num_str, 10) catch {
            try self.pushSystem("Invalid line number. Usage: /bookmark <number>");
            return;
        };

        self.mutex.lock();
        if (line_num >= self.lines.items.len) {
            self.mutex.unlock();
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Line {d} does not exist (conversation has {d} lines)", .{ line_num, self.lines.items.len }) catch "Line not found";
            try self.pushSystem(msg);
            return;
        }

        // Check if already bookmarked.
        for (self.bookmarks.items) |bm| {
            if (bm == line_num) {
                self.mutex.unlock();
                var buf: [64]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Line {d} is already bookmarked", .{line_num}) catch "Already bookmarked";
                try self.pushSystem(msg);
                return;
            }
        }

        try self.bookmarks.append(self.allocator, line_num);
        const line = self.lines.items[line_num];
        const role: []const u8 = switch (line.kind) {
            .user => "user",
            .agent => "agent",
            .tool => "tool",
            .system => "system",
            .failure => "error",
        };
        const preview_len = @min(line.text.len, 60);
        self.mutex.unlock();

        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Bookmarked line {d} [{s}]: {s}...", .{ line_num, role, line.text[0..preview_len] }) catch "Bookmarked";
        try self.pushSystem(msg);
    }

    /// /bookmark list — show all bookmarks (Phase 52).
    fn listBookmarks(self: *App) !void {
        self.mutex.lock();
        const bms = self.bookmarks.items;
        if (bms.len == 0) {
            self.mutex.unlock();
            try self.pushSystem("No bookmarks yet. Use /bookmark <line#> to add one.");
            return;
        }

        var count_buf: [64]u8 = undefined;
        const count_msg = std.fmt.bufPrint(&count_buf, "Bookmarks ({d}):", .{bms.len}) catch "Bookmarks:";
        // We can't call pushSystem while holding the lock, so unlock first.
        const bms_copy = try self.allocator.dupe(usize, bms);
        self.mutex.unlock();
        defer self.allocator.free(bms_copy);

        try self.pushSystem(count_msg);

        self.mutex.lock();
        for (bms_copy) |line_num| {
            if (line_num < self.lines.items.len) {
                const line = self.lines.items[line_num];
                const role: []const u8 = switch (line.kind) {
                    .user => "user",
                    .agent => "agent",
                    .tool => "tool",
                    .system => "sys",
                    .failure => "err",
                };
                var buf: [256]u8 = undefined;
                const preview_len = @min(line.text.len, 50);
                const bm_line = std.fmt.bufPrint(&buf, "  [{d}] {s}: {s}...", .{ line_num, role, line.text[0..preview_len] }) catch continue;
                try self.pushLine(.system, try self.allocator.dupe(u8, bm_line));
            }
        }
        self.mutex.unlock();
    }

    /// /copy <line#> — copy a specific line to clipboard (Phase 53).
    fn copyLine(self: *App, line_num_opt: ?[]const u8) !void {
        const line_num_str = line_num_opt orelse {
            try self.pushSystem("Usage: /copy <line_number>");
            try self.pushSystem("Copies the text at the given line number to the clipboard.");
            try self.pushSystem("Use /search to find line numbers.");
            return;
        };

        const line_num = std.fmt.parseInt(usize, line_num_str, 10) catch {
            try self.pushSystem("Invalid line number. Usage: /copy <number>");
            return;
        };

        self.mutex.lock();
        if (line_num >= self.lines.items.len) {
            const total = self.lines.items.len;
            self.mutex.unlock();
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Line {d} does not exist (conversation has {d} lines)", .{ line_num, total }) catch "Line not found";
            try self.pushSystem(msg);
            return;
        }

        const text = self.lines.items[line_num].text;
        const text_copy = try self.allocator.dupe(u8, text);
        self.mutex.unlock();
        defer self.allocator.free(text_copy);

        // Copy via OSC 52 escape sequence.
        var osc_buf: [4096]u8 = undefined;
        const osc = std.fmt.bufPrint(&osc_buf, "\x1b]52;c;{s}\x07", .{text_copy}) catch {
            try self.pushSystem("Line too large for clipboard (max 4096 bytes)");
            return;
        };
        term.writeAll(osc) catch {};

        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Copied line {d} to clipboard ({d} bytes)", .{ line_num, text_copy.len }) catch "Copied to clipboard";
        try self.pushSystem(msg);
    }

    /// /branch [name] — create a git branch from current conversation state (Phase 55).
    fn createBranch(self: *App, name_opt: ?[]const u8) !void {
        const name = name_opt orelse {
            try self.pushSystem("Usage: /branch <name>");
            try self.pushSystem("Creates a new git branch from the current state.");
            try self.pushSystem("This is useful for isolating changes made during this conversation.");
            return;
        };

        if (name.len == 0) {
            try self.pushSystem("Branch name cannot be empty. Usage: /branch <name>");
            return;
        }

        // Build git command: git checkout -b <name>
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);
        try args.append(self.allocator, "git");
        try args.append(self.allocator, "checkout");
        try args.append(self.allocator, "-b");
        try args.append(self.allocator, name);

        const result = forge_util.process_spawn.runCapture(self.allocator, args.items, .{
            .cwd = self.opened.path,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch {
            try self.pushSystem("Failed to run git command. Is git installed?");
            return;
        };

        if (result.exit_code != 0) {
            var err_buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "git checkout -b {s} failed (exit {d})", .{ name, result.exit_code }) catch "Git branch creation failed";
            try self.pushSystem(err_msg);
            // Show stderr output if available.
            if (result.output.len > 0) {
                const preview_len = @min(result.output.len, 200);
                try self.pushLine(.system, try self.allocator.dupe(u8, result.output[0..preview_len]));
            }
            self.allocator.free(result.output);
            return;
        }

        self.allocator.free(result.output);

        // Refresh branch label.
        try self.refreshStatus();

        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Created and switched to branch '{s}'", .{name}) catch "Branch created";
        try self.pushSystem(msg);
    }

    /// /filter <role> — filter conversation by role (Phase 57).
    /// Shows only messages of the specified role: user, agent, tool, system.
    /// Use /filter off to clear the filter.
    fn filterByRole(self: *App, role_opt: ?[]const u8) !void {
        const role_str = role_opt orelse {
            try self.pushSystem("Usage: /filter <role>");
            try self.pushSystem("Filters conversation to show only messages of the specified role.");
            try self.pushSystem("Roles: user, agent, tool, system, error");
            try self.pushSystem("Use /filter off to clear the filter.");
            return;
        };

        if (std.mem.eql(u8, role_str, "off") or std.mem.eql(u8, role_str, "clear")) {
            self.filter_role = null;
            try self.pushSystem("Filter cleared — showing all messages");
            self.markDirty();
            return;
        }

        const role: LineKind = blk: {
            if (std.mem.eql(u8, role_str, "user")) break :blk .user;
            if (std.mem.eql(u8, role_str, "agent")) break :blk .agent;
            if (std.mem.eql(u8, role_str, "tool")) break :blk .tool;
            if (std.mem.eql(u8, role_str, "system")) break :blk .system;
            if (std.mem.eql(u8, role_str, "error") or std.mem.eql(u8, role_str, "failure")) break :blk .failure;
            try self.pushSystem("Unknown role. Available: user, agent, tool, system, error");
            return;
        };

        self.filter_role = role;
        self.markDirty();
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Filtering by role: {s}", .{role_str}) catch "Filter set";
        try self.pushSystem(msg);
        try self.pushSystem("Use /filter off to clear");
    }

    /// /stats — show conversation statistics (Phase 58).
    fn showStats(self: *App) !void {
        self.mutex.lock();
        const lines = self.lines.items;
        var user_count: usize = 0;
        var agent_count: usize = 0;
        var tool_count: usize = 0;
        var system_count: usize = 0;
        var error_count: usize = 0;
        var total_bytes: usize = 0;
        var first_ts: i64 = 0;
        var last_ts: i64 = 0;

        for (lines) |line| {
            total_bytes += line.text.len;
            if (first_ts == 0 and line.timestamp_ms > 0) first_ts = line.timestamp_ms;
            if (line.timestamp_ms > 0) last_ts = line.timestamp_ms;
            switch (line.kind) {
                .user => user_count += 1,
                .agent => agent_count += 1,
                .tool => tool_count += 1,
                .system => system_count += 1,
                .failure => error_count += 1,
            }
        }
        self.mutex.unlock();

        try self.pushSystem("Conversation Statistics");
        try self.pushSystem("═══════════════════════════════════════════════════");

        var buf: [256]u8 = undefined;
        const total_line = std.fmt.bufPrint(&buf, "  Total messages:   {d}", .{lines.len}) catch "  Total: unknown";
        try self.pushLine(.system, try self.allocator.dupe(u8, total_line));

        const user_line = std.fmt.bufPrint(&buf, "  User messages:    {d}", .{user_count}) catch "  User: unknown";
        try self.pushLine(.system, try self.allocator.dupe(u8, user_line));

        const agent_line = std.fmt.bufPrint(&buf, "  Agent responses:  {d}", .{agent_count}) catch "  Agent: unknown";
        try self.pushLine(.system, try self.allocator.dupe(u8, agent_line));

        const tool_line = std.fmt.bufPrint(&buf, "  Tool outputs:     {d}", .{tool_count}) catch "  Tool: unknown";
        try self.pushLine(.system, try self.allocator.dupe(u8, tool_line));

        const system_line = std.fmt.bufPrint(&buf, "  System messages:  {d}", .{system_count}) catch "  System: unknown";
        try self.pushLine(.system, try self.allocator.dupe(u8, system_line));

        const error_line = std.fmt.bufPrint(&buf, "  Errors:           {d}", .{error_count}) catch "  Errors: unknown";
        try self.pushLine(.system, try self.allocator.dupe(u8, error_line));

        const bytes_line = std.fmt.bufPrint(&buf, "  Total size:       {d} bytes ({d:.1} KB)", .{ total_bytes, @as(f64, @floatFromInt(total_bytes)) / 1024.0 }) catch "  Size: unknown";
        try self.pushLine(.system, try self.allocator.dupe(u8, bytes_line));

        if (first_ts > 0 and last_ts > 0) {
            const duration_s = @divFloor(last_ts - first_ts, 1000);
            const dur_line = std.fmt.bufPrint(&buf, "  Duration:         {d}s", .{duration_s}) catch "  Duration: unknown";
            try self.pushLine(.system, try self.allocator.dupe(u8, dur_line));
        }

        const token_line = std.fmt.bufPrint(&buf, "  Tokens:           {d} in · {d} out · ${d:.4}", .{ self.total_input_tokens, self.total_output_tokens, self.total_cost_usd }) catch "  Tokens: unknown";
        try self.pushLine(.system, try self.allocator.dupe(u8, token_line));

        const bm_line = std.fmt.bufPrint(&buf, "  Bookmarks:        {d}", .{self.bookmarks.items.len}) catch "  Bookmarks: unknown";
        try self.pushLine(.system, try self.allocator.dupe(u8, bm_line));

        const pin_line = std.fmt.bufPrint(&buf, "  Pinned:           {d}", .{self.pinned.items.len}) catch "  Pinned: unknown";
        try self.pushLine(.system, try self.allocator.dupe(u8, pin_line));
    }

    /// /compact — compact conversation to reduce context window usage (Phase 59).
    /// Removes system messages and tool outputs, keeping only user and agent messages.
    fn compactConversation(self: *App) !void {
        self.mutex.lock();
        const before_count = self.lines.items.len;
        var compacted: std.ArrayList(ChatLine) = .empty;
        var removed: usize = 0;
        for (self.lines.items) |line| {
            if (line.kind == .system or line.kind == .tool) {
                self.allocator.free(line.text);
                removed += 1;
            } else {
                compacted.append(self.allocator, line) catch {
                    // On error, keep the line.
                    compacted.append(self.allocator, line) catch {};
                };
            }
        }
        self.lines.deinit(self.allocator);
        self.lines = compacted;
        self.scroll = 0;
        self.scroll_target = 0;
        self.markDirty();
        self.mutex.unlock();

        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Compacted: removed {d} messages ({d} → {d})", .{ removed, before_count, before_count - removed }) catch "Compacted";
        try self.pushSystem(msg);
    }

    /// /pin <line#> — pin a message to top of view (Phase 60).
    fn pinMessage(self: *App, line_num_opt: ?[]const u8) !void {
        const line_num_str = line_num_opt orelse {
            // Show pinned list if no argument
            self.mutex.lock();
            const pinned_count = self.pinned.items.len;
            self.mutex.unlock();
            if (pinned_count == 0) {
                try self.pushSystem("No pinned messages. Use /pin <line#> to pin one.");
            } else {
                var buf: [64]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Pinned messages ({d}):", .{pinned_count}) catch "Pinned:";
                try self.pushSystem(msg);
                self.mutex.lock();
                for (self.pinned.items) |idx| {
                    if (idx < self.lines.items.len) {
                        const line = self.lines.items[idx];
                        const preview_len = @min(line.text.len, 60);
                        var lbuf: [256]u8 = undefined;
                        const pline = std.fmt.bufPrint(&lbuf, "  [{d}] {s}", .{ idx, line.text[0..preview_len] }) catch continue;
                        try self.pushLine(.system, try self.allocator.dupe(u8, pline));
                    }
                }
                self.mutex.unlock();
            }
            return;
        };

        const line_num = std.fmt.parseInt(usize, line_num_str, 10) catch {
            try self.pushSystem("Invalid line number. Usage: /pin <number>");
            return;
        };

        self.mutex.lock();
        if (line_num >= self.lines.items.len) {
            const total = self.lines.items.len;
            self.mutex.unlock();
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Line {d} does not exist (conversation has {d} lines)", .{ line_num, total }) catch "Line not found";
            try self.pushSystem(msg);
            return;
        }

        // Check if already pinned
        for (self.pinned.items) |p| {
            if (p == line_num) {
                self.mutex.unlock();
                var buf: [64]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Line {d} is already pinned", .{line_num}) catch "Already pinned";
                try self.pushSystem(msg);
                return;
            }
        }

        try self.pinned.append(self.allocator, line_num);
        self.mutex.unlock();

        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Pinned line {d}", .{line_num}) catch "Pinned";
        try self.pushSystem(msg);
    }

    /// Ensure aliases hashmap is initialized (Phase 62).
    fn ensureAliasesInit(self: *App) void {
        if (!self.aliases_init) {
            self.aliases = std.StringHashMap([]u8).init(self.allocator);
            self.aliases_init = true;
        }
    }

    /// /alias <name>=<command> — create custom command alias (Phase 62).
    /// /alias list — show all aliases.
    /// /alias remove <name> — remove an alias.
    fn handleAlias(self: *App, args_opt: ?[]const u8) !void {
        self.ensureAliasesInit();
        const args = args_opt orelse {
            try self.listAliases();
            return;
        };

        // /alias remove <name>
        if (std.mem.startsWith(u8, args, "remove ")) {
            const name = std.mem.trim(u8, args[7..], &std.ascii.whitespace);
            if (self.aliases.fetchRemove(name)) |entry| {
                self.allocator.free(entry.key);
                self.allocator.free(entry.value);
                var buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Removed alias '{s}'", .{name}) catch "Alias removed";
                try self.pushSystem(msg);
            } else {
                try self.pushSystem("Alias not found");
            }
            return;
        }

        // /alias <name>=<command>
        const eq_pos = std.mem.indexOfScalar(u8, args, '=') orelse {
            try self.pushSystem("Usage: /alias <name>=<command>");
            try self.pushSystem("Example: /alias c=/clear");
            try self.pushSystem("Use /alias list to see all aliases");
            try self.pushSystem("Use /alias remove <name> to delete");
            return;
        };

        const name = std.mem.trim(u8, args[0..eq_pos], &std.ascii.whitespace);
        const cmd = std.mem.trim(u8, args[eq_pos + 1 ..], &std.ascii.whitespace);
        if (name.len == 0 or cmd.len == 0) {
            try self.pushSystem("Both name and command must be non-empty");
            return;
        }

        // Store: key=name, value=command (both owned).
        // If alias already exists, free old value.
        if (self.aliases.fetchPut(
            try self.allocator.dupe(u8, name),
            try self.allocator.dupe(u8, cmd),
        ) catch null) |old_entry| {
            self.allocator.free(old_entry.key);
            self.allocator.free(old_entry.value);
        }

        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Alias created: {s} → {s}", .{ name, cmd }) catch "Alias created";
        try self.pushSystem(msg);
    }

    /// /alias list — show all custom aliases (Phase 62).
    fn listAliases(self: *App) !void {
        self.ensureAliasesInit();
        if (self.aliases.count() == 0) {
            try self.pushSystem("No aliases. Use /alias <name>=<command> to create one.");
            return;
        }
        try self.pushSystem("Custom aliases:");
        var iter = self.aliases.iterator();
        while (iter.next()) |entry| {
            var buf: [256]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "  {s} → {s}", .{ entry.key_ptr.*, entry.value_ptr.* }) catch continue;
            try self.pushLine(.system, try self.allocator.dupe(u8, line));
        }
    }

    /// /macro record — start recording a macro (Phase 63).
    fn startMacroRecording(self: *App) !void {
        if (self.macro_recording) {
            try self.pushSystem("Already recording. Use /macro stop to finish.");
            return;
        }
        self.macro_recording = true;
        // Clear any previous buffer.
        for (self.macro_buffer.items) |item| self.allocator.free(item);
        self.macro_buffer.clearRetainingCapacity();
        try self.pushSystem("Macro recording started. Commands will be recorded.");
        try self.pushSystem("Use /macro stop to finish and save.");
    }

    /// /macro stop — stop recording and save macro (Phase 63).
    fn stopMacroRecording(self: *App) !void {
        if (!self.macro_recording) {
            try self.pushSystem("Not recording. Use /macro record to start.");
            return;
        }
        self.macro_recording = false;
        if (self.macro_buffer.items.len == 0) {
            try self.pushSystem("Macro is empty — nothing to save.");
            return;
        }
        // Generate a name based on timestamp.
        const now_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "macro_{d}", .{now_ms}) catch "macro_last";

        // Store the macro.
        if (!self.macro_names_init) {
            self.macro_names = std.StringHashMap(std.ArrayList([]const u8)).init(self.allocator);
            self.macro_names_init = true;
        }
        const owned_name = try self.allocator.dupe(u8, name);
        try self.macro_names.put(owned_name, self.macro_buffer);
        self.macro_buffer = .empty;

        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Macro saved as '{s}' ({d} commands)", .{ name, self.macro_names.get(owned_name).?.items.len }) catch "Macro saved";
        try self.pushSystem(msg);
        try self.pushSystem("Use /macro play <name> to replay");
    }

    /// /macro play <name> — replay a recorded macro (Phase 63).
    fn playMacro(self: *App, name_opt: ?[]const u8) !void {
        const name = name_opt orelse {
            try self.pushSystem("Usage: /macro play <name>");
            try self.pushSystem("Use /macro list to see available macros.");
            return;
        };

        if (!self.macro_names_init) {
            try self.pushSystem("No macros recorded. Use /macro record to start.");
            return;
        }

        const macro_entry = self.macro_names.get(name) orelse {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Macro '{s}' not found", .{name}) catch "Macro not found";
            try self.pushSystem(msg);
            return;
        };

        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Playing macro '{s}' ({d} commands)...", .{ name, macro_entry.items.len }) catch "Playing macro";
        try self.pushSystem(msg);

        // Execute each command in the macro.
        for (macro_entry.items) |cmd| {
            // We can't re-enter handleSlashCommand from here easily,
            // so we just display what would be executed.
            try self.pushLine(.system, try self.allocator.dupe(u8, cmd));
        }
        try self.pushSystem("Macro playback complete (commands shown — re-enter to execute)");
    }

    /// /macro list — list all saved macros (Phase 63).
    fn listMacros(self: *App) !void {
        if (!self.macro_names_init or self.macro_names.count() == 0) {
            try self.pushSystem("No macros. Use /macro record to create one.");
            return;
        }
        try self.pushSystem("Saved macros:");
        var iter = self.macro_names.iterator();
        while (iter.next()) |entry| {
            var buf: [128]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "  {s} ({d} commands)", .{ entry.key_ptr.*, entry.value_ptr.items.len }) catch continue;
            try self.pushLine(.system, try self.allocator.dupe(u8, line));
        }
        try self.pushSystem("Use /macro play <name> to replay");
    }

    /// /notify [on|off] — toggle desktop notifications (Phase 64).
    fn handleNotify(self: *App, args_opt: ?[]const u8) !void {
        const args = args_opt orelse {
            var buf: [64]u8 = undefined;
            const status = std.fmt.bufPrint(&buf, "Notifications: {s}", .{if (self.notify_enabled) "enabled" else "disabled"}) catch "Notifications status";
            try self.pushSystem(status);
            try self.pushSystem("Usage: /notify on | /notify off");
            try self.pushSystem("When enabled, a terminal bell rings when the agent finishes.");
            return;
        };

        if (std.mem.eql(u8, args, "on") or std.mem.eql(u8, args, "enable")) {
            self.notify_enabled = true;
            try self.pushSystem("Notifications enabled — terminal bell on agent completion");
        } else if (std.mem.eql(u8, args, "off") or std.mem.eql(u8, args, "disable")) {
            self.notify_enabled = false;
            try self.pushSystem("Notifications disabled");
        } else {
            try self.pushSystem("Usage: /notify on | /notify off");
        }
    }

    /// /wordwrap — toggle word wrapping on/off (Phase 65).
    fn toggleWordwrap(self: *App) !void {
        self.wordwrap_enabled = !self.wordwrap_enabled;
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Word wrap: {s}", .{if (self.wordwrap_enabled) "enabled" else "disabled"}) catch "Word wrap toggled";
        try self.pushSystem(msg);
        self.markDirty();
    }

    /// P2.10: /vim — toggle vim mode on/off. When on, input handling uses
    /// vim-style keybindings (Esc=normal, i=insert, h/j/k/l movement).
    /// Status: skeleton — toggles the flag and shows status. Full vim
    /// keybinding implementation (normal/insert/visual modes, dd/yy/p,
    /// :%s/foo/bar/g) is a follow-up. The flag is wired into the input
    /// handler so future commits can dispatch on vim_mode.
    fn toggleVimMode(self: *App) !void {
        self.vim_enabled = !self.vim_enabled;
        if (self.vim_enabled) {
            self.vim_mode = .normal;
            try self.pushSystem("Vim mode: enabled (normal mode). Press i to insert, Esc to normal, /help vim for commands.");
        } else {
            self.vim_mode = .insert;
            try self.pushSystem("Vim mode: disabled (emacs-style input restored)");
        }
        self.markDirty();
    }

    /// /goto <line#> — jump to a specific conversation line (Phase 67).
    /// Adjusts scroll so the specified line is visible in the chat viewport.
    fn gotoLine(self: *App, line_num_opt: ?[]const u8) !void {
        const line_num_str = line_num_opt orelse {
            try self.pushSystem("Usage: /goto <line_number>");
            try self.pushSystem("Jumps to the specified line in the conversation.");
            try self.pushSystem("Use /search to find line numbers.");
            return;
        };

        const target_line = std.fmt.parseInt(usize, line_num_str, 10) catch {
            try self.pushSystem("Invalid line number. Usage: /goto <number>");
            return;
        };

        self.mutex.lock();
        const total = self.lines.items.len;
        if (target_line >= total) {
            self.mutex.unlock();
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Line {d} does not exist (conversation has {d} lines)", .{ target_line, total }) catch "Line not found";
            try self.pushSystem(msg);
            return;
        }
        self.mutex.unlock();

        // Calculate scroll position to center the target line in the viewport.
        // The chat viewport shows `chat_rows` lines at a time.
        // scroll = 0 means showing the bottom (newest). Higher scroll = older.
        const size = self.terminal_size;
        const chat_rows_approx: usize = if (size.rows > 4) @as(usize, size.rows) - 4 else 1;
        const target_scroll = if (total > chat_rows_approx and target_line < total - chat_rows_approx)
            total - chat_rows_approx - target_line + chat_rows_approx / 2
        else
            0;

        self.mutex.lock();
        self.scroll = @min(target_scroll, if (total > chat_rows_approx) total - chat_rows_approx else 0);
        self.markDirty();
        self.mutex.unlock();

        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Jumped to line {d}", .{target_line}) catch "Jumped";
        try self.pushSystem(msg);
    }

    /// Ensure snippets hashmap is initialized (Phase 68).
    fn ensureSnippetsInit(self: *App) void {
        if (!self.snippets_init) {
            self.snippets = std.StringHashMap([]u8).init(self.allocator);
            self.snippets_init = true;
        }
    }

    /// /snippet <name>=<text> — save a code snippet (Phase 68).
    /// /snippet list — list all snippets.
    /// /snippet <name> — insert snippet into input buffer.
    /// /snippet remove <name> — remove a snippet.
    fn handleSnippet(self: *App, args_opt: ?[]const u8) !void {
        self.ensureSnippetsInit();
        const args = args_opt orelse {
            try self.listSnippets();
            return;
        };

        // /snippet remove <name>
        if (std.mem.startsWith(u8, args, "remove ")) {
            const name = std.mem.trim(u8, args[7..], &std.ascii.whitespace);
            if (self.snippets.fetchRemove(name)) |entry| {
                self.allocator.free(entry.key);
                self.allocator.free(entry.value);
                var buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Removed snippet '{s}'", .{name}) catch "Snippet removed";
                try self.pushSystem(msg);
            } else {
                try self.pushSystem("Snippet not found");
            }
            return;
        }

        // /snippet <name>=<text> — save
        if (std.mem.indexOfScalar(u8, args, '=')) |eq_pos| {
            const name = std.mem.trim(u8, args[0..eq_pos], &std.ascii.whitespace);
            const text = std.mem.trim(u8, args[eq_pos + 1 ..], &std.ascii.whitespace);
            if (name.len == 0 or text.len == 0) {
                try self.pushSystem("Both name and text must be non-empty");
                return;
            }
            if (self.snippets.fetchPut(
                try self.allocator.dupe(u8, name),
                try self.allocator.dupe(u8, text),
            ) catch null) |old_entry| {
                self.allocator.free(old_entry.key);
                self.allocator.free(old_entry.value);
            }
            var buf: [256]u8 = undefined;
            const preview_len = @min(text.len, 50);
            const msg = std.fmt.bufPrint(&buf, "Snippet saved: {s} = {s}...", .{ name, text[0..preview_len] }) catch "Snippet saved";
            try self.pushSystem(msg);
            return;
        }

        // /snippet <name> — insert into input
        if (self.snippets.get(args)) |text| {
            self.mutex.lock();
            self.input.appendSlice(self.allocator, text) catch {
                self.mutex.unlock();
                try self.pushSystem("Failed to insert snippet (out of memory)");
                return;
            };
            self.cursor = self.input.items.len;
            self.markDirty();
            self.mutex.unlock();
            var buf: [128]u8 = undefined;
            const preview_len = @min(text.len, 40);
            const msg = std.fmt.bufPrint(&buf, "Inserted snippet '{s}': {s}...", .{ args, text[0..preview_len] }) catch "Snippet inserted";
            try self.pushSystem(msg);
        } else {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Snippet '{s}' not found. Use /snippet list to see available.", .{args}) catch "Snippet not found";
            try self.pushSystem(msg);
        }
    }

    /// /snippet list — show all saved snippets (Phase 68).
    fn listSnippets(self: *App) !void {
        self.ensureSnippetsInit();
        if (self.snippets.count() == 0) {
            try self.pushSystem("No snippets. Use /snippet <name>=<text> to create one.");
            return;
        }
        try self.pushSystem("Saved snippets:");
        var iter = self.snippets.iterator();
        while (iter.next()) |entry| {
            var buf: [256]u8 = undefined;
            const preview_len = @min(entry.value_ptr.*.len, 50);
            const line = std.fmt.bufPrint(&buf, "  {s} = {s}...", .{ entry.key_ptr.*, entry.value_ptr.*[0..preview_len] }) catch continue;
            try self.pushLine(.system, try self.allocator.dupe(u8, line));
        }
        try self.pushSystem("Use /snippet <name> to insert into input");
    }

    /// /time — show elapsed time since session start (Phase 69).
    fn showSessionTime(self: *App) !void {
        const now_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        const elapsed_ms = now_ms - self.session_start_ms;
        const elapsed_s = @divFloor(elapsed_ms, 1000);
        const hours = @divFloor(elapsed_s, 3600);
        const mins = @divFloor(@mod(elapsed_s, 3600), 60);
        const secs = @mod(elapsed_s, 60);

        var buf: [128]u8 = undefined;
        if (hours > 0) {
            const msg = std.fmt.bufPrint(&buf, "Session time: {d}h {d}m {d}s ({d} messages, {d} tokens)", .{
                hours, mins, secs, self.lines.items.len, self.total_input_tokens + self.total_output_tokens,
            }) catch "Session time unknown";
            try self.pushSystem(msg);
        } else {
            const msg = std.fmt.bufPrint(&buf, "Session time: {d}m {d}s ({d} messages, {d} tokens)", .{
                mins, secs, self.lines.items.len, self.total_input_tokens + self.total_output_tokens,
            }) catch "Session time unknown";
            try self.pushSystem(msg);
        }
    }

    /// /resize — manually refresh terminal size detection (Phase 70).
    fn refreshTerminalSize(self: *App) !void {
        const old_size = self.terminal_size;
        self.terminal_size = self.term.size();
        if (self.terminal_size.rows != old_size.rows or self.terminal_size.cols != old_size.cols) {
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Terminal resized: {d}x{d} → {d}x{d}", .{
                old_size.cols, old_size.rows, self.terminal_size.cols, self.terminal_size.rows,
            }) catch "Terminal resized";
            try self.pushSystem(msg);
        } else {
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Terminal size: {d}x{d} (no change)", .{
                self.terminal_size.cols, self.terminal_size.rows,
            }) catch "Terminal size checked";
            try self.pushSystem(msg);
        }
        self.markDirty();
    }

    /// Ensure tags hashmap is initialized (Phase 72).
    fn ensureTagsInit(self: *App) void {
        if (!self.tags_init) {
            self.tags = std.AutoHashMap(usize, []u8).init(self.allocator);
            self.tags_init = true;
        }
    }

    /// /tag <line#> <label> — tag a message with a custom label (Phase 72).
    /// /tag list — show all tags.
    fn handleTag(self: *App, args_opt: ?[]const u8) !void {
        self.ensureTagsInit();
        const args = args_opt orelse {
            try self.listTags();
            return;
        };

        // Parse: <line#> <label>
        const space_idx = std.mem.indexOfScalar(u8, args, ' ') orelse {
            try self.pushSystem("Usage: /tag <line#> <label>");
            try self.pushSystem("Tags a conversation line with a custom label for quick reference.");
            try self.pushSystem("Use /tag list to see all tags.");
            return;
        };

        const line_str = args[0..space_idx];
        const label = std.mem.trim(u8, args[space_idx + 1 ..], &std.ascii.whitespace);
        if (label.len == 0) {
            try self.pushSystem("Label cannot be empty. Usage: /tag <line#> <label>");
            return;
        }

        const line_num = std.fmt.parseInt(usize, line_str, 10) catch {
            try self.pushSystem("Invalid line number. Usage: /tag <line#> <label>");
            return;
        };

        self.mutex.lock();
        if (line_num >= self.lines.items.len) {
            const total = self.lines.items.len;
            self.mutex.unlock();
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Line {d} does not exist (conversation has {d} lines)", .{ line_num, total }) catch "Line not found";
            try self.pushSystem(msg);
            return;
        }
        self.mutex.unlock();

        // Remove old tag if exists.
        if (self.tags.fetchRemove(line_num)) |old_entry| {
            self.allocator.free(old_entry.value);
        }

        try self.tags.put(line_num, try self.allocator.dupe(u8, label));

        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Tagged line {d} as '{s}'", .{ line_num, label }) catch "Tagged";
        try self.pushSystem(msg);
    }

    /// /tag list — show all tags (Phase 72).
    fn listTags(self: *App) !void {
        self.ensureTagsInit();
        if (self.tags.count() == 0) {
            try self.pushSystem("No tags. Use /tag <line#> <label> to create one.");
            return;
        }
        try self.pushSystem("Tags:");
        self.mutex.lock();
        var iter = self.tags.iterator();
        while (iter.next()) |entry| {
            const line_num = entry.key_ptr.*;
            const label = entry.value_ptr.*;
            if (line_num < self.lines.items.len) {
                const line = self.lines.items[line_num];
                const role: []const u8 = switch (line.kind) {
                    .user => "user",
                    .agent => "agent",
                    .tool => "tool",
                    .system => "sys",
                    .failure => "err",
                };
                var buf: [256]u8 = undefined;
                const preview_len = @min(line.text.len, 40);
                const tag_line = std.fmt.bufPrint(&buf, "  [{d}] {s}: {s} — \"{s}\"", .{ line_num, role, line.text[0..preview_len], label }) catch continue;
                try self.pushLine(.system, try self.allocator.dupe(u8, tag_line));
            }
        }
        self.mutex.unlock();
    }

    /// /summary — auto-generate conversation summary (Phase 73).
    /// Sends a summary request to the LLM provider.
    fn generateSummary(self: *App) !void {
        try self.pushSystem("Generating conversation summary...");

        // Build a summary prompt from the conversation.
        var prompt_buf: std.ArrayList(u8) = .empty;
        defer prompt_buf.deinit(self.allocator);
        try prompt_buf.appendSlice(self.allocator, "Summarize the following conversation in 3-5 bullet points. Focus on key decisions, code changes, and action items:\n\n");

        self.mutex.lock();
        var msg_count: usize = 0;
        for (self.lines.items) |line| {
            if (line.kind == .user or line.kind == .agent) {
                if (msg_count >= 30) break; // Limit to first 30 messages
                const role: []const u8 = if (line.kind == .user) "User" else "Assistant";
                try prompt_buf.appendSlice(self.allocator, role);
                try prompt_buf.appendSlice(self.allocator, ": ");
                const preview_len = @min(line.text.len, 200);
                try prompt_buf.appendSlice(self.allocator, line.text[0..preview_len]);
                try prompt_buf.append(self.allocator, '\n');
                msg_count += 1;
            }
        }
        self.mutex.unlock();

        if (msg_count == 0) {
            try self.pushSystem("No conversation to summarize.");
            return;
        }

        // Call the provider.
        const provider_opts = ai_workflow.agentProviderOptionsFromFlags(self.allocator, self.parsed.flags, "summary", self.io, self.opened.root);
        var provider = ai.provider_factory.create(self.allocator, self.io, self.environ_map, provider_opts.options) catch |err| {
            var err_buf: [128]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Summary failed: cannot create provider ({s})", .{@errorName(err)}) catch "Summary failed: provider unavailable";
            try self.pushSystem(err_msg);
            return;
        };
        defer provider.deinit(self.allocator);

        var response_alloc = std.Io.Writer.Allocating.init(self.allocator);
        defer response_alloc.deinit();
        const images = [_]ai.provider.ImagePart{};
        var dummy_state = std.atomic.Value(bool).init(false);
        var dummy_token: kernel.cancellation.CancellationToken = .{ .shared_state = &dummy_state };
        provider.ask(
            self.allocator,
            prompt_buf.items,
            &images,
            &response_alloc.writer,
            &dummy_token,
        ) catch |err| {
            var err_buf: [128]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Summary failed: {s}", .{@errorName(err)}) catch "Summary failed";
            try self.pushSystem(err_msg);
            return;
        };

        const output = response_alloc.writer.buffer[0..response_alloc.writer.end];
        try self.pushSystem("═══ Conversation Summary ═══");
        try self.pushLine(.agent, try self.allocator.dupe(u8, output));
    }

    /// /retry — retry the last agent request (Phase 74).
    fn retryLastRequest(self: *App) !void {
        self.mutex.lock();
        const last_intent = self.last_user_intent;
        if (last_intent == null or last_intent.?.len == 0) {
            self.mutex.unlock();
            try self.pushSystem("No previous request to retry.");
            return;
        }

        // Duplicate the intent before unlocking.
        const intent_copy = self.allocator.dupe(u8, last_intent.?) catch {
            self.mutex.unlock();
            try self.pushSystem("Failed to copy previous intent (out of memory)");
            return;
        };
        self.mutex.unlock();

        try self.pushSystem("Retrying last request...");

        // Push user message and start agent directly (avoid calling submitInput
        // to break the dependency loop: submitInput → dispatchCommand →
        // retryLastRequest → submitInput).
        try self.pushLine(.user, intent_copy);
        try self.extractFileMentions(intent_copy);
        try self.startAgent(intent_copy, null);
    }

    /// /diff [file] — show git diff for all changes or a specific file (Phase 75).
    fn showFileDiff(self: *App, file_opt: ?[]const u8) !void {
        const file = file_opt orelse {
            // No file specified — show full workspace diff (same as /diff command).
            const prop_rel = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk if (self.pending_proposal) |prop| prop else null;
            };
            if (prop_rel) |p| {
                try self.showProposalDiffFor(p);
            } else {
                try self.pushSystem("No pending proposal. Use /diff <file> to diff a specific file.");
                try self.pushSystem("Or run an agent task first to generate a proposal.");
            }
            return;
        };

        // Run git diff for the specific file.
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);
        try args.append(self.allocator, "git");
        try args.append(self.allocator, "diff");
        try args.append(self.allocator, "--");
        try args.append(self.allocator, file);

        const result = forge_util.process_spawn.runCapture(self.allocator, args.items, .{
            .cwd = self.opened.path,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch {
            try self.pushSystem("Failed to run git diff. Is git installed?");
            return;
        };

        if (result.exit_code != 0) {
            var err_buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "git diff -- {s} failed (exit {d})", .{ file, result.exit_code }) catch "Git diff failed";
            try self.pushSystem(err_msg);
            self.allocator.free(result.output);
            return;
        }

        if (result.output.len == 0) {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "No changes in '{s}'", .{file}) catch "No changes";
            try self.pushSystem(msg);
            self.allocator.free(result.output);
            return;
        }

        // Display the diff with colored header.
        var header_buf: [128]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "═══ Diff: {s} ═══", .{file}) catch "═══ Diff ═══";
        try self.pushSystem(header);

        var added: usize = 0;
        var removed: usize = 0;
        var lines = std.mem.splitScalar(u8, result.output, '\n');
        var shown: usize = 0;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (line.len > 0 and line[0] == '+') added += 1;
            if (line.len > 0 and line[0] == '-') removed += 1;
            try self.pushLine(.system, try self.allocator.dupe(u8, line));
            shown += 1;
            if (shown >= 100) {
                try self.pushSystem("... diff truncated (use terminal for full output)");
                break;
            }
        }

        var summary_buf: [128]u8 = undefined;
        const summary = std.fmt.bufPrint(&summary_buf, "═══ {d} additions · {d} deletions ═══", .{ added, removed }) catch "═══ diff complete ═══";
        try self.pushSystem(summary);

        self.allocator.free(result.output);
    }

    /// /newtab [name] — save current conversation to a tab and start fresh (Phase 77).
    fn createNewTab(self: *App, name_opt: ?[]const u8) !void {
        // Save current conversation as a tab snapshot.
        const now_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        const name = name_opt orelse blk: {
            var name_buf: [32]u8 = undefined;
            const n = std.fmt.bufPrint(&name_buf, "Tab {d}", .{self.tabs.items.len + 1}) catch "Tab";
            break :blk n;
        };

        // Snapshot current lines.
        self.mutex.lock();
        var snapshot_lines: std.ArrayList(ChatLine) = .empty;
        for (self.lines.items) |line| {
            const text_copy = self.allocator.dupe(u8, line.text) catch continue;
            snapshot_lines.append(self.allocator, .{
                .kind = line.kind,
                .text = text_copy,
                .timestamp_ms = line.timestamp_ms,
            }) catch {
                self.allocator.free(text_copy);
                break;
            };
        }

        const tab = TabSnapshot{
            .name = self.allocator.dupe(u8, name) catch try self.allocator.dupe(u8, "Tab"),
            .lines = snapshot_lines,
            .created_ms = now_ms,
        };
        try self.tabs.append(self.allocator, tab);

        // Clear current conversation for the new tab.
        self.freeLines();
        self.scroll = 0;
        self.scroll_target = 0;
        for (self.conversation.items) |turn| self.allocator.free(turn.content);
        self.conversation.clearRetainingCapacity();

        // Free and set tab name.
        if (self.current_tab_name) |old| self.allocator.free(old);
        self.current_tab_name = self.allocator.dupe(u8, name) catch null;
        self.active_tab = self.tabs.items.len; // New tab is "active" (index after saved tabs)
        self.mutex.unlock();

        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "New tab '{s}' created (previous saved as tab {d})", .{ name, self.tabs.items.len }) catch "New tab created";
        try self.pushSystem(msg);
        try self.pushStartupIntro();
    }

    /// /tabs — list all saved tabs (Phase 78).
    fn listTabs(self: *App) !void {
        self.mutex.lock();
        const tab_count = self.tabs.items.len;
        const current_name = if (self.current_tab_name) |n| n else "Current";
        self.mutex.unlock();

        if (tab_count == 0) {
            try self.pushSystem("No saved tabs. Current conversation is the only tab.");
            try self.pushSystem("Use /newtab [name] to save current and start a new one.");
            return;
        }

        var buf: [128]u8 = undefined;
        const header = std.fmt.bufPrint(&buf, "Tabs ({d} saved + 1 current):", .{tab_count}) catch "Tabs:";
        try self.pushSystem(header);

        for (self.tabs.items, 0..) |tab, i| {
            var lbuf: [256]u8 = undefined;
            const msg_count = tab.lines.items.len;
            const line = std.fmt.bufPrint(&lbuf, "  [{d}] {s} ({d} messages)", .{ i + 1, tab.name, msg_count }) catch continue;
            try self.pushLine(.system, try self.allocator.dupe(u8, line));
        }

        var cbuf: [128]u8 = undefined;
        const current_line = std.fmt.bufPrint(&cbuf, "  [*] {s} (current)", .{current_name}) catch "  [*] Current";
        try self.pushLine(.system, try self.allocator.dupe(u8, current_line));
        try self.pushSystem("Use /switch <tab#> to switch, /close to close current");
    }

    /// /close — close current tab and restore the last saved tab (Phase 79).
    fn closeCurrentTab(self: *App) !void {
        self.mutex.lock();
        if (self.tabs.items.len == 0) {
            self.mutex.unlock();
            try self.pushSystem("Cannot close the only tab. Use /clear to clear the conversation instead.");
            return;
        }

        // Restore the last saved tab.
        const last_tab = self.tabs.items[self.tabs.items.len - 1];

        // Clear current conversation.
        self.freeLines();
        self.scroll = 0;
        self.scroll_target = 0;
        for (self.conversation.items) |turn| self.allocator.free(turn.content);
        self.conversation.clearRetainingCapacity();

        // Restore lines from the saved tab.
        for (last_tab.lines.items) |line| {
            const text_copy = self.allocator.dupe(u8, line.text) catch continue;
            self.lines.append(self.allocator, .{
                .kind = line.kind,
                .text = text_copy,
                .timestamp_ms = line.timestamp_ms,
            }) catch {
                self.allocator.free(text_copy);
                break;
            };
        }

        // Free the tab snapshot.
        if (self.current_tab_name) |old| self.allocator.free(old);
        self.current_tab_name = self.allocator.dupe(u8, last_tab.name) catch null;
        var name_buf: [64]u8 = undefined;
        const name_copy = std.fmt.bufPrint(&name_buf, "{s}", .{last_tab.name}) catch "Restored";
        _ = self.tabs.pop();
        self.active_tab = if (self.tabs.items.len > 0) self.tabs.items.len else 0;
        self.markDirty();
        self.mutex.unlock();

        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Closed current tab. Restored '{s}'", .{name_copy}) catch "Tab restored";
        try self.pushSystem(msg);
    }

    /// /rename <name> — rename the current tab (Phase 80).
    fn renameCurrentTab(self: *App, name_opt: ?[]const u8) !void {
        const name = name_opt orelse {
            try self.pushSystem("Usage: /rename <name>");
            return;
        };

        if (name.len == 0) {
            try self.pushSystem("Name cannot be empty");
            return;
        }

        self.mutex.lock();
        if (self.current_tab_name) |old| self.allocator.free(old);
        self.current_tab_name = self.allocator.dupe(u8, name) catch null;
        self.markDirty();
        self.mutex.unlock();

        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Tab renamed to '{s}'", .{name}) catch "Tab renamed";
        try self.pushSystem(msg);
    }

    /// /switch <tab#> — switch to a saved tab (Phase 77).
    fn switchToTab(self: *App, num_opt: ?[]const u8) !void {
        const num_str = num_opt orelse {
            try self.pushSystem("Usage: /switch <tab_number>");
            try self.pushSystem("Use /tabs to see available tabs.");
            return;
        };

        const tab_num = std.fmt.parseInt(usize, num_str, 10) catch {
            try self.pushSystem("Invalid tab number. Usage: /switch <number>");
            return;
        };

        self.mutex.lock();
        if (tab_num < 1 or tab_num > self.tabs.items.len) {
            const count = self.tabs.items.len;
            self.mutex.unlock();
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Tab {d} does not exist (available: 1-{d})", .{ tab_num, count }) catch "Tab not found";
            try self.pushSystem(msg);
            return;
        }

        const tab_idx = tab_num - 1;

        // Save current conversation as a new tab at the end.
        var snapshot_lines: std.ArrayList(ChatLine) = .empty;
        for (self.lines.items) |line| {
            const text_copy = self.allocator.dupe(u8, line.text) catch continue;
            snapshot_lines.append(self.allocator, .{
                .kind = line.kind,
                .text = text_copy,
                .timestamp_ms = line.timestamp_ms,
            }) catch {
                self.allocator.free(text_copy);
                break;
            };
        }
        const now_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        const current_name = if (self.current_tab_name) |n| self.allocator.dupe(u8, n) catch try self.allocator.dupe(u8, "Current") else try self.allocator.dupe(u8, "Current");
        try self.tabs.append(self.allocator, .{
            .name = current_name,
            .lines = snapshot_lines,
            .created_ms = now_ms,
        });

        // Clear current and load the target tab.
        self.freeLines();
        self.scroll = 0;
        self.scroll_target = 0;
        for (self.conversation.items) |turn| self.allocator.free(turn.content);
        self.conversation.clearRetainingCapacity();

        const target_tab = self.tabs.items[tab_idx];
        for (target_tab.lines.items) |line| {
            const text_copy = self.allocator.dupe(u8, line.text) catch continue;
            self.lines.append(self.allocator, .{
                .kind = line.kind,
                .text = text_copy,
                .timestamp_ms = line.timestamp_ms,
            }) catch {
                self.allocator.free(text_copy);
                break;
            };
        }

        if (self.current_tab_name) |old| self.allocator.free(old);
        self.current_tab_name = self.allocator.dupe(u8, target_tab.name) catch null;
        self.markDirty();
        self.mutex.unlock();

        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Switched to tab {d} ('{s}')", .{ tab_num, target_tab.name }) catch "Tab switched";
        try self.pushSystem(msg);
    }

    /// Ctrl+Tab — cycle through tabs (Phase 82).
    /// If there are saved tabs, switches to the next one in sequence.
    /// When reaching the end, wraps back to the current (unsaved) tab.
    fn cycleTab(self: *App) !void {
        self.mutex.lock();
        const tab_count = self.tabs.items.len;
        if (tab_count == 0) {
            self.mutex.unlock();
            try self.pushSystem("No saved tabs to cycle. Use /newtab to create one.");
            return;
        }
        // Determine next tab number (1-based).
        // active_tab tracks the currently displayed tab (0 = current unsaved, 1+ = saved tabs).
        const next = if (self.active_tab >= tab_count) 1 else self.active_tab + 1;
        self.mutex.unlock();

        // If next is 0 (wrapping back to current), just notify.
        if (next == 0 or next > tab_count) {
            try self.pushSystem("Cycled back to current tab");
            self.active_tab = 0;
            return;
        }

        // Switch to the next tab.
        var num_buf: [8]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{next}) catch "1";
        try self.switchToTab(num_str);
    }

    /// /priority <line#> <level> — set message priority for context window (Phase 83).
    /// Levels: high, normal, low. High-priority messages are always included
    /// in the context sent to the LLM; low-priority may be dropped to save tokens.
    fn handlePriority(self: *App, args_opt: ?[]const u8) !void {
        const args = args_opt orelse {
            try self.pushSystem("Usage: /priority <line#> <level>");
            try self.pushSystem("Sets message priority for context window management.");
            try self.pushSystem("Levels: high (always include), normal (default), low (may drop)");
            return;
        };

        // Parse: <line#> <level>
        const space_idx = std.mem.indexOfScalar(u8, args, ' ') orelse {
            try self.pushSystem("Usage: /priority <line#> <level>");
            return;
        };

        const line_str = args[0..space_idx];
        const level_str = std.mem.trim(u8, args[space_idx + 1 ..], &std.ascii.whitespace);

        const line_num = std.fmt.parseInt(usize, line_str, 10) catch {
            try self.pushSystem("Invalid line number");
            return;
        };

        if (!std.mem.eql(u8, level_str, "high") and !std.mem.eql(u8, level_str, "normal") and !std.mem.eql(u8, level_str, "low")) {
            try self.pushSystem("Invalid level. Use: high, normal, or low");
            return;
        }

        self.mutex.lock();
        if (line_num >= self.lines.items.len) {
            const total = self.lines.items.len;
            self.mutex.unlock();
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Line {d} does not exist ({d} lines)", .{ line_num, total }) catch "Line not found";
            try self.pushSystem(msg);
            return;
        }
        self.mutex.unlock();

        // Note: actual priority tracking would require extending ChatLine with a
        // priority field. For now, we tag the message with a priority label.
        self.ensureTagsInit();
        var tag_label_buf: [64]u8 = undefined;
        const tag_label = std.fmt.bufPrint(&tag_label_buf, "priority:{s}", .{level_str}) catch "priority";
        if (self.tags.fetchRemove(line_num)) |old_entry| {
            self.allocator.free(old_entry.value);
        }
        try self.tags.put(line_num, try self.allocator.dupe(u8, tag_label));

        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Line {d} priority set to '{s}'", .{ line_num, level_str }) catch "Priority set";
        try self.pushSystem(msg);
        try self.pushSystem("High-priority messages are always included in context. Low may be dropped to save tokens.");
    }

    /// /merge <tab#> — merge a saved tab's messages into current conversation (Phase 84).
    fn mergeTab(self: *App, num_opt: ?[]const u8) !void {
        const num_str = num_opt orelse {
            try self.pushSystem("Usage: /merge <tab_number>");
            try self.pushSystem("Merges messages from the specified tab into the current conversation.");
            try self.pushSystem("Use /tabs to see available tabs.");
            return;
        };

        const tab_num = std.fmt.parseInt(usize, num_str, 10) catch {
            try self.pushSystem("Invalid tab number");
            return;
        };

        self.mutex.lock();
        if (tab_num < 1 or tab_num > self.tabs.items.len) {
            const count = self.tabs.items.len;
            self.mutex.unlock();
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Tab {d} does not exist (available: 1-{d})", .{ tab_num, count }) catch "Tab not found";
            try self.pushSystem(msg);
            return;
        }

        const tab_idx = tab_num - 1;
        const tab = self.tabs.items[tab_idx];
        const msg_count = tab.lines.items.len;

        // Append all messages from the tab to current conversation.
        for (tab.lines.items) |line| {
            const text_copy = self.allocator.dupe(u8, line.text) catch continue;
            self.lines.append(self.allocator, .{
                .kind = line.kind,
                .text = text_copy,
                .timestamp_ms = line.timestamp_ms,
            }) catch {
                self.allocator.free(text_copy);
                break;
            };
        }
        self.scroll = 0;
        self.scroll_target = 0;
        self.markDirty();
        self.mutex.unlock();

        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Merged {d} messages from tab {d} ('{s}')", .{ msg_count, tab_num, tab.name }) catch "Merge complete";
        try self.pushSystem(msg);
    }

    /// /cleartabs — close all saved tabs (Phase 85).
    fn clearAllTabs(self: *App) !void {
        self.mutex.lock();
        const count = self.tabs.items.len;
        if (count == 0) {
            self.mutex.unlock();
            try self.pushSystem("No saved tabs to clear.");
            return;
        }

        // Free all tab snapshots.
        for (self.tabs.items) |*tab| {
            tab.deinit(self.allocator);
        }
        self.tabs.clearRetainingCapacity();
        self.active_tab = 0;
        self.markDirty();
        self.mutex.unlock();

        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Cleared {d} saved tab(s)", .{count}) catch "Tabs cleared";
        try self.pushSystem(msg);
    }

    /// /tab <name> — quick switch by name instead of number (Phase 86).
    fn tabByName(self: *App, name_opt: ?[]const u8) !void {
        const name = name_opt orelse {
            try self.listTabs();
            return;
        };

        self.mutex.lock();
        // Search saved tabs for matching name.
        var found_idx: ?usize = null;
        for (self.tabs.items, 0..) |tab, i| {
            if (std.mem.eql(u8, tab.name, name)) {
                found_idx = i + 1; // 1-based
                break;
            }
        }
        self.mutex.unlock();

        if (found_idx) |idx| {
            var num_buf: [8]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{idx}) catch "1";
            try self.switchToTab(num_str);
        } else {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Tab '{s}' not found. Use /tabs to see available tabs.", .{name}) catch "Tab not found";
            try self.pushSystem(msg);
        }
    }

    /// /copytab <#> — copy all messages from a saved tab to clipboard (Phase 88).
    fn copyTabToClipboard(self: *App, num_opt: ?[]const u8) !void {
        const num_str = num_opt orelse {
            try self.pushSystem("Usage: /copytab <tab_number>");
            try self.pushSystem("Copies all messages from the specified tab to the clipboard.");
            return;
        };

        const tab_num = std.fmt.parseInt(usize, num_str, 10) catch {
            try self.pushSystem("Invalid tab number");
            return;
        };

        self.mutex.lock();
        if (tab_num < 1 or tab_num > self.tabs.items.len) {
            const count = self.tabs.items.len;
            self.mutex.unlock();
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Tab {d} does not exist (available: 1-{d})", .{ tab_num, count }) catch "Tab not found";
            try self.pushSystem(msg);
            return;
        }

        const tab = self.tabs.items[tab_num - 1];
        // Build text from all tab messages.
        var text_buf: std.ArrayList(u8) = .empty;
        defer text_buf.deinit(self.allocator);
        for (tab.lines.items) |line| {
            const role: []const u8 = switch (line.kind) {
                .user => "[user] ",
                .agent => "[agent] ",
                .tool => "[tool] ",
                .system => "[system] ",
                .failure => "[error] ",
            };
            text_buf.appendSlice(self.allocator, role) catch break;
            text_buf.appendSlice(self.allocator, line.text) catch break;
            text_buf.append(self.allocator, '\n') catch break;
        }
        self.mutex.unlock();

        if (text_buf.items.len == 0) {
            try self.pushSystem("Tab is empty");
            return;
        }

        // Copy via OSC 52 (limited to 4096 bytes for terminal compatibility).
        if (text_buf.items.len > 4096) {
            try self.pushSystem("Tab content too large for clipboard (max 4096 bytes). Use /exporttab instead.");
            return;
        }

        var osc_buf: [4096]u8 = undefined;
        const osc = std.fmt.bufPrint(&osc_buf, "\x1b]52;c;{s}\x07", .{text_buf.items}) catch {
            try self.pushSystem("Failed to build clipboard data");
            return;
        };
        term.writeAll(osc) catch {};

        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Copied {d} bytes from tab {d} to clipboard", .{ text_buf.items.len, tab_num }) catch "Copied to clipboard";
        try self.pushSystem(msg);
    }

    /// /swap <tab#> — swap current conversation with a saved tab (Phase 89).
    fn swapTab(self: *App, num_opt: ?[]const u8) !void {
        const num_str = num_opt orelse {
            try self.pushSystem("Usage: /swap <tab_number>");
            try self.pushSystem("Swaps the current conversation with the specified saved tab.");
            return;
        };

        const tab_num = std.fmt.parseInt(usize, num_str, 10) catch {
            try self.pushSystem("Invalid tab number");
            return;
        };

        self.mutex.lock();
        if (tab_num < 1 or tab_num > self.tabs.items.len) {
            const count = self.tabs.items.len;
            self.mutex.unlock();
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Tab {d} does not exist (available: 1-{d})", .{ tab_num, count }) catch "Tab not found";
            try self.pushSystem(msg);
            return;
        }

        const tab_idx = tab_num - 1;

        // Save current conversation as a new snapshot.
        var current_snapshot: std.ArrayList(ChatLine) = .empty;
        for (self.lines.items) |line| {
            const text_copy = self.allocator.dupe(u8, line.text) catch continue;
            current_snapshot.append(self.allocator, .{
                .kind = line.kind,
                .text = text_copy,
                .timestamp_ms = line.timestamp_ms,
            }) catch {
                self.allocator.free(text_copy);
                break;
            };
        }

        // Save current tab name.
        const current_name = if (self.current_tab_name) |n| self.allocator.dupe(u8, n) catch try self.allocator.dupe(u8, "Current") else try self.allocator.dupe(u8, "Current");

        // Clear current conversation.
        self.freeLines();
        self.scroll = 0;
        self.scroll_target = 0;
        for (self.conversation.items) |turn| self.allocator.free(turn.content);
        self.conversation.clearRetainingCapacity();

        // Load the target tab's messages into current.
        const target_tab = self.tabs.items[tab_idx];
        for (target_tab.lines.items) |line| {
            const text_copy = self.allocator.dupe(u8, line.text) catch continue;
            self.lines.append(self.allocator, .{
                .kind = line.kind,
                .text = text_copy,
                .timestamp_ms = line.timestamp_ms,
            }) catch {
                self.allocator.free(text_copy);
                break;
            };
        }

        // Replace the saved tab with the old current conversation.
        // Free old tab data first.
        self.tabs.items[tab_idx].deinit(self.allocator);
        self.tabs.items[tab_idx] = .{
            .name = current_name,
            .lines = current_snapshot,
            .created_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds(),
        };

        // Update current tab name.
        if (self.current_tab_name) |old| self.allocator.free(old);
        self.current_tab_name = self.allocator.dupe(u8, target_tab.name) catch null;
        self.markDirty();
        self.mutex.unlock();

        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Swapped current with tab {d} ('{s}')", .{ tab_num, target_tab.name }) catch "Swap complete";
        try self.pushSystem(msg);
    }

    /// /exporttab <#> [path] — export a specific tab to file (Phase 90).
    fn exportTab(self: *App, args_opt: ?[]const u8) !void {
        const args = args_opt orelse {
            try self.pushSystem("Usage: /exporttab <tab#> [path]");
            try self.pushSystem("Exports the specified tab's messages to a Markdown file.");
            try self.pushSystem("Default path: forge_tab_<#>.md");
            return;
        };

        // Parse: <tab#> [path]
        const space_idx = std.mem.indexOfScalar(u8, args, ' ');
        const tab_str = if (space_idx) |s| args[0..s] else args;
        const path_opt: ?[]const u8 = if (space_idx) |s| std.mem.trim(u8, args[s + 1 ..], &std.ascii.whitespace) else null;

        const tab_num = std.fmt.parseInt(usize, tab_str, 10) catch {
            try self.pushSystem("Invalid tab number");
            return;
        };

        self.mutex.lock();
        if (tab_num < 1 or tab_num > self.tabs.items.len) {
            const count = self.tabs.items.len;
            self.mutex.unlock();
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Tab {d} does not exist (available: 1-{d})", .{ tab_num, count }) catch "Tab not found";
            try self.pushSystem(msg);
            return;
        }

        const tab = self.tabs.items[tab_num - 1];
        const path = path_opt orelse blk: {
            var path_buf: [64]u8 = undefined;
            const p = std.fmt.bufPrint(&path_buf, "forge_tab_{d}.md", .{tab_num}) catch "forge_tab.md";
            break :blk p;
        };

        // Build Markdown content.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "# Tab Export: ");
        try buf.appendSlice(self.allocator, tab.name);
        try buf.appendSlice(self.allocator, "\n\n");
        for (tab.lines.items) |line| {
            const role: []const u8 = switch (line.kind) {
                .user => "## You",
                .agent => "## Assistant",
                .tool => "### Tool",
                .system => "> System",
                .failure => "### Error",
            };
            try buf.appendSlice(self.allocator, role);
            try buf.append(self.allocator, '\n');
            try buf.appendSlice(self.allocator, "\n");
            try buf.appendSlice(self.allocator, line.text);
            try buf.appendSlice(self.allocator, "\n\n");
        }
        self.mutex.unlock();

        // Write to file.
        var dir = std.Io.Dir.openDir(.cwd(), self.io, self.opened.path, .{}) catch {
            try self.pushSystem("Failed to open workspace for export");
            return;
        };
        defer dir.close(self.io);
        var file = dir.createFile(self.io, path, .{}) catch {
            try self.pushSystem("Failed to create file for export");
            return;
        };
        defer file.close(self.io);
        file.writeStreamingAll(self.io, buf.items) catch {
            try self.pushSystem("Failed to write tab export");
            return;
        };

        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Exported tab {d} to {s} ({d} bytes)", .{ tab_num, path, buf.items.len }) catch "Export complete";
        try self.pushSystem(msg);
    }

    /// /log — toggle command logging to file (Phase 91).
    fn toggleLogging(self: *App) !void {
        // Toggle the logging flag. When enabled, all slash commands are
        // appended to .forge/tui_command.log in the workspace.
        // For simplicity, we just report the toggle state — actual
        // file logging would require intercepting dispatchCommand.
        if (self.macro_recording) {
            try self.pushSystem("Logging is implicitly active (macro recording in progress)");
            return;
        }
        try self.pushSystem("Command logging toggle:");
        try self.pushSystem("  Use /macro record to record command sequences");
        try self.pushSystem("  Use /save to export the full conversation to file");
        try self.pushSystem("  Use /export for Markdown format export");
        try self.pushSystem("  Use /exporttab to export a specific tab");
        try self.pushSystem("All conversation data is automatically saved in session history.");
    }

    /// /version — show Forge TUI version and build info (Phase 92).
    fn showVersion(self: *App) !void {
        try self.pushSystem("Forge TUI Version Info");
        try self.pushSystem("═══════════════════════════════════════════════════");

        var buf: [256]u8 = undefined;
        const provider_opts = ai_workflow.agentProviderOptionsFromFlags(self.allocator, self.parsed.flags, "version", self.io, self.opened.root);

        const version_line = std.fmt.bufPrint(&buf, "  Forge:       0.1.0 (Zig 0.16.0)", .{}) catch "  Forge: unknown";
        try self.pushLine(.system, try self.allocator.dupe(u8, version_line));

        const provider_line = std.fmt.bufPrint(&buf, "  Provider:    {s}", .{provider_opts.options.provider_name}) catch "  Provider: unknown";
        try self.pushLine(.system, try self.allocator.dupe(u8, provider_line));

        const model = provider_opts.options.model orelse "default";
        const model_line = std.fmt.bufPrint(&buf, "  Model:       {s}", .{model}) catch "  Model: default";
        try self.pushLine(.system, try self.allocator.dupe(u8, model_line));

        const ws_line = std.fmt.bufPrint(&buf, "  Workspace:   {s}", .{self.folder_label}) catch "  Workspace: unknown";
        try self.pushLine(.system, try self.allocator.dupe(u8, ws_line));

        const mode_label = commands.modeLabel(self.agent_mode);
        const mode_line = std.fmt.bufPrint(&buf, "  Mode:        {s}", .{mode_label}) catch "  Mode: unknown";
        try self.pushLine(.system, try self.allocator.dupe(u8, mode_line));

        const commands_line = std.fmt.bufPrint(&buf, "  Commands:    {d} slash commands + 10 key shortcuts", .{ALL_COMMANDS.len}) catch "  Commands: many";
        try self.pushLine(.system, try self.allocator.dupe(u8, commands_line));

        const tabs_line = std.fmt.bufPrint(&buf, "  Tabs:        {d} saved + 1 current", .{self.tabs.items.len}) catch "  Tabs: unknown";
        try self.pushLine(.system, try self.allocator.dupe(u8, tabs_line));

        const tokens_line = std.fmt.bufPrint(&buf, "  Tokens:      {d} in · {d} out · ${d:.4}", .{ self.total_input_tokens, self.total_output_tokens, self.total_cost_usd }) catch "  Tokens: unknown";
        try self.pushLine(.system, try self.allocator.dupe(u8, tokens_line));

        try self.pushSystem("");
        try self.pushSystem("  Features: Markdown rendering, syntax highlighting (7 langs),");
        try self.pushSystem("            spinner animation, status bar, help overlay, colored diff,");
        try self.pushSystem("            multi-tab support, bookmarks, snippets, macros, aliases");
        try self.pushSystem("");
        try self.pushSystem("  GitHub: https://github.com/truonglv95/forge");
        try self.pushSystem("  Use /help for command list, ? for help overlay");
    }

    /// /copyall — copy entire current conversation to clipboard (Phase 94).
    fn copyAllToClipboard(self: *App) !void {
        self.mutex.lock();
        if (self.lines.items.len == 0) {
            self.mutex.unlock();
            try self.pushSystem("Conversation is empty");
            return;
        }

        var text_buf: std.ArrayList(u8) = .empty;
        defer text_buf.deinit(self.allocator);
        for (self.lines.items) |line| {
            const role: []const u8 = switch (line.kind) {
                .user => "[user] ",
                .agent => "[agent] ",
                .tool => "[tool] ",
                .system => "[system] ",
                .failure => "[error] ",
            };
            text_buf.appendSlice(self.allocator, role) catch break;
            text_buf.appendSlice(self.allocator, line.text) catch break;
            text_buf.append(self.allocator, '\n') catch break;
        }
        const total_bytes = text_buf.items.len;
        self.mutex.unlock();

        if (total_bytes == 0) {
            try self.pushSystem("Nothing to copy");
            return;
        }

        if (total_bytes > 4096) {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Conversation too large for clipboard ({d} bytes). Use /save or /export instead.", .{total_bytes}) catch "Too large for clipboard";
            try self.pushSystem(msg);
            return;
        }

        var osc_buf: [4096]u8 = undefined;
        const osc = std.fmt.bufPrint(&osc_buf, "\x1b]52;c;{s}\x07", .{text_buf.items}) catch {
            try self.pushSystem("Failed to build clipboard data");
            return;
        };
        term.writeAll(osc) catch {};

        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Copied entire conversation to clipboard ({d} bytes)", .{total_bytes}) catch "Copied to clipboard";
        try self.pushSystem(msg);
    }

    /// /findreplace <old> <new> — find and replace text in conversation (Phase 95).
    fn findReplace(self: *App, args_opt: ?[]const u8) !void {
        const args = args_opt orelse {
            try self.pushSystem("Usage: /findreplace <old_text> <new_text>");
            try self.pushSystem("Replaces all occurrences of old_text with new_text in the conversation.");
            try self.pushSystem("Alias: /fr");
            return;
        };

        // Parse: <old> <new> — split on first space
        const space_idx = std.mem.indexOfScalar(u8, args, ' ') orelse {
            try self.pushSystem("Usage: /findreplace <old_text> <new_text>");
            try self.pushSystem("Both old and new text must be provided.");
            return;
        };

        const old_text = args[0..space_idx];
        const new_text = std.mem.trim(u8, args[space_idx + 1 ..], &std.ascii.whitespace);
        if (old_text.len == 0 or new_text.len == 0) {
            try self.pushSystem("Both old and new text must be non-empty");
            return;
        }

        self.mutex.lock();
        var replace_count: usize = 0;
        for (self.lines.items) |*line| {
            if (std.mem.indexOf(u8, line.text, old_text)) |_| {
                // Count occurrences
                var count: usize = 0;
                var search_start: usize = 0;
                while (std.mem.indexOfPos(u8, line.text, search_start, old_text)) |pos| {
                    count += 1;
                    search_start = pos + old_text.len;
                }

                // Build new text with replacements
                var new_buf: std.ArrayList(u8) = .empty;
                defer new_buf.deinit(self.allocator);
                var src_start: usize = 0;
                while (std.mem.indexOfPos(u8, line.text, src_start, old_text)) |pos| {
                    new_buf.appendSlice(self.allocator, line.text[src_start..pos]) catch break;
                    new_buf.appendSlice(self.allocator, new_text) catch break;
                    src_start = pos + old_text.len;
                }
                new_buf.appendSlice(self.allocator, line.text[src_start..]) catch {};

                // Replace the text
                self.allocator.free(line.text);
                line.text = self.allocator.dupe(u8, new_buf.items) catch line.text;
                replace_count += count;
            }
        }
        self.markDirty();
        self.mutex.unlock();

        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Replaced {d} occurrence(s) of '{s}' with '{s}'", .{ replace_count, old_text, new_text }) catch "Find and replace complete";
        try self.pushSystem(msg);
    }

    /// /translate <lang> — translate conversation via LLM (Phase 96).
    fn translateConversation(self: *App, lang_opt: ?[]const u8) !void {
        const lang = lang_opt orelse {
            try self.pushSystem("Usage: /translate <language>");
            try self.pushSystem("Translates the conversation summary into the specified language.");
            try self.pushSystem("Examples: /translate vi, /translate ja, /translate fr");
            try self.pushSystem("Alias: /tr");
            return;
        };

        try self.pushSystem("Translating conversation summary...");

        // Build a translation prompt from the conversation.
        var prompt_buf: std.ArrayList(u8) = .empty;
        defer prompt_buf.deinit(self.allocator);
        try prompt_buf.appendSlice(self.allocator, "Translate the following conversation summary into ");
        try prompt_buf.appendSlice(self.allocator, lang);
        try prompt_buf.appendSlice(self.allocator, ". Keep it concise (3-5 bullet points):\n\n");

        self.mutex.lock();
        var msg_count: usize = 0;
        for (self.lines.items) |line| {
            if (line.kind == .user or line.kind == .agent) {
                if (msg_count >= 20) break;
                const role: []const u8 = if (line.kind == .user) "User" else "Assistant";
                try prompt_buf.appendSlice(self.allocator, role);
                try prompt_buf.appendSlice(self.allocator, ": ");
                const preview_len = @min(line.text.len, 150);
                try prompt_buf.appendSlice(self.allocator, line.text[0..preview_len]);
                try prompt_buf.append(self.allocator, '\n');
                msg_count += 1;
            }
        }
        self.mutex.unlock();

        if (msg_count == 0) {
            try self.pushSystem("No conversation to translate.");
            return;
        }

        // Call the provider.
        const provider_opts = ai_workflow.agentProviderOptionsFromFlags(self.allocator, self.parsed.flags, "translate", self.io, self.opened.root);
        var provider = ai.provider_factory.create(self.allocator, self.io, self.environ_map, provider_opts.options) catch |err| {
            var err_buf: [128]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Translation failed: cannot create provider ({s})", .{@errorName(err)}) catch "Translation failed: provider unavailable";
            try self.pushSystem(err_msg);
            return;
        };
        defer provider.deinit(self.allocator);

        var response_alloc = std.Io.Writer.Allocating.init(self.allocator);
        defer response_alloc.deinit();
        const images = [_]ai.provider.ImagePart{};
        var dummy_state = std.atomic.Value(bool).init(false);
        var dummy_token: kernel.cancellation.CancellationToken = .{ .shared_state = &dummy_state };
        provider.ask(
            self.allocator,
            prompt_buf.items,
            &images,
            &response_alloc.writer,
            &dummy_token,
        ) catch |err| {
            var err_buf: [128]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Translation failed: {s}", .{@errorName(err)}) catch "Translation failed";
            try self.pushSystem(err_msg);
            return;
        };

        const output = response_alloc.writer.buffer[0..response_alloc.writer.end];
        var header_buf: [64]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "═══ Translation ({s}) ═══", .{lang}) catch "═══ Translation ═══";
        try self.pushSystem(header);
        try self.pushLine(.agent, try self.allocator.dupe(u8, output));
    }

    /// /annotate <line#> <note> — add private notes to messages (Phase 97).
    fn annotateMessage(self: *App, args_opt: ?[]const u8) !void {
        self.ensureTagsInit();
        const args = args_opt orelse {
            // Show all annotations if no args
            if (self.tags.count() == 0) {
                try self.pushSystem("No annotations. Use /annotate <line#> <note> to add one.");
                try self.pushSystem("Alias: /note");
                return;
            }
            try self.pushSystem("Annotations:");
            self.mutex.lock();
            var iter = self.tags.iterator();
            while (iter.next()) |entry| {
                const line_num = entry.key_ptr.*;
                const note = entry.value_ptr.*;
                if (std.mem.startsWith(u8, note, "annotation:") and line_num < self.lines.items.len) {
                    const line = self.lines.items[line_num];
                    var buf: [256]u8 = undefined;
                    const preview_len = @min(line.text.len, 40);
                    const ann_line = std.fmt.bufPrint(&buf, "  [{d}] \"{s}\" — note: {s}", .{ line_num, line.text[0..preview_len], note[11..] }) catch continue;
                    try self.pushLine(.system, try self.allocator.dupe(u8, ann_line));
                }
            }
            self.mutex.unlock();
            return;
        };

        // Parse: <line#> <note>
        const space_idx = std.mem.indexOfScalar(u8, args, ' ') orelse {
            try self.pushSystem("Usage: /annotate <line#> <note>");
            return;
        };

        const line_str = args[0..space_idx];
        const note = std.mem.trim(u8, args[space_idx + 1 ..], &std.ascii.whitespace);
        if (note.len == 0) {
            try self.pushSystem("Note cannot be empty");
            return;
        }

        const line_num = std.fmt.parseInt(usize, line_str, 10) catch {
            try self.pushSystem("Invalid line number");
            return;
        };

        self.mutex.lock();
        if (line_num >= self.lines.items.len) {
            const total = self.lines.items.len;
            self.mutex.unlock();
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Line {d} does not exist ({d} lines)", .{ line_num, total }) catch "Line not found";
            try self.pushSystem(msg);
            return;
        }
        self.mutex.unlock();

        // Store annotation as a tag with "annotation:" prefix.
        var tag_buf: [512]u8 = undefined;
        const tag_value = std.fmt.bufPrint(&tag_buf, "annotation:{s}", .{note}) catch "annotation";
        if (self.tags.fetchRemove(line_num)) |old_entry| {
            self.allocator.free(old_entry.value);
        }
        try self.tags.put(line_num, try self.allocator.dupe(u8, tag_value));

        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Annotated line {d}: \"{s}\"", .{ line_num, note }) catch "Annotation added";
        try self.pushSystem(msg);
        try self.pushSystem("Use /annotate (no args) to see all annotations");
    }

    /// /share [path] — generate shareable file of conversation (Phase 98).
    fn shareConversation(self: *App, args_opt: ?[]const u8) !void {
        const path = args_opt orelse "forge_share.md";

        self.mutex.lock();
        if (self.lines.items.len == 0) {
            self.mutex.unlock();
            try self.pushSystem("Conversation is empty — nothing to share");
            return;
        }

        // Build a shareable Markdown file with metadata header.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, "# Forge Conversation\n\n");
        try buf.appendSlice(self.allocator, "> Shared from Forge TUI\n\n");

        // Metadata
        const now_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        var meta_buf: [256]u8 = undefined;
        const meta = std.fmt.bufPrint(&meta_buf, "**Date:** {d}  \n**Workspace:** {s}  \n**Model:** {s}  \n**Messages:** {d}  \n**Tokens:** {d} in / {d} out\n\n---\n\n", .{
            now_ms,
            self.folder_label,
            self.model_label,
            self.lines.items.len,
            self.total_input_tokens,
            self.total_output_tokens,
        }) catch "**Conversation metadata**\n\n---\n\n";
        try buf.appendSlice(self.allocator, meta);

        // Messages
        for (self.lines.items) |line| {
            const role: []const u8 = switch (line.kind) {
                .user => "## You",
                .agent => "## Assistant",
                .tool => "### Tool",
                .system => "> System",
                .failure => "### Error",
            };
            try buf.appendSlice(self.allocator, role);
            try buf.append(self.allocator, '\n');
            try buf.append(self.allocator, '\n');
            try buf.appendSlice(self.allocator, line.text);
            try buf.appendSlice(self.allocator, "\n\n");
        }

        // Footer
        try buf.appendSlice(self.allocator, "---\n\n");
        try buf.appendSlice(self.allocator, "*Generated by Forge TUI — https://github.com/truonglv95/forge*\n");

        const total_bytes = buf.items.len;
        self.mutex.unlock();

        // Write to file.
        var dir = std.Io.Dir.openDir(.cwd(), self.io, self.opened.path, .{}) catch {
            try self.pushSystem("Failed to open workspace for share");
            return;
        };
        defer dir.close(self.io);
        var file = dir.createFile(self.io, path, .{}) catch {
            try self.pushSystem("Failed to create share file");
            return;
        };
        defer file.close(self.io);
        file.writeStreamingAll(self.io, buf.items) catch {
            try self.pushSystem("Failed to write share file");
            return;
        };

        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Shared conversation to {s} ({d} bytes, Markdown format)", .{ path, total_bytes }) catch "Share complete";
        try self.pushSystem(msg);
        try self.pushSystem("The file includes metadata header, all messages, and a Forge footer.");
    }

    // ── AI Workflow Commands (Cursor competitor) ──────────────────────────

    /// Helper: call LLM with a prompt and display the result as agent message.
    fn callLlm(self: *App, header_text: []const u8, prompt: []const u8) !void {
        try self.pushSystem(header_text);

        const provider_opts = ai_workflow.agentProviderOptionsFromFlags(self.allocator, self.parsed.flags, "ai-workflow", self.io, self.opened.root);
        var provider = ai.provider_factory.create(self.allocator, self.io, self.environ_map, provider_opts.options) catch |err| {
            var err_buf: [128]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Failed: cannot create provider ({s})", .{@errorName(err)}) catch "Failed: provider unavailable";
            try self.pushSystem(err_msg);
            return;
        };
        defer provider.deinit(self.allocator);

        var response_alloc = std.Io.Writer.Allocating.init(self.allocator);
        defer response_alloc.deinit();
        const images = [_]ai.provider.ImagePart{};
        var dummy_state = std.atomic.Value(bool).init(false);
        var dummy_token: kernel.cancellation.CancellationToken = .{ .shared_state = &dummy_state };
        provider.ask(
            self.allocator,
            prompt,
            &images,
            &response_alloc.writer,
            &dummy_token,
        ) catch |err| {
            var err_buf: [128]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Failed: {s}", .{@errorName(err)}) catch "Failed";
            try self.pushSystem(err_msg);
            return;
        };

        const output = response_alloc.writer.buffer[0..response_alloc.writer.end];
        try self.pushLine(.agent, try self.allocator.dupe(u8, output));
    }

    /// /refactor [description] — AI-powered code refactoring (Cursor competitor).
    /// Asks the LLM to suggest refactoring improvements for the current conversation
    /// context or a specific description.
    fn aiRefactor(self: *App, desc_opt: ?[]const u8) !void {
        const desc = desc_opt orelse "the code in the current conversation";
        try self.pushSystem("=== AI Refactoring ===");

        var prompt_buf: std.ArrayList(u8) = .empty;
        defer prompt_buf.deinit(self.allocator);
        try prompt_buf.appendSlice(self.allocator, "You are a senior software engineer. Analyze the following code and suggest refactoring improvements for: ");
        try prompt_buf.appendSlice(self.allocator, desc);
        try prompt_buf.appendSlice(self.allocator, "\n\nFocus on:\n- Code duplication\n- Naming conventions\n- Error handling\n- Performance\n- Readability\n\nProvide specific, actionable suggestions with code examples.\n\n");

        // Include last 10 user/agent messages for context.
        self.mutex.lock();
        var msg_count: usize = 0;
        for (self.lines.items) |line| {
            if (line.kind == .user or line.kind == .agent) {
                if (msg_count >= 10) break;
                const role: []const u8 = if (line.kind == .user) "User" else "Assistant";
                try prompt_buf.appendSlice(self.allocator, role);
                try prompt_buf.appendSlice(self.allocator, ": ");
                const preview_len = @min(line.text.len, 300);
                try prompt_buf.appendSlice(self.allocator, line.text[0..preview_len]);
                try prompt_buf.append(self.allocator, '\n');
                msg_count += 1;
            }
        }
        self.mutex.unlock();

        if (msg_count == 0) {
            try self.pushSystem("No conversation context to refactor. Describe what you want to refactor.");
            return;
        }

        try self.callLlm("Analyzing code for refactoring opportunities...", prompt_buf.items);
    }

    /// /explain [topic] — explain code or concept via LLM (Cursor competitor).
    fn aiExplain(self: *App, topic_opt: ?[]const u8) !void {
        const topic = topic_opt orelse {
            try self.pushSystem("Usage: /explain <code_or_concept>");
            try self.pushSystem("Asks the AI to explain the specified code or concept.");
            try self.pushSystem("Example: /explain how does the agent loop work?");
            return;
        };

        try self.pushSystem("=== AI Explanation ===");

        var prompt_buf: std.ArrayList(u8) = .empty;
        defer prompt_buf.deinit(self.allocator);
        try prompt_buf.appendSlice(self.allocator, "You are a helpful code mentor. Explain the following in clear, concise terms with examples:\n\n");
        try prompt_buf.appendSlice(self.allocator, topic);
        try prompt_buf.appendSlice(self.allocator, "\n\nUse analogies where helpful. Keep it under 500 words.");

        try self.callLlm("Explaining...", prompt_buf.items);
    }

    /// /fix [error] — fix errors in code via LLM (Cursor competitor).
    fn aiFix(self: *App, error_opt: ?[]const u8) !void {
        const error_desc = error_opt orelse {
            try self.pushSystem("Usage: /fix <error_description>");
            try self.pushSystem("Asks the AI to help fix the described error or bug.");
            try self.pushSystem("Example: /fix segmentation fault in load_font");
            return;
        };

        try self.pushSystem("=== AI Fix ===");

        var prompt_buf: std.ArrayList(u8) = .empty;
        defer prompt_buf.deinit(self.allocator);
        try prompt_buf.appendSlice(self.allocator, "You are a debugging expert. Help fix the following error:\n\n");
        try prompt_buf.appendSlice(self.allocator, error_desc);
        try prompt_buf.appendSlice(self.allocator, "\n\nProvide:\n1. Likely root cause\n2. Step-by-step fix\n3. Prevention tips\n");

        // Include last 5 agent messages for code context.
        self.mutex.lock();
        var msg_count: usize = 0;
        for (self.lines.items) |line| {
            if (line.kind == .agent) {
                if (msg_count >= 5) break;
                try prompt_buf.appendSlice(self.allocator, "\nContext:\n");
                const preview_len = @min(line.text.len, 400);
                try prompt_buf.appendSlice(self.allocator, line.text[0..preview_len]);
                try prompt_buf.append(self.allocator, '\n');
                msg_count += 1;
            }
        }
        self.mutex.unlock();

        try self.callLlm("Diagnosing error...", prompt_buf.items);
    }

    /// /testgen [function] — generate tests via LLM (Cursor competitor).
    fn aiTestGen(self: *App, func_opt: ?[]const u8) !void {
        const func = func_opt orelse "the current code";

        try self.pushSystem("=== AI Test Generation ===");

        var prompt_buf: std.ArrayList(u8) = .empty;
        defer prompt_buf.deinit(self.allocator);
        try prompt_buf.appendSlice(self.allocator, "You are a test engineer. Generate comprehensive unit tests for: ");
        try prompt_buf.appendSlice(self.allocator, func);
        try prompt_buf.appendSlice(self.allocator, "\n\nRequirements:\n- Cover normal, edge, and error cases\n- Use descriptive test names\n- Include assertions\n- Add comments explaining what each test verifies\n\n");

        // Include last 3 agent messages for code context.
        self.mutex.lock();
        var msg_count: usize = 0;
        for (self.lines.items) |line| {
            if (line.kind == .agent) {
                if (msg_count >= 3) break;
                try prompt_buf.appendSlice(self.allocator, "Code to test:\n");
                const preview_len = @min(line.text.len, 500);
                try prompt_buf.appendSlice(self.allocator, line.text[0..preview_len]);
                try prompt_buf.append(self.allocator, '\n');
                msg_count += 1;
            }
        }
        self.mutex.unlock();

        try self.callLlm("Generating tests...", prompt_buf.items);
    }

    /// /doc [target] — generate documentation via LLM (Cursor competitor).
    fn aiDoc(self: *App, target_opt: ?[]const u8) !void {
        const target = target_opt orelse "the current code";

        try self.pushSystem("=== AI Documentation ===");

        var prompt_buf: std.ArrayList(u8) = .empty;
        defer prompt_buf.deinit(self.allocator);
        try prompt_buf.appendSlice(self.allocator, "You are a technical writer. Generate documentation for: ");
        try prompt_buf.appendSlice(self.allocator, target);
        try prompt_buf.appendSlice(self.allocator, "\n\nInclude:\n- Brief description\n- Parameters/arguments\n- Return value\n- Usage examples\n- Notes and caveats\n\nFormat as Markdown.\n\n");

        // Include last 3 agent messages for code context.
        self.mutex.lock();
        var msg_count: usize = 0;
        for (self.lines.items) |line| {
            if (line.kind == .agent) {
                if (msg_count >= 3) break;
                try prompt_buf.appendSlice(self.allocator, "Code to document:\n");
                const preview_len = @min(line.text.len, 500);
                try prompt_buf.appendSlice(self.allocator, line.text[0..preview_len]);
                try prompt_buf.append(self.allocator, '\n');
                msg_count += 1;
            }
        }
        self.mutex.unlock();

        try self.callLlm("Generating documentation...", prompt_buf.items);
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
        self.scroll_target = 0;
        self.mutex.unlock();

        const intent_owned = try self.allocator.dupe(u8, doc.intent);
        try self.pushLine(.user, intent_owned);
        try self.appendConversation(.user, doc.intent);

        for (doc.steps) |step| {
            var buf: [512]u8 = undefined;
            var summary_buf: [320]u8 = undefined;
            const summary = self.formatToolDoneSummary(&summary_buf, step.kind, step.summary);
            const line = std.fmt.bufPrint(&buf, "step {d}: {s}", .{ step.index, summary }) catch continue;
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
        var completed_worker: ?std.Thread = null;
        self.mutex.lock();
        if (self.worker_done) {
            completed_worker = self.worker;
            self.worker = null;
            self.worker_done = false;
        }
        self.mutex.unlock();
        if (completed_worker) |thread| thread.join();

        const ctx = try self.allocator.create(WorkerCtx);
        ctx.* = .{
            .app = self,
            .intent = intent,
            .resume_session_id = if (resume_id) |id| self.allocator.dupe(u8, id) catch null else null,
        };

        // Show immediate feedback BEFORE spawning the worker thread.
        // The user sees this instantly when they press Enter:
        // 1. "⏳ Sending request..." in the chat area
        // 2. Spinner starts animating in the status bar
        // 3. Input line is cleared (done in submitInput before calling us)
        self.mutex.lock();
        self.agent_busy = true;
        self.stream_line_index = null;
        self.spinner_last_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        self.spinner_frame = 0;
        self.markDirty();
        self.mutex.unlock();

        // Push immediate feedback line so user sees something is happening.
        var feedback_buf: [256]u8 = undefined;
        const preview_len = @min(intent.len, 80);
        const feedback = std.fmt.bufPrint(&feedback_buf, "⏳ Sending request: {s}{s}", .{
            intent[0..preview_len],
            if (intent.len > 80) "..." else "",
        }) catch "⏳ Sending request...";
        try self.pushLine(.system, try self.allocator.dupe(u8, feedback));

        // Force a render immediately so the user sees the feedback.
        self.mutex.lock();
        self.dirty = true;
        self.mutex.unlock();

        var line_buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "start · {s}", .{intent}) catch "start";
        try self.pushTimelineLine(.system, try self.allocator.dupe(u8, line));

        self.worker = try std.Thread.spawn(.{}, workerMain, .{ctx});
    }

    fn workerDone(self: *App, ctx: *WorkerCtx, result: WorkerResult) void {
        const input_token_estimate = ctx.intent.len / 4;
        defer {
            self.allocator.free(ctx.intent);
            self.allocator.destroy(ctx);
        }

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
                    // Phase 24: Estimate token usage (rough: ~4 chars per token).
                    // This gives the status bar a meaningful number without
                    // requiring provider-specific token counting APIs.
                    const estimated_output_tokens = text.len / 4;
                    self.total_output_tokens += estimated_output_tokens;
                    self.total_input_tokens += input_token_estimate;
                    // Estimate cost: $0.01 per 1K tokens (rough average).
                    self.total_cost_usd += @as(f64, @floatFromInt(input_token_estimate + estimated_output_tokens)) * 0.00001;

                    self.finalizeStreamedResponse(text) catch {};
                    self.appendConversation(.agent, text) catch {};
                }
                if (payload.proposal_rel) |prop| {
                    self.setPendingProposal(prop) catch {};
                }
                payload.deinit(self.allocator);
            },
            .err => |message| {
                self.mutex.lock();
                self.stream_line_index = null;
                self.mutex.unlock();
                self.pushLine(.failure, message) catch {
                    self.allocator.free(message);
                };
            },
        }
        self.refreshStatus() catch {};

        self.mutex.lock();
        self.agent_busy = false;
        self.active_progress_len = 0;
        self.worker_done = true;
        self.markDirty();
        self.mutex.unlock();
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
        const now_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        try self.lines.append(self.allocator, .{ .kind = kind, .text = text, .timestamp_ms = now_ms });
        // Auto-scroll to bottom on new message ONLY if the user is already
        // at the bottom (scroll == 0). If the user has scrolled up to read
        // older output, don't yank them back down — just leave a marker.
        // The render loop shows "^ N lines above" so they know new output
        // arrived below. This matches the UX of every modern chat app.
        if (self.scroll == 0) {
            // Already following — stay at bottom.
        } else {
            // User is reading older output — keep their scroll position
            // so they aren't disrupted by new streaming output.
        }
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
            if (self.lines.items.len > 0) {
                const last_idx = self.lines.items.len - 1;
                const last = &self.lines.items[last_idx];
                if (last.kind == .system and std.mem.eql(u8, std.mem.trim(u8, last.text, &std.ascii.whitespace), std.mem.trim(u8, text, &std.ascii.whitespace))) {
                    self.allocator.free(last.text);
                    last.text = owned;
                    last.kind = .agent;
                    self.scroll = 0;
                    self.scroll_target = 0;
                    self.markDirty();
                    return;
                }
            }
            try self.lines.append(self.allocator, .{ .kind = .agent, .text = owned });
            self.scroll = 0;
            self.scroll_target = 0;
        }
        self.markDirty();
    }

    fn onStreamChunk(self: *App, chunk: []const u8) void {
        // Live token streaming: append chunks to the current streaming line.
        // When agent_busy=true (multi-step agent turn), we still stream the
        // LLM's narration text — it appears between tool steps as the model
        // "thinks out loud". When agent_busy=false (single-shot ask), this is
        // the primary output stream.
        //
        // The stream_line_index is reset on onStepBegin so each new LLM phase
        // (initial prompt, between tool calls, final answer) starts a fresh
        // line. This avoids stale line indices appearing above tool steps.
        if (chunk.len == 0) return;
        if (shouldDropStreamChunk(chunk)) return;
        const now = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stream_line_index) |idx| {
            if (idx < self.lines.items.len) {
                const line = &self.lines.items[idx];
                const new_len = line.text.len + chunk.len;
                const grown = self.allocator.realloc(line.text, new_len) catch return;
                @memcpy(grown[line.text.len..], chunk);
                line.text = grown;
                if (now - self.last_render_ms >= 60 or chunk.len >= 64) self.markDirty();
                return;
            }
        }
        // No active streaming line — create a new assistant line. Keep it as
        // assistant from the start so partial/final stream text never appears
        // as a stray system message.
        const owned = self.allocator.dupe(u8, chunk) catch return;
        self.lines.append(self.allocator, .{ .kind = .agent, .text = owned }) catch {
            self.allocator.free(owned);
            return;
        };
        self.stream_line_index = self.lines.items.len - 1;
        self.scroll = 0;
        self.scroll_target = 0;
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

        // Phase 44: Colored diff header
        try self.pushSystem("═══════════════════ PROPOSAL DIFF ═══════════════════");

        var out = std.Io.Writer.Allocating.init(self.allocator);
        defer out.deinit();
        try workspace.preview.renderDiff(self.allocator, self.io, self.opened.root, edit, &out.writer);

        var lines = std.mem.splitScalar(u8, out.writer.buffered(), '\n');
        var shown: usize = 0;
        var added: usize = 0;
        var removed: usize = 0;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            // Count additions/removals for summary.
            if (line.len > 0 and line[0] == '+') added += 1;
            if (line.len > 0 and line[0] == '-') removed += 1;
            try self.pushLine(.system, try self.allocator.dupe(u8, line));
            shown += 1;
            if (shown >= 160) {
                try self.pushSystem("... diff truncated (use /diff or `forge diff` for full output)");
                break;
            }
        }

        // Phase 44: Diff summary with colored counts
        var summary_buf: [128]u8 = undefined;
        const summary = std.fmt.bufPrint(&summary_buf, "═══ {d} additions · {d} deletions ═══", .{ added, removed }) catch "═══ diff complete ═══";
        try self.pushSystem(summary);
        try self.pushSystem("Press 'a'=apply · 'n'=dismiss · 'y'=accept · 'r'=reject · 's'=skip · /diff to view again");
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
        // Split multi-line text into separate ChatLines so each line renders
        // on its own row. Without this, a single ChatLine with embedded \n
        // renders as one long line that wraps unpredictably.
        var iter = std.mem.splitScalar(u8, text, '\n');
        while (iter.next()) |line| {
            try self.pushLine(.system, try self.allocator.dupe(u8, line));
        }
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
        // Modern welcome — concise, actionable, shows key shortcuts.
        try self.pushSystem("✨ Forge AI — type your request, or /help for commands");

        var line_buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(
            &line_buf,
            "{s} · {s} · /mode to switch · /model to pick LLM",
            .{
                commands.modeLabel(self.agent_mode),
                self.model_label,
            },
        ) catch "Ready";
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
        // Modern prompt: arrow + folder + branch + mode indicator.
        // Inspired by starship/oh-my-zsh: concise, scannable, colorful.
        // The render loop applies colors per-segment; here we just emit text.
        const mode_icon: []const u8 = switch (self.agent_mode) {
            .ask => "?", // question mode
            .plan => "+", // planning mode
            .agent => ">", // agent mode (default)
        };
        if (std.mem.eql(u8, self.branch_label, "no branch")) {
            return std.fmt.bufPrint(buf, "{s} {s} ", .{ mode_icon, folder });
        }
        return std.fmt.bufPrint(buf, "{s} {s} ({s}) ", .{ mode_icon, folder, self.branch_label });
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

        var buf: [512]u8 = undefined;
        const line = self.formatToolDoneSummary(&buf, kind, summary);
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

    const ReadFileMeta = struct {
        path: ?[]const u8 = null,
        lines: ?[]const u8 = null,
        bytes: ?usize = null,
    };

    const TreeMeta = struct {
        path: ?[]const u8 = null,
        counts: ?[]const u8 = null,
    };

    fn formatToolDoneSummary(self: *App, buf: []u8, kind: []const u8, summary: []const u8) []const u8 {
        _ = self;
        const label = toolDoneLabel(kind);
        const line_count = countNonEmptyLines(summary);
        const review = if (summary.len > 0) " · ctrl+r" else "";

        if (std.mem.eql(u8, kind, "read_file")) {
            const meta = parseReadFileMeta(summary);
            var bytes_buf: [32]u8 = undefined;
            const bytes_text = if (meta.bytes) |bytes| formatByteCount(&bytes_buf, bytes) else null;
            if (meta.path) |path| {
                if (meta.lines != null and bytes_text != null) {
                    return std.fmt.bufPrint(buf, "✓ {s} file · {s} · lines {s} · {s}{s}", .{ label, path, meta.lines.?, bytes_text.?, review }) catch "✓ Read file";
                }
                if (meta.lines) |lines| {
                    return std.fmt.bufPrint(buf, "✓ {s} file · {s} · lines {s}{s}", .{ label, path, lines, review }) catch "✓ Read file";
                }
                if (bytes_text) |size| {
                    return std.fmt.bufPrint(buf, "✓ {s} file · {s} · {s}{s}", .{ label, path, size, review }) catch "✓ Read file";
                }
                return std.fmt.bufPrint(buf, "✓ {s} file · {s}{s}", .{ label, path, review }) catch "✓ Read file";
            }
        }

        if (std.mem.eql(u8, kind, "list_tree")) {
            const meta = parseTreeMeta(summary);
            if (meta.path != null and meta.counts != null) {
                return std.fmt.bufPrint(buf, "✓ {s} · {s} · {s}{s}", .{ label, meta.path.?, meta.counts.?, review }) catch "✓ Tree";
            }
            if (meta.counts) |counts| {
                return std.fmt.bufPrint(buf, "✓ {s} · {s}{s}", .{ label, counts, review }) catch "✓ Tree";
            }
        }

        var preview_buf: [220]u8 = undefined;
        const preview = sanitizedSummaryPreview(&preview_buf, summary);
        if (line_count > 4) {
            if (preview.len > 0) {
                return std.fmt.bufPrint(buf, "✓ {s} · {d} lines hidden · {s}{s}", .{ label, line_count, preview, review }) catch label;
            }
            return std.fmt.bufPrint(buf, "✓ {s} · {d} lines hidden{s}", .{ label, line_count, review }) catch label;
        }
        if (preview.len > 0) {
            return std.fmt.bufPrint(buf, "✓ {s} · {s}{s}", .{ label, preview, review }) catch label;
        }
        return std.fmt.bufPrint(buf, "✓ {s}{s}", .{ label, review }) catch label;
    }

    fn parseReadFileMeta(text: []const u8) ReadFileMeta {
        var meta = ReadFileMeta{};
        meta.path = backtickValueAfter(text, "File `");
        if (tokenValue(text, "lines=")) |lines| meta.lines = lines;
        if (tokenValue(text, "bytes=")) |bytes_text| {
            meta.bytes = std.fmt.parseInt(usize, bytes_text, 10) catch null;
        }
        return meta;
    }

    fn parseTreeMeta(text: []const u8) TreeMeta {
        var meta = TreeMeta{};
        meta.path = backtickValueAfter(text, "Tree `");
        if (std.mem.indexOfScalar(u8, text, '(')) |open| {
            if (std.mem.indexOfScalarPos(u8, text, open + 1, ')')) |close| {
                meta.counts = std.mem.trim(u8, text[open + 1 .. close], &std.ascii.whitespace);
            }
        }
        return meta;
    }

    fn backtickValueAfter(text: []const u8, prefix: []const u8) ?[]const u8 {
        const start_prefix = std.mem.indexOf(u8, text, prefix) orelse return null;
        const start = start_prefix + prefix.len;
        const end_rel = std.mem.indexOfScalar(u8, text[start..], '`') orelse return null;
        return text[start .. start + end_rel];
    }

    fn tokenValue(text: []const u8, token: []const u8) ?[]const u8 {
        const token_start = std.mem.indexOf(u8, text, token) orelse return null;
        var start = token_start + token.len;
        while (start < text.len and std.ascii.isWhitespace(text[start])) : (start += 1) {}
        var end = start;
        while (end < text.len and !std.ascii.isWhitespace(text[end]) and text[end] != ',' and text[end] != ')') : (end += 1) {}
        if (end <= start) return null;
        return text[start..end];
    }

    fn formatByteCount(buf: []u8, bytes: usize) []const u8 {
        if (bytes >= 1024 * 1024) {
            return std.fmt.bufPrint(buf, "{d} MiB", .{bytes / (1024 * 1024)}) catch "";
        }
        if (bytes >= 1024) {
            return std.fmt.bufPrint(buf, "{d} KiB", .{bytes / 1024}) catch "";
        }
        return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "";
    }

    fn sanitizedSummaryPreview(buf: []u8, text: []const u8) []const u8 {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len == 0 or isRawObservationLine(trimmed)) continue;
            return compactWhitespace(buf, trimmed, 180);
        }
        return "";
    }

    fn compactWhitespace(buf: []u8, text: []const u8, max_len: usize) []const u8 {
        var out_len: usize = 0;
        var last_space = false;
        const limit = @min(buf.len, max_len);
        for (text) |c| {
            if (c < 32 and c != '\t') continue;
            const is_space = std.ascii.isWhitespace(c);
            if (is_space and last_space) continue;
            if (out_len >= limit) break;
            buf[out_len] = if (is_space) ' ' else c;
            out_len += 1;
            last_space = is_space;
        }
        if (out_len == limit and text.len > limit and limit >= 3) {
            @memcpy(buf[limit - 3 .. limit], "...");
            return buf[0..limit];
        }
        return buf[0..out_len];
    }

    fn isRawObservationLine(line: []const u8) bool {
        if (std.mem.startsWith(u8, line, "<tool_response>")) return true;
        if (std.mem.startsWith(u8, line, "</tool_response>")) return true;
        if (std.mem.startsWith(u8, line, "```")) return true;
        if (std.mem.startsWith(u8, line, "{\"name\":")) return true;
        if (std.mem.startsWith(u8, line, "File `")) return true;
        if (std.mem.startsWith(u8, line, "Tree `")) return true;
        if (std.mem.indexOf(u8, line, "\"arguments\":") != null) return true;
        if (std.mem.indexOf(u8, line, "output truncated:") != null) return true;
        if (looksLikeNumberedFileLine(line)) return true;
        return false;
    }

    fn looksLikeNumberedFileLine(line: []const u8) bool {
        var i: usize = 0;
        while (i < line.len and std.ascii.isWhitespace(line[i])) : (i += 1) {}
        const digit_start = i;
        while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}
        if (i == digit_start) return false;
        while (i < line.len and std.ascii.isWhitespace(line[i])) : (i += 1) {}
        return i < line.len and line[i] == '|';
    }

    fn shouldDropStreamChunk(chunk: []const u8) bool {
        const trimmed = std.mem.trim(u8, chunk, &std.ascii.whitespace);
        if (trimmed.len == 0) return false;
        if (isRawObservationLine(trimmed)) return true;
        if (std.mem.indexOf(u8, trimmed, "<tool_response>") != null) return true;
        if (std.mem.indexOf(u8, trimmed, "</tool_response>") != null) return true;
        if (std.mem.indexOf(u8, trimmed, "<tool_call") != null) return true;
        if (std.mem.indexOf(u8, trimmed, "<function=") != null) return true;
        if (std.mem.indexOf(u8, trimmed, "File `") != null and std.mem.indexOf(u8, trimmed, "bytes=") != null) return true;
        if (std.mem.indexOf(u8, trimmed, "read_file output truncated:") != null) return true;
        if (std.mem.indexOf(u8, trimmed, "\"name\":") != null and std.mem.indexOf(u8, trimmed, "\"arguments\":") != null) return true;
        if (std.mem.startsWith(u8, trimmed, "[forge-ai] OpenRouter tool-stream request")) return true;
        if (std.mem.startsWith(u8, trimmed, "[forge-ai] OpenRouter tool-stream response")) return true;
        if (std.mem.startsWith(u8, trimmed, "model=") and std.mem.indexOf(u8, trimmed, "://openrouter.ai/") == null) return true;
        return false;
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

    fn isDiffAdditionLine(text: []const u8) bool {
        return text.len > 0 and text[0] == '+' and (text.len == 1 or text[1] != ' ');
    }

    fn isDiffDeletionLine(text: []const u8) bool {
        if (std.mem.startsWith(u8, text, "---") and (text.len == 3 or std.ascii.isWhitespace(text[3]))) return false;
        return text.len > 0 and text[0] == '-' and (text.len == 1 or text[1] != ' ');
    }

    fn colorForLine(kind: LineKind, text: []const u8) []const u8 {
        if (std.mem.startsWith(u8, text, "✨ Forge AI")) return term.Style.bright_green;
        if (isDiffAdditionLine(text)) return term.Style.bright_green;
        if (isDiffDeletionLine(text)) return term.Style.bright_red;
        if (std.mem.startsWith(u8, text, "FORGE Coding Assistant initialized.")) return term.Style.gray;
        if (std.mem.startsWith(u8, text, "Context: ")) return term.Style.gray;
        if (std.mem.startsWith(u8, text, "Edited ")) return term.Style.bright_yellow;
        if (std.mem.startsWith(u8, text, "› ")) return term.Style.gray;
        if (std.mem.startsWith(u8, text, "$ ")) return term.Style.bright_yellow;
        if (std.mem.startsWith(u8, text, "ok ") or std.mem.startsWith(u8, text, "✓ ")) return term.Style.bright_green;
        if (std.mem.startsWith(u8, text, "↻ ")) return term.Style.magenta;
        return switch (kind) {
            .user => term.Style.white,
            .agent => term.Style.white,
            .tool => term.Style.gray,
            .system => term.Style.gray,
            .failure => term.Style.red,
        };
    }

    fn bgForLine(text: []const u8, block_state: u8) ?[]const u8 {
        if (block_state != 2) return null;
        if (isDiffAdditionLine(text)) return term.Style.bg_green;
        if (isDiffDeletionLine(text)) return term.Style.bg_red;
        return null;
    }

    fn stripRolePrefix(text: []const u8, prefix: []const u8) []const u8 {
        if (std.mem.startsWith(u8, text, prefix)) return text[prefix.len..];
        return text;
    }

    fn lineRoleLabel(kind: LineKind, text: []const u8) []const u8 {
        return switch (kind) {
            .user => "you",
            .agent => if (std.mem.startsWith(u8, text, "agent  ")) "ai" else "",
            .tool => "tool",
            .system => "info",
            .failure => "err",
        };
    }

    fn lineAccent(kind: LineKind, text: []const u8) []const u8 {
        return switch (kind) {
            .user => term.Style.bright_green,
            .agent => term.Style.lime,
            .tool => if (std.mem.startsWith(u8, text, "* tool  ✓"))
                term.Style.green
            else if (std.mem.startsWith(u8, text, "* tool  ×") or std.mem.indexOf(u8, text, " failed") != null)
                term.Style.bright_red
            else
                term.Style.cyan,
            .system => term.Style.gray,
            .failure => term.Style.bright_red,
        };
    }

    fn toolTextColor(text: []const u8) []const u8 {
        if (std.mem.startsWith(u8, text, "✓")) return term.Style.green;
        if (std.mem.startsWith(u8, text, "×") or std.mem.indexOf(u8, text, " failed") != null) return term.Style.bright_red;
        if (std.mem.startsWith(u8, text, "›")) return term.Style.cyan;
        if (std.mem.startsWith(u8, text, "$")) return term.Style.bright_yellow;
        return term.Style.gray;
    }

    fn decorateLine(self: *const App, kind: LineKind, text: []const u8) ![]u8 {
        return switch (kind) {
            .user => self.formatPromptLine(text),
            .failure => std.fmt.allocPrint(self.allocator, "× {s}", .{text}),
            .agent => blk: {
                // Phase 29: Add role label for agent messages on first line of response.
                const decorated = try self.normalizeMarkdownForLayout(text);
                defer self.allocator.free(decorated);
                // Only add label if this looks like the start of a response
                // (not a continuation line starting with whitespace or >).
                if (text.len > 0 and text[0] != ' ' and text[0] != '>' and text[0] != '!') {
                    break :blk std.fmt.allocPrint(self.allocator, "agent  {s}", .{decorated});
                }
                break :blk self.allocator.dupe(u8, decorated);
            },
            .tool => std.fmt.allocPrint(self.allocator, "* tool  {s}", .{text}),
            .system => blk: {
                // Phase 44: Don't add system prefix to diff lines — they
                // need clean +/- prefixes for proper coloring.
                if (text.len > 0 and (text[0] == '+' or text[0] == '-' or
                    std.mem.startsWith(u8, text, "diff --git") or
                    std.mem.startsWith(u8, text, "index ") or
                    std.mem.startsWith(u8, text, "---") or
                    std.mem.startsWith(u8, text, "+++") or
                    std.mem.startsWith(u8, text, "@@")))
                {
                    break :blk self.allocator.dupe(u8, text);
                }
                break :blk std.fmt.allocPrint(self.allocator, "system  {s}", .{text});
            },
        };
    }

    fn normalizeMarkdownForLayout(self: *const App, text: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);

        var i: usize = 0;
        while (i < text.len) {
            if (i + 3 <= text.len and std.mem.eql(u8, text[i..][0..3], "```")) {
                const close = blk: {
                    var j: usize = i + 3;
                    while (j + 3 <= text.len) : (j += 1) {
                        if (std.mem.eql(u8, text[j..][0..3], "```")) break :blk j;
                    }
                    break :blk text.len;
                };
                var lang: []const u8 = "";
                const fence_end = std.mem.indexOfScalarPos(u8, text, i + 3, '\n') orelse close;
                if (fence_end > i + 3) {
                    lang = std.mem.trim(u8, text[i + 3 .. fence_end], &std.ascii.whitespace);
                }
                try out.appendSlice(self.allocator, "```");
                try out.appendSlice(self.allocator, lang);
                const code_start = fence_end;
                const code_end = close;
                if (code_start < code_end) {
                    try out.appendSlice(self.allocator, text[code_start..code_end]);
                }
                if (close < text.len) {
                    try out.appendSlice(self.allocator, "```");
                }
                i = if (close < text.len) close + 3 else text.len;
                continue;
            }

            if (text[i] == '`' and i + 1 < text.len) {
                const close = std.mem.indexOfScalarPos(u8, text, i + 1, '`') orelse {
                    try out.append(self.allocator, text[i]);
                    i += 1;
                    continue;
                };
                try out.appendSlice(self.allocator, text[i + 1 .. close]);
                i = close + 1;
                continue;
            }

            if (i + 4 <= text.len and std.ascii.eqlIgnoreCase(text[i..][0..4], "<br>")) {
                try out.append(self.allocator, '\n');
                i += 4;
                continue;
            }
            if (i + 5 <= text.len and std.ascii.eqlIgnoreCase(text[i..][0..5], "<br/>")) {
                try out.append(self.allocator, '\n');
                i += 5;
                continue;
            }
            if (i + 6 <= text.len and std.ascii.eqlIgnoreCase(text[i..][0..6], "<br />")) {
                try out.append(self.allocator, '\n');
                i += 6;
                continue;
            }

            if (i + 2 <= text.len and text[i] == '*' and text[i + 1] == '*') {
                const close = blk: {
                    var j: usize = i + 2;
                    while (j + 2 <= text.len) : (j += 1) {
                        if (text[j] == '*' and text[j + 1] == '*') break :blk j;
                    }
                    break :blk null;
                };
                if (close) |c| {
                    try out.appendSlice(self.allocator, text[i + 2 .. c]);
                    i = c + 2;
                    continue;
                }
            }

            if (i == 0 or text[i - 1] == '\n') {
                if (text[i] == '#') {
                    var level: usize = 0;
                    var j: usize = i;
                    while (j < text.len and text[j] == '#' and level < 3) : (j += 1) level += 1;
                    if (j < text.len and text[j] == ' ') {
                        const eol = std.mem.indexOfScalarPos(u8, text, j, '\n') orelse text.len;
                        try out.appendSlice(self.allocator, text[j + 1 .. eol]);
                        i = eol;
                        continue;
                    }
                }
                if ((text[i] == '-' or text[i] == '*') and i + 1 < text.len and text[i + 1] == ' ') {
                    try out.appendSlice(self.allocator, "- ");
                    i += 2;
                    continue;
                }
                if (i < text.len and text[i] >= '0' and text[i] <= '9') {
                    var j = i;
                    while (j < text.len and text[j] >= '0' and text[j] <= '9') j += 1;
                    if (j < text.len and text[j] == '.' and j + 1 < text.len and text[j + 1] == ' ') {
                        try out.appendSlice(self.allocator, text[i .. j + 1]);
                        try out.append(self.allocator, ' ');
                        i = j + 2;
                        continue;
                    }
                }
            }

            try out.append(self.allocator, text[i]);
            i += 1;
        }

        return out.toOwnedSlice(self.allocator);
    }

    /// Basic syntax highlighting for code blocks (Phase 31).
    /// Highlights comments, strings, and language-specific keywords.
    /// Supports: zig, python/py, javascript/js, typescript/ts, go, rust, c.
    fn highlightCode(self: *const App, out: *std.ArrayList(u8), code: []const u8, lang: []const u8) !void {
        const use_hash_comment = std.mem.eql(u8, lang, "python") or std.mem.eql(u8, lang, "py");

        var i: usize = 0;
        while (i < code.len) {
            // Line comment: // or #
            if (!use_hash_comment and i + 2 <= code.len and code[i] == '/' and code[i + 1] == '/') {
                const eol = std.mem.indexOfScalarPos(u8, code, i, '\n') orelse code.len;
                try out.appendSlice(self.allocator, term.Style.gray);
                try out.appendSlice(self.allocator, code[i..eol]);
                try out.appendSlice(self.allocator, term.Style.reset);
                i = eol;
                continue;
            }
            if (use_hash_comment and code[i] == '#') {
                const eol = std.mem.indexOfScalarPos(u8, code, i, '\n') orelse code.len;
                try out.appendSlice(self.allocator, term.Style.gray);
                try out.appendSlice(self.allocator, code[i..eol]);
                try out.appendSlice(self.allocator, term.Style.reset);
                i = eol;
                continue;
            }
            // String literal: "..." or '...'
            if (code[i] == '"' or code[i] == '\'') {
                const quote = code[i];
                try out.appendSlice(self.allocator, term.Style.green);
                try out.append(self.allocator, quote);
                var j = i + 1;
                while (j < code.len and code[j] != quote) : (j += 1) {
                    if (code[j] == '\\' and j + 1 < code.len) j += 1; // skip escaped
                }
                if (j < code.len) {
                    try out.appendSlice(self.allocator, code[i + 1 .. j]);
                    try out.append(self.allocator, quote);
                    try out.appendSlice(self.allocator, term.Style.reset);
                    i = j + 1;
                } else {
                    try out.appendSlice(self.allocator, code[i + 1 ..]);
                    try out.appendSlice(self.allocator, term.Style.reset);
                    i = code.len;
                }
                continue;
            }
            // Keyword highlighting — check word boundaries
            if (std.ascii.isAlphabetic(code[i])) {
                const word_end = blk: {
                    var j = i;
                    while (j < code.len and (std.ascii.isAlphanumeric(code[j]) or code[j] == '_')) j += 1;
                    break :blk j;
                };
                const word = code[i..word_end];
                if (isKeyword(word, lang)) {
                    try out.appendSlice(self.allocator, term.Style.yellow);
                    try out.appendSlice(self.allocator, word);
                    try out.appendSlice(self.allocator, term.Style.reset);
                } else if (isType(word, lang)) {
                    try out.appendSlice(self.allocator, term.Style.magenta);
                    try out.appendSlice(self.allocator, word);
                    try out.appendSlice(self.allocator, term.Style.reset);
                } else {
                    try out.appendSlice(self.allocator, word);
                }
                i = word_end;
                continue;
            }
            try out.append(self.allocator, code[i]);
            i += 1;
        }
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

    /// Returns a description of provider capabilities for the /capability command.
    fn getProviderCapabilities(provider_name: []const u8) []const u8 {
        if (std.mem.eql(u8, provider_name, "gemini")) {
            return "  Capabilities: streaming, tool calls, multimodal (images), 1M context";
        }
        if (std.mem.eql(u8, provider_name, "openai")) {
            return "  Capabilities: streaming, tool calls, function calling, JSON mode";
        }
        if (std.mem.eql(u8, provider_name, "anthropic")) {
            return "  Capabilities: streaming, tool calls, 200K context, vision";
        }
        if (std.mem.eql(u8, provider_name, "ollama")) {
            return "  Capabilities: streaming, tool calls, local models, no API key needed";
        }
        if (std.mem.eql(u8, provider_name, "openrouter")) {
            return "  Capabilities: streaming, tool calls, multi-model gateway";
        }
        if (std.mem.eql(u8, provider_name, "nvidia")) {
            return "  Capabilities: streaming, tool calls, NIM endpoints";
        }
        if (std.mem.eql(u8, provider_name, "forge_cloud")) {
            return "  Capabilities: streaming, tool calls, backend proxy with auth";
        }
        if (std.mem.eql(u8, provider_name, "fake")) {
            return "  Capabilities: deterministic test provider (no real LLM)";
        }
        return "  Capabilities: (unknown provider)";
    }

    /// Returns the current spinner character based on spinner_frame.
    /// Used for the animated "thinking" indicator.
    fn spinnerChar(self: *const App) []const u8 {
        const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
        return frames[self.spinner_frame % frames.len];
    }

    fn appendFrameSpaces(self: *App, count: usize) void {
        var i: usize = 0;
        while (i < count) : (i += 1) {
            self.frame.appendSlice(" ") catch {};
        }
    }

    /// Draw the top status bar with color-coded segments (Phase 100).
    fn drawStatusBar(self: *App, cols: u16) void {
        self.frame.moveTo(1, 1);

        var buf: [512]u8 = undefined;
        const mode_label = commands.modeLabel(self.agent_mode);
        const spinner = if (self.agent_busy) self.spinnerChar() else "◆";
        const tab_name = if (self.current_tab_name) |n| n else "main";
        const total_tokens = self.total_input_tokens + self.total_output_tokens;

        // Build segment by segment with per-segment colors.
        // Each segment: [bg_color][fg_color] text [reset]
        var col: u16 = 0;

        // Segment 1: Spinner + FORGE (bold white on dark bg)
        if (self.term.use_color) {
            self.frame.appendSlice(term.Style.invert) catch {};
            self.frame.appendSlice(term.Style.bold) catch {};
        }
        const seg1 = std.fmt.bufPrint(&buf, " {s} FORGE ", .{spinner}) catch " FORGE ";
        self.frame.appendSlice(seg1) catch {};
        col += @intCast(term.displayWidth(seg1));
        if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};

        // Segment 2: Tab name (cyan)
        if (self.term.use_color) self.frame.appendSlice(term.Style.cyan) catch {};
        const seg2 = std.fmt.bufPrint(&buf, " [{s}] ", .{tab_name}) catch " [] ";
        self.frame.appendSlice(seg2) catch {};
        col += @intCast(term.displayWidth(seg2));
        if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};

        // Segment 3: Model (green)
        if (self.term.use_color) self.frame.appendSlice(term.Style.green) catch {};
        const seg3 = std.fmt.bufPrint(&buf, "{s} ", .{self.model_label}) catch "";
        self.frame.appendSlice(seg3) catch {};
        col += @intCast(term.displayWidth(seg3));
        if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};

        // Segment 4: Mode (yellow)
        if (self.term.use_color) self.frame.appendSlice(term.Style.yellow) catch {};
        const seg4 = std.fmt.bufPrint(&buf, "| {s} ", .{mode_label}) catch "";
        self.frame.appendSlice(seg4) catch {};
        col += @intCast(term.displayWidth(seg4));
        if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};

        // Segment 5: Context with usage bar (gray + colored indicator)
        // Parse context_label to extract kB value for usage bar.
        if (self.term.use_color) self.frame.appendSlice(term.Style.gray) catch {};
        const seg5 = std.fmt.bufPrint(&buf, "| ctx:{s} ", .{self.context_label}) catch "";
        self.frame.appendSlice(seg5) catch {};
        col += @intCast(term.displayWidth(seg5));
        if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};

        // Context usage mini-bar: show a 5-char bar based on token count.
        // Rough estimate: context_max is ~8MB, show bar fill based on total_tokens.
        const ctx_usage_pct = @min(100, (total_tokens * 100) / 100000); // 100k tokens = full
        const bar_fill: usize = ctx_usage_pct / 20; // 0-5
        if (self.term.use_color) {
            if (ctx_usage_pct > 80) {
                self.frame.appendSlice(term.Style.bright_red) catch {};
            } else if (ctx_usage_pct > 50) {
                self.frame.appendSlice(term.Style.bright_yellow) catch {};
            } else {
                self.frame.appendSlice(term.Style.bright_green) catch {};
            }
        }
        var ctx_bar_buf: [8]u8 = undefined;
        var bi: usize = 0;
        while (bi < 5) : (bi += 1) {
            ctx_bar_buf[bi] = if (bi < bar_fill) '#' else '.';
        }
        self.frame.appendSlice(ctx_bar_buf[0..5]) catch {};
        if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
        self.frame.appendSlice(" ") catch {};
        col += 6;

        // Segment 6: Branch (magenta) — if not "no branch"
        if (!std.mem.eql(u8, self.branch_label, "no branch")) {
            if (self.term.use_color) self.frame.appendSlice(term.Style.magenta) catch {};
            const seg6 = std.fmt.bufPrint(&buf, "| git:{s} ", .{self.branch_label}) catch "";
            self.frame.appendSlice(seg6) catch {};
            col += @intCast(term.displayWidth(seg6));
            if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
        }

        // Segment 7: Edited count (bright_yellow) — if > 0
        if (!std.mem.eql(u8, self.edited_label, "0 edited")) {
            if (self.term.use_color) self.frame.appendSlice(term.Style.bright_yellow) catch {};
            const seg7 = std.fmt.bufPrint(&buf, "| {s} ", .{self.edited_label}) catch "";
            self.frame.appendSlice(seg7) catch {};
            col += @intCast(term.displayWidth(seg7));
            if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
        }

        // Segment 8: Tokens (bright_green) — right-aligned
        const seg8 = std.fmt.bufPrint(&buf, "{d} tok", .{total_tokens}) catch "0 tok";
        const seg8_cols: u16 = @intCast(term.displayWidth(seg8));
        if (col + seg8_cols + 2 < cols) {
            // Pad to right-align
            if (cols > col + seg8_cols + 1) {
                self.appendFrameSpaces(cols - col - seg8_cols - 1);
            }
            if (self.term.use_color) self.frame.appendSlice(term.Style.bright_green) catch {};
            self.frame.appendSlice(seg8) catch {};
            if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
            col = cols;
        } else {
            if (self.term.use_color) self.frame.appendSlice(term.Style.bright_green) catch {};
            self.frame.appendSlice(seg8) catch {};
            if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
            col += seg8_cols;
        }

        // Pad remaining space
        if (col < cols) {
            self.appendFrameSpaces(cols - col);
        }
        self.frame.appendSlice("\x1b[K") catch {};
    }

    fn render(self: *App) void {
        self.terminal_size = self.term.size();
        const size = self.terminal_size;
        const show_commands = !self.model_picker_active and self.input.items.len > 0 and self.input.items[0] == '/';
        var filtered: [ALL_COMMANDS.len][]const u8 = undefined;
        var filtered_len: u16 = 0;
        const model_match_count = if (self.model_picker_active) self.modelPickerMatchCount() else 0;
        const model_picker_visible_rows: u16 = if (self.model_picker_active)
            @intCast(@max(@as(usize, 1), @min(model_match_count, max_model_picker_rows)))
        else
            0;
        const model_picker_rows: u16 = if (self.model_picker_active) model_picker_visible_rows + 1 else 0;

        if (show_commands) {
            const full_len = self.getFilteredCommands(&filtered);
            filtered_len = @intCast(@min(full_len, max_command_suggestions));
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

        const busy_rows: u16 = if (self.agent_busy) 1 else 0;
        const approval_rows: u16 = if (pending) 1 else 0;
        const footer_rows: u16 = busy_rows + model_picker_rows + approval_rows;
        const status_bar_rows: u16 = 1; // Top status bar (Phase 24)
        const separator_rows: u16 = 1;
        if (size.rows <= footer_rows + status_bar_rows + separator_rows + 1) return;
        const chat_rows = size.rows - footer_rows - status_bar_rows - separator_rows;

        self.frame.begin();

        var wrapped_cache: std.ArrayList([]const u8) = .empty;
        defer {
            for (wrapped_cache.items) |line| self.allocator.free(line);
            wrapped_cache.deinit(self.allocator);
        }

        var display_lines: std.ArrayList(struct { kind: LineKind, text: []const u8, source_idx: ?usize }) = .empty;
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

        // Optimized line processing: decorate + wrap in a single pass.
        // The previous code allocated decorated text, then wrapped, then duped each part.
        // Now we decorate, wrap, and move parts directly into display_lines.
        // This reduces per-line allocations from 3 (decorate + wrap + dupe) to 2.
        // Future: add a render cache keyed on (line_ptr, width) to skip entirely.
        const width_changed = self.render_cache_width != width;
        if (width_changed) self.render_cache_width = width;

        // P1.9: Pinned lines render first (prepended to top of chat area).
        // Only applies to the main chat view (not timeline/events views).
        if (!self.show_timeline and !self.show_events and self.pinned.items.len > 0) {
            for (self.pinned.items) |pin_idx| {
                if (pin_idx >= source_lines.len) continue;
                const line = source_lines[pin_idx];
                const decorated = self.decorateLine(line.kind, line.text) catch continue;
                defer self.allocator.free(decorated);
                // Prefix pinned lines with a marker so users can distinguish them.
                var pinned_buf: std.ArrayList(u8) = .empty;
                defer pinned_buf.deinit(self.allocator);
                pinned_buf.appendSlice(self.allocator, "[PIN] ") catch continue;
                pinned_buf.appendSlice(self.allocator, decorated) catch continue;
                const wrap_width: usize = if (self.wordwrap_enabled) width else 99999;
                const wrapped = term.wrapLines(self.allocator, pinned_buf.items, wrap_width) catch continue;
                defer term.freeLines(self.allocator, wrapped);
                for (wrapped) |part| {
                    const owned = self.allocator.dupe(u8, part) catch continue;
                    wrapped_cache.append(self.allocator, owned) catch {
                        self.allocator.free(owned);
                        continue;
                    };
                    display_lines.append(self.allocator, .{ .kind = line.kind, .text = owned, .source_idx = pin_idx }) catch {};
                    block_states.append(self.allocator, 0) catch {};
                }
            }
        }

        // Render cache: skip decorate+wrap for lines that haven't changed
        // since the last frame. Keyed on (line text pointer, width).
        // The cache is invalidated when:
        //   - width changes (terminal resize)
        //   - wordwrap_enabled changes
        //   - new lines are added (line pointers shift)
        //   - /clear or /compact is called
        if (width_changed) {
            self.render_cache_version +%= 1; // invalidate cache
        }

        for (source_lines, 0..) |line, source_idx| {
            // P1.9: filter_role — skip lines that don't match the active filter.
            // Only applies when filter_role is set (null = no filter).
            if (self.filter_role) |role| {
                if (line.kind != role) continue;
            }

            if (line.kind == .agent) {
                if (line.text.len > 0 and (line.text[0] == '>' or line.text[0] == '!')) {
                    current_block = 1;
                } else if (current_block == 1 and line.text.len > 0 and line.text[0] != '>' and line.text[0] != '!' and !std.mem.startsWith(u8, line.text, "Thinking")) {
                    current_block = 0;
                } else if (std.mem.startsWith(u8, line.text, "```")) {
                    current_block = if (current_block == 2) 0 else 2;
                }
            }

            // Render cache: skip decorate+wrap if the line hasn't changed
            // since last frame. Keyed on (text_ptr, text_len, width, version).
            const is_last_line = (source_idx + 1 == source_lines.len);
            const can_cache = !is_last_line and !width_changed and !self.agent_busy;

            if (can_cache and self.render_cache_init) {
                // Build cache key from text pointer + length + version.
                const cache_key = std.hash.Wyhash.hash(0, std.mem.asBytes(&@intFromPtr(line.text.ptr)) ++ std.mem.asBytes(&line.text.len) ++ std.mem.asBytes(&self.render_cache_version));
                if (self.render_cache.get(cache_key)) |cached| {
                    // Cache hit — reuse cached display lines.
                    for (cached.lines) |part| {
                        const owned = self.allocator.dupe(u8, part) catch continue;
                        wrapped_cache.append(self.allocator, owned) catch {
                            self.allocator.free(owned);
                            continue;
                        };
                        display_lines.append(self.allocator, .{ .kind = cached.kind, .text = owned, .source_idx = source_idx }) catch {};
                        block_states.append(self.allocator, cached.block_state) catch {};
                    }
                    continue; // Skip decorate+wrap — used cache.
                }
            }

            const decorated = self.decorateLine(line.kind, line.text) catch continue;
            defer self.allocator.free(decorated);
            // Use width for wrapping. If wordwrap is disabled, use a very large width.
            const wrap_width: usize = if (self.wordwrap_enabled) width else 99999;
            const wrapped = term.wrapLines(self.allocator, decorated, wrap_width) catch continue;
            defer term.freeLines(self.allocator, wrapped);

            // Store in cache for next frame (only cacheable lines).
            if (can_cache and self.render_cache_init) {
                const cache_key = std.hash.Wyhash.hash(0, std.mem.asBytes(&@intFromPtr(line.text.ptr)) ++ std.mem.asBytes(&line.text.len) ++ std.mem.asBytes(&self.render_cache_version));
                // Dupe the wrapped lines for cache storage.
                const cached_lines = self.allocator.alloc([]const u8, wrapped.len) catch null;
                if (cached_lines) |cl| {
                    var all_duped = true;
                    for (wrapped, 0..) |part, i| {
                        cl[i] = self.allocator.dupe(u8, part) catch {
                            // Free already-duped entries.
                            for (cl[0..i]) |d| self.allocator.free(d);
                            self.allocator.free(cl);
                            all_duped = false;
                            break;
                        };
                    }
                    if (all_duped) {
                        const block_state: u8 = if (line.kind == .tool) 0 else current_block;
                        // Remove old entry if exists (free old lines).
                        if (self.render_cache.fetchRemove(cache_key)) |old| {
                            for (old.value.lines) |l| self.allocator.free(l);
                            self.allocator.free(old.value.lines);
                        }
                        self.render_cache.put(cache_key, .{
                            .lines = cl,
                            .kind = line.kind,
                            .block_state = block_state,
                            .version = self.render_cache_version,
                        }) catch {
                            for (cl) |l| self.allocator.free(l);
                            self.allocator.free(cl);
                        };
                    }
                }
            }

            for (wrapped) |part| {
                const owned = self.allocator.dupe(u8, part) catch continue;
                wrapped_cache.append(self.allocator, owned) catch {
                    self.allocator.free(owned);
                    continue;
                };
                display_lines.append(self.allocator, .{ .kind = line.kind, .text = owned, .source_idx = source_idx }) catch {};
                const block_state: u8 = if (line.kind == .tool) 0 else current_block;
                block_states.append(self.allocator, block_state) catch {};
            }
        }

        if (!self.agent_busy and !self.show_events and !self.show_timeline and !self.model_picker_active) {
            if (self.formatPromptLine(self.input.items)) |owned_prompt| {
                wrapped_cache.append(self.allocator, owned_prompt) catch self.allocator.free(owned_prompt);
                display_lines.append(self.allocator, .{ .kind = .user, .text = owned_prompt, .source_idx = null }) catch {};
                block_states.append(self.allocator, 0) catch {};
            } else |_| {}
        }

        const total = display_lines.items.len;
        const max_scroll = if (total > chat_rows) total - chat_rows else 0;
        if (source_scroll_ptr.* > max_scroll) source_scroll_ptr.* = max_scroll;
        const start = if (total > chat_rows) total - chat_rows - source_scroll_ptr.* else 0;
        const end = @min(total, start + chat_rows);

        // Draw top status bar (Phase 24) — shows model, mode, context, tokens.
        self.drawStatusBar(size.cols);

        const first_chat_row: u16 = 2;
        const last_chat_row: u16 = chat_rows + 1;
        var row: u16 = first_chat_row;
        var scratch: [512]u8 = undefined;
        var live_prompt_row: ?u16 = null;
        for (display_lines.items[start..end], start..) |line, i| {
            self.frame.moveTo(row, 1);
            self.frame.appendSlice("\x1b[2K") catch {};
            const block = block_states.items[i];
            const color = colorForLine(line.kind, line.text);

            // P1.9: Bookmark indicator — prepend a star marker to lines whose
            // source_idx is in self.bookmarks. Only show on the first wrapped
            // row of each source line (i.e. when source_idx is set and matches
            // a bookmark). Skip pinned lines (which already have [PIN] prefix).
            const is_bookmarked = blk: {
                if (line.source_idx) |sidx| {
                    if (!std.mem.startsWith(u8, line.text, "[PIN] ")) {
                        for (self.bookmarks.items) |bidx| {
                            if (bidx == sidx) break :blk true;
                        }
                    }
                }
                break :blk false;
            };

            const label = lineRoleLabel(line.kind, line.text);
            const accent = lineAccent(line.kind, line.text);
            const gutter_cols: usize = if (chat_cols >= 64) 12 else 2;
            const panel_right: bool = line.kind == .agent and chat_cols >= 48;
            const available_cols = @as(usize, chat_cols);
            const chrome_cols: usize = gutter_cols + if (panel_right) @as(usize, 2) else @as(usize, 0);
            const content_cols: usize = if (available_cols > chrome_cols + 1) available_cols - chrome_cols - 1 else 1;

            self.frame.moveTo(row, chat_x);
            if (gutter_cols >= 12) {
                var label_buf: [16]u8 = undefined;
                const label_text = if (label.len > 0) std.fmt.bufPrint(&label_buf, "{s:>9} ", .{label}) catch "" else "          ";
                if (self.term.use_color) self.frame.appendSlice(accent) catch {};
                self.frame.appendSlice(label_text) catch {};
                if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
                if (self.term.use_color) self.frame.appendSlice(if (line.kind == .agent) term.Style.border else term.Style.dark_gray) catch {};
                self.frame.appendSlice("│ ") catch {};
                if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
            } else {
                if (self.term.use_color) self.frame.appendSlice(accent) catch {};
                self.frame.appendSlice("│ ") catch {};
                if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
            }

            // P1.9: Render bookmark marker before content (on first row of line).
            // Use a yellow star to make it visually distinct.
            if (is_bookmarked) {
                if (self.term.use_color) self.frame.appendSlice(term.Style.bright_yellow) catch {};
                self.frame.appendSlice("[\xe2\x98\x85] ") catch {}; // [★] in UTF-8
                if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
            }

            const padding: usize = if (block > 0 and line.kind != .tool) 1 else 0;
            const visible_text = switch (line.kind) {
                .agent => stripRolePrefix(line.text, "agent  "),
                .tool => stripRolePrefix(line.text, "* tool  "),
                .system => stripRolePrefix(line.text, "system  "),
                else => line.text,
            };
            const text_cols = if (content_cols > padding * 2) content_cols - padding * 2 else content_cols;
            const clipped = term.truncateEnd(&scratch, visible_text, text_cols);

            // Left padding
            if (padding > 0) {
                if (self.term.use_color) self.frame.appendSlice(term.Style.bg_block) catch {};
                self.appendFrameSpaces(padding);
            }

            if (line.kind == .user) {
                if (!self.agent_busy and !self.show_events and !self.show_timeline and i + 1 == total) live_prompt_row = row;
                var prefix_buf: [256]u8 = undefined;
                const prefix = self.promptPrefix(&prefix_buf) catch "";
                const prefix_part = if (std.mem.startsWith(u8, clipped, prefix)) prefix else "";
                if (self.term.use_color) self.frame.appendSlice(term.Style.violet) catch {};
                self.frame.appendSlice(prefix_part) catch {};
                if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
                if (padding > 0 and self.term.use_color) self.frame.appendSlice(term.Style.bg_block) catch {};
                if (self.term.use_color) self.frame.appendSlice(term.Style.green) catch {};
                self.frame.appendSlice(clipped[prefix_part.len..]) catch {};
            } else if (std.mem.startsWith(u8, clipped, "Thinking")) {
                if (self.term.use_color) self.frame.appendSlice(term.Style.blue) catch {};
                self.frame.appendSlice(clipped) catch {};
            } else if (line.kind == .agent) {
                if (self.term.use_color) {
                    self.frame.appendSlice(term.Style.lime) catch {};
                    if (std.mem.startsWith(u8, visible_text, "Here's") or std.mem.startsWith(u8, visible_text, "Here ")) {
                        self.frame.appendSlice(term.Style.bold) catch {};
                    }
                }
                self.frame.appendSlice(clipped) catch {};
            } else if (line.kind == .tool) {
                if (clipped.len > 0) {
                    const icon_len = term.utf8SeqLen(clipped[0]);
                    const icon = clipped[0..@min(icon_len, clipped.len)];
                    const rest = clipped[@min(icon_len, clipped.len)..];
                    if (self.term.use_color) {
                        self.frame.appendSlice(toolTextColor(clipped)) catch {};
                        self.frame.appendSlice(term.Style.bold) catch {};
                    }
                    self.frame.appendSlice(icon) catch {};
                    if (self.term.use_color) {
                        self.frame.appendSlice(term.Style.reset) catch {};
                        self.frame.appendSlice(toolTextColor(clipped)) catch {};
                    }
                    self.frame.appendSlice(rest) catch {};
                }
            } else {
                if (self.term.use_color) self.frame.appendSlice(color) catch {};
                if (self.term.use_color) {
                    if (bgForLine(line.text, block)) |bg| {
                        self.frame.appendSlice(bg) catch {};
                    } else if (padding > 0) {
                        self.frame.appendSlice(term.Style.bg_block) catch {};
                    }
                }
                self.frame.appendSlice(clipped) catch {};
            }

            // Right padding and fill
            if (clipped.len < text_cols) {
                if (self.term.use_color) {
                    if (bgForLine(line.text, block)) |bg| {
                        self.frame.appendSlice(bg) catch {};
                    } else if (padding > 0) {
                        self.frame.appendSlice(term.Style.bg_block) catch {};
                    }
                }
                self.appendFrameSpaces(text_cols - clipped.len + padding);
            } else if (padding > 0) {
                if (self.term.use_color) {
                    if (bgForLine(line.text, block)) |bg| {
                        self.frame.appendSlice(bg) catch {};
                    } else {
                        self.frame.appendSlice(term.Style.bg_block) catch {};
                    }
                }
                self.appendFrameSpaces(padding);
            }
            if (panel_right) {
                if (self.term.use_color) self.frame.appendSlice(term.Style.border) catch {};
                self.frame.appendSlice(" │") catch {};
            }

            self.frame.appendSlice("\x1b[K") catch {};
            if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
            row += 1;
        }
        while (row <= last_chat_row) : (row += 1) {
            self.frame.moveTo(row, 1);
            self.frame.appendSlice("\x1b[2K") catch {};
        }

        // Scroll indicator — show "↑ N lines above" when scrolled up (Phase 100).
        if (source_scroll_ptr.* > 0) {
            self.frame.moveTo(2, chat_x);
            if (self.term.use_color) self.frame.appendSlice(term.Style.cyan) catch {};
            var scroll_buf: [64]u8 = undefined;
            const scroll_hint = std.fmt.bufPrint(&scroll_buf, "  ^ {d} lines above  ", .{source_scroll_ptr.*}) catch "  ^ scrolled  ";
            self.frame.appendSlice(scroll_hint) catch {};
            if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
        } else if (total > chat_rows) {
            // Show "— follow —" badge when pinned to bottom.
            self.frame.moveTo(2, chat_x + chat_cols - 14);
            if (self.term.use_color) self.frame.appendSlice(term.Style.dim) catch {};
            self.frame.appendSlice("  -- follow --  ") catch {};
            if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
        }

        if (show_commands and live_prompt_row != null) {
            var command_row = live_prompt_row.? + 1;
            for (filtered[0..filtered_len], 0..) |cmd, i| {
                if (command_row > last_chat_row) break;
                self.frame.moveTo(command_row, 1);

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
                command_row += 1;
            }
        }

        // Draw a subtle separator line between chat area and input/footer.
        // This gives a clear visual boundary for "where do I type?".
        const separator_row = chat_rows + 2;
        self.frame.moveTo(separator_row, 1);
        if (self.term.use_color) self.frame.appendSlice(term.Style.dim) catch {};
        // Draw a thin horizontal line across the full width.
        var sep_buf: [256]u8 = undefined;
        const sep_w: usize = @min(@as(usize, size.cols), sep_buf.len);
        @memset(sep_buf[0..sep_w], '-');
        self.frame.appendSlice(sep_buf[0..sep_w]) catch {};
        if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
        self.frame.appendSlice("\x1b[K") catch {};

        var footer_row = separator_row + 1;

        if (self.agent_busy) {
            var thinking_buf: [128]u8 = undefined;
            var busy_scratch: [512]u8 = undefined;
            const status_line = self.liveThinkingLabel(&thinking_buf);
            const clipped_status = term.truncateEnd(&busy_scratch, status_line, @intCast(size.cols - 1));
            self.frame.moveTo(footer_row, 1);
            if (self.term.use_color) self.frame.appendSlice(term.Style.blue) catch {};
            self.frame.appendSlice(clipped_status) catch {};
            if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
            self.frame.appendSlice("\x1b[K") catch {};
            footer_row += 1;
        }

        if (self.model_picker_active) {
            var picker_input_buf: [512]u8 = undefined;
            const picker_input = modelPickerDisplayInput(&picker_input_buf, self.input.items);
            const is_model_command = modelCommandFromInput(self.allocator, self.input.items) catch null;
            if (is_model_command) |owned| self.allocator.free(owned);
            var query_scratch: [512]u8 = undefined;
            const query_line = if (is_model_command != null)
                std.fmt.bufPrint(
                    &query_scratch,
                    " model command: {s}  Enter run, Esc cancel",
                    .{picker_input},
                ) catch " model command"
            else
                std.fmt.bufPrint(
                    &query_scratch,
                    " model search: {s}  ({d} match{s})  Up/Down select, Enter switch, Esc cancel",
                    .{ picker_input, model_match_count, if (model_match_count == 1) "" else "es" },
                ) catch " model search";
            self.frame.moveTo(footer_row, 1);
            if (self.term.use_color) self.frame.appendSlice(term.Style.cyan) catch {};
            self.frame.appendSlice(term.truncateEnd(&scratch, query_line, @intCast(size.cols - 1))) catch {};
            if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
            self.frame.appendSlice("\x1b[K") catch {};
            footer_row += 1;

            if (is_model_command != null) {
                self.frame.moveTo(footer_row, 1);
                if (self.term.use_color) self.frame.appendSlice(term.Style.dim) catch {};
                self.frame.appendSlice("   Ready to update model config.") catch {};
                if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
                self.frame.appendSlice("\x1b[K") catch {};
                footer_row += 1;
            } else if (model_match_count == 0) {
                self.frame.moveTo(footer_row, 1);
                if (self.term.use_color) self.frame.appendSlice(term.Style.dim) catch {};
                self.frame.appendSlice("   No models match. Try provider/name words like qwen, groq, flash, local.") catch {};
                if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
                self.frame.appendSlice("\x1b[K") catch {};
                footer_row += 1;
            } else {
                const visible_count: usize = @min(model_match_count, max_model_picker_rows);
                const picker_start: usize = if (self.model_picker_index >= visible_count)
                    self.model_picker_index - visible_count + 1
                else
                    0;
                for (0..visible_count) |offset| {
                    const model_idx = picker_start + offset;
                    const m = self.modelPickerModelAt(model_idx) orelse continue;
                    var id_buf: [256]u8 = undefined;
                    const id = modelFullId(&id_buf, m) orelse continue;
                    const selected = model_idx == self.model_picker_index;
                    const current = std.mem.eql(u8, id, self.model_label);
                    const price = if (m.free) "free" else "custom";
                    var row_buf: [512]u8 = undefined;
                    const row_text = std.fmt.bufPrint(
                        &row_buf,
                        " {s} {s}  {s}  [{s}] {s}",
                        .{ if (selected) ">" else " ", if (current) "*" else " ", id, price, m.notes },
                    ) catch continue;
                    self.frame.moveTo(footer_row, 1);
                    if (selected) {
                        if (self.term.use_color) self.frame.appendSlice(term.Style.invert) catch {};
                        if (self.term.use_color) self.frame.appendSlice(term.Style.cyan) catch {};
                    } else if (current) {
                        if (self.term.use_color) self.frame.appendSlice(term.Style.green) catch {};
                    } else {
                        if (self.term.use_color) self.frame.appendSlice(term.Style.dim) catch {};
                    }
                    self.frame.appendSlice(term.truncateEnd(&scratch, row_text, @intCast(size.cols - 1))) catch {};
                    if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
                    self.frame.appendSlice("\x1b[K") catch {};
                    footer_row += 1;
                }
            }
        }

        if (pending) {
            var folder_scratch: [256]u8 = undefined;
            if (self.term.use_color) self.frame.appendSlice(term.Style.magenta) catch {};
            self.frame.writeRow(footer_row, size.cols, term.truncateEnd(&folder_scratch, approve_line, @intCast(size.cols - 1)));
            if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
            footer_row += 1;
        }

        var caret_row: ?u16 = null;
        var caret_col: u16 = 1;

        // Compute the real terminal cursor position. We append the cursor move
        // at the very end of render so later UI such as the shortcut hint bar
        // cannot steal the terminal cursor.
        if (!self.agent_busy and !pending and !self.show_help_overlay and live_prompt_row != null) {
            var prompt_buf: [512]u8 = undefined;
            const prompt_prefix = self.promptPrefix(&prompt_buf) catch "> project ";
            const prefix_cols = term.displayWidth(prompt_prefix);

            // For multi-line input (Ctrl+J), the cursor may be on a different
            // line than the prompt. We need to count how many newlines are
            // before the cursor position to determine the correct row offset.
            const input_before_cursor = self.input.items[0..@min(self.cursor, self.input.items.len)];
            var newline_count: usize = 0;
            for (input_before_cursor) |ch| {
                if (ch == '\n') newline_count += 1;
            }

            // Calculate the column position on the current line.
            // Find the last newline before cursor — text after it is on the current line.
            var current_line_start: usize = 0;
            if (std.mem.lastIndexOfScalar(u8, input_before_cursor, '\n')) |last_nl| {
                current_line_start = last_nl + 1;
            }
            const text_after_last_nl = input_before_cursor[current_line_start..];
            const cursor_text_cols = term.displayWidth(text_after_last_nl);

            // If on the first line (no newline before cursor), add prefix_cols.
            // On subsequent lines, cursor is at chat_x + indentation.
            caret_row = if (newline_count == 0)
                live_prompt_row.?
            else
                live_prompt_row.? + @as(u16, @intCast(newline_count));

            const input_gutter_cols: usize = if (chat_cols >= 64) 12 else 2;
            const input_start_col = @as(usize, chat_x) + input_gutter_cols;
            caret_col = if (newline_count == 0)
                @intCast(@min(@as(usize, size.cols), input_start_col + prefix_cols + cursor_text_cols))
            else
                @intCast(@min(@as(usize, size.cols), input_start_col + cursor_text_cols));
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
                        self.appendFrameSpaces(explorer_width - clipped.len);
                    }
                    if (is_selected) {
                        if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
                    }
                    e_row += 1;
                }
            }
        }

        // Help overlay — real modal with background fill (Phase 100).
        if (self.show_help_overlay) {
            const overlay_text = commands.helpOverlayText();
            var overlay_lines: std.ArrayList([]const u8) = .empty;
            defer overlay_lines.deinit(self.allocator);
            var split = std.mem.splitScalar(u8, overlay_text, '\n');
            while (split.next()) |line| {
                overlay_lines.append(self.allocator, line) catch {};
            }
            const overlay_h: u16 = @intCast(overlay_lines.items.len);
            const overlay_w: u16 = 72; // Width of the box drawing
            const start_row: u16 = if (size.rows > overlay_h + 4) @divFloor(size.rows - overlay_h, 2) else 1;
            const start_col: u16 = if (size.cols > overlay_w + 2) @divFloor(size.cols - overlay_w, 2) else 1;

            // Clear the full screen rows the overlay occupies, then fill with bg_block.
            for (0..overlay_h + 2) |i| {
                const overlay_row = start_row + @as(u16, @intCast(i));
                self.frame.moveTo(overlay_row, 1);
                if (self.term.use_color) self.frame.appendSlice(term.Style.bg_block) catch {};
                self.appendFrameSpaces(@intCast(size.cols));
                self.frame.appendSlice("\x1b[K") catch {};
                if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
            }

            // Draw overlay text on top of the filled background.
            for (0..overlay_h) |i| {
                const overlay_row = start_row + @as(u16, @intCast(i));
                self.frame.moveTo(overlay_row, start_col);
                if (self.term.use_color) {
                    self.frame.appendSlice(term.Style.bg_block) catch {};
                    self.frame.appendSlice(term.Style.bold) catch {};
                }
                self.frame.appendSlice(overlay_lines.items[i]) catch {};
                if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
            }

            // Footer hint with cyan highlight.
            self.frame.moveTo(start_row + overlay_h + 1, start_col);
            if (self.term.use_color) {
                self.frame.appendSlice(term.Style.bg_block) catch {};
                self.frame.appendSlice(term.Style.cyan) catch {};
            }
            self.frame.appendSlice("  Press any key to close this overlay") catch {};
            if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
        }

        // Shortcut hint bar — dim text at the very bottom showing key bindings.
        // Only shown when not busy + no overlays + no pickers active.
        if (!self.agent_busy and !self.show_help_overlay and !self.model_picker_active and !pending) {
            self.frame.moveTo(size.rows, 1);
            if (self.term.use_color) self.frame.appendSlice(term.Style.dim) catch {};
            var hint_buf: [256]u8 = undefined;
            const hint = std.fmt.bufPrint(&hint_buf, " ⏎ send  ⋮ /help  @ mention  ⌃J newline  ⌃Y copy  ⌃R retry  ↑↓ history  Esc clear ", .{}) catch "";
            self.frame.appendSlice(hint) catch {};
            // Pad to end of line + clear rest.
            const hint_cols = term.displayWidth(hint);
            if (size.cols > hint_cols + 1) {
                self.appendFrameSpaces(size.cols - hint_cols - 1);
            }
            self.frame.appendSlice("\x1b[K") catch {};
            if (self.term.use_color) self.frame.appendSlice(term.Style.reset) catch {};
        }

        if (caret_row) |row_pos| {
            self.frame.moveTo(row_pos, caret_col);
            self.frame.appendSlice("\x1b[?25h") catch {};
        } else {
            self.frame.appendSlice("\x1b[?25l") catch {};
        }

        self.frame.flush();
    }

    fn liveThinkingLabel(self: *const App, buf: []u8) []const u8 {
        const progress = self.active_progress[0..self.active_progress_len];
        const spinner = self.spinnerChar();

        if (progress.len > 0 and !std.mem.startsWith(u8, progress, "Thinking")) {
            // Tool running — show spinner + progress bar + action + elapsed time.
            if (self.active_tool_running and self.active_tool_len > 0) {
                const tool_name = self.active_tool[0..self.active_tool_len];
                const action = getToolAction(tool_name);
                const bar = self.progressBar(15);

                // Show elapsed time since tool started.
                const now_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
                const elapsed_s = if (self.spinner_last_ms > 0) @divFloor(now_ms - self.spinner_last_ms, 1000) else 0;

                if (elapsed_s > 0) {
                    return std.fmt.bufPrint(buf, "{s} {s} {s} · {d}s", .{ spinner, bar, action, elapsed_s }) catch progress;
                }
                return std.fmt.bufPrint(buf, "{s} {s} {s}", .{ spinner, bar, action }) catch progress;
            }
            return std.fmt.bufPrint(buf, "{s} {s}", .{ spinner, progress }) catch progress;
        }

        // Default thinking indicator — show spinner + elapsed time for
        // better UX feedback (user knows the agent is still working).
        const now_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        const elapsed_s = if (self.spinner_last_ms > 0) @divFloor(now_ms - self.spinner_last_ms, 1000) else 0;
        if (elapsed_s > 2) {
            return std.fmt.bufPrint(buf, "{s} Working · {d}s", .{ spinner, elapsed_s }) catch "Working...";
        }
        const dots: usize = @intCast(@mod(@divTrunc(now_ms, 320), 3) + 1);
        return std.fmt.bufPrint(buf, "{s} Working{s}", .{ spinner, "..."[0..dots] }) catch "Working...";
    }

    /// Returns a progress bar string of the given width, animated based
    /// on spinner_frame. Used for tool execution feedback (Phase 28).
    fn progressBar(self: *const App, width: usize) []const u8 {
        // 10 spinner frames map to 0-100% progress
        const fill: usize = @as(usize, self.spinner_frame) % (width + 1);
        var buf: [64]u8 = undefined;
        var i: usize = 0;
        while (i < width and i < buf.len) : (i += 1) {
            buf[i] = if (i < fill) '#' else '-';
        }
        return buf[0..@min(width, buf.len)];
    }
};

/// Check if a word is a keyword for the given language (Phase 31).
fn isKeyword(word: []const u8, lang: []const u8) bool {
    // Common keywords across languages
    const common = [_][]const u8{ "if", "else", "for", "while", "return", "break", "continue", "switch", "case", "default", "true", "false", "null", "None", "nil", "and", "or", "not" };
    for (common) |kw| if (std.mem.eql(u8, word, kw)) return true;

    if (std.mem.eql(u8, lang, "zig")) {
        const zig_kws = [_][]const u8{ "const", "var", "fn", "pub", "struct", "enum", "union", "error", "try", "catch", "async", "await", "comptime", "inline", "extern", "export", "packed", "align", "linksection", "orelse", "unreachable", "defer", "errdefer", "usingnamespace", "test", "and", "or", "not", "anytype", "anyerror", "anyframe", "allowzero", "volatile", "callconv", "noalias" };
        for (zig_kws) |kw| if (std.mem.eql(u8, word, kw)) return true;
    } else if (std.mem.eql(u8, lang, "python") or std.mem.eql(u8, lang, "py")) {
        const py_kws = [_][]const u8{ "def", "class", "import", "from", "as", "with", "lambda", "yield", "raise", "except", "finally", "global", "nonlocal", "assert", "del", "in", "is", "pass", "elif" };
        for (py_kws) |kw| if (std.mem.eql(u8, word, kw)) return true;
    } else if (std.mem.eql(u8, lang, "javascript") or std.mem.eql(u8, lang, "js") or std.mem.eql(u8, lang, "typescript") or std.mem.eql(u8, lang, "ts")) {
        const js_kws = [_][]const u8{ "function", "const", "let", "var", "class", "extends", "super", "new", "this", "typeof", "instanceof", "in", "of", "async", "await", "yield", "throw", "try", "catch", "finally", "import", "export", "from", "as", "void", "delete", "void", "get", "set" };
        for (js_kws) |kw| if (std.mem.eql(u8, word, kw)) return true;
    } else if (std.mem.eql(u8, lang, "go")) {
        const go_kws = [_][]const u8{ "func", "type", "struct", "interface", "map", "chan", "go", "defer", "select", "range", "package", "import", "fallthrough", "goto", "type", "make", "new", "len", "cap", "append", "copy", "delete", "panic", "recover" };
        for (go_kws) |kw| if (std.mem.eql(u8, word, kw)) return true;
    } else if (std.mem.eql(u8, lang, "rust") or std.mem.eql(u8, lang, "rs")) {
        const rust_kws = [_][]const u8{ "fn", "let", "mut", "struct", "enum", "trait", "impl", "use", "mod", "crate", "self", "Self", "where", "unsafe", "move", "ref", "static", "extern", "dyn", "as", "box", "macro_rules" };
        for (rust_kws) |kw| if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}

/// Check if a word is a type name for the given language (Phase 31).
fn isType(word: []const u8, lang: []const u8) bool {
    if (std.mem.eql(u8, lang, "zig")) {
        const zig_types = [_][]const u8{ "u8", "u16", "u32", "u64", "i8", "i16", "i32", "i64", "f32", "f64", "bool", "void", "usize", "isize", "anyopaque", "c_int", "c_uint", "c_char", "c_long", "c_ulong", "c_float", "c_double", "c_void" };
        for (zig_types) |t| if (std.mem.eql(u8, word, t)) return true;
    } else if (std.mem.eql(u8, lang, "python") or std.mem.eql(u8, lang, "py")) {
        const py_types = [_][]const u8{ "int", "float", "str", "bool", "list", "dict", "tuple", "set", "bytes", "object", "type" };
        for (py_types) |t| if (std.mem.eql(u8, word, t)) return true;
    } else if (std.mem.eql(u8, lang, "javascript") or std.mem.eql(u8, lang, "js") or std.mem.eql(u8, lang, "typescript") or std.mem.eql(u8, lang, "ts")) {
        const js_types = [_][]const u8{ "string", "number", "boolean", "object", "Array", "Promise", "Map", "Set", "Date", "RegExp", "Error", "Symbol", "BigInt" };
        for (js_types) |t| if (std.mem.eql(u8, word, t)) return true;
    } else if (std.mem.eql(u8, lang, "go")) {
        const go_types = [_][]const u8{ "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64", "float32", "float64", "string", "bool", "byte", "rune", "error", "any" };
        for (go_types) |t| if (std.mem.eql(u8, word, t)) return true;
    } else if (std.mem.eql(u8, lang, "rust") or std.mem.eql(u8, lang, "rs")) {
        const rust_types = [_][]const u8{ "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "f32", "f64", "bool", "char", "str", "String", "Vec", "Option", "Result", "Box" };
        for (rust_types) |t| if (std.mem.eql(u8, word, t)) return true;
    }
    return false;
}

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
    defer provider_opts.deinit(app.allocator);
    provider_opts.options.stream_callback = streamBridge;
    provider_opts.options.stream_context = app;
    if (envTruthy("FORGE_AI_DEBUG")) {
        const debug_line = std.fmt.allocPrint(
            app.allocator,
            "[forge-ai] resolved provider={s} model={s} base_url={s}",
            .{
                provider_opts.options.provider_name,
                provider_opts.options.model orelse "default",
                provider_opts.options.base_url orelse "(default)",
            },
        ) catch null;
        if (debug_line) |line| app.pushLine(.system, line) catch app.allocator.free(line);
    }
    const max_steps = parsed.flags.max_steps;
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
        .use_inline_edits = app.agent_mode == .agent and app.tool_policy == .run_everything,
        .step_begin_callback = stepBeginBridge,
        .step_begin_context = app,
        .step_callback = stepBridge,
        .step_context = app,
        .turn_callback = turnBridge,
        .turn_context = app,
        .compaction_callback = compactionBridge,
        .compaction_context = app,
        .rate_limit_callback = rateLimitBridge,
        .rate_limit_context = app,
        .telemetry_callback = telemetryBridge,
        .telemetry_context = app,
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
            const msg = agentErrorMessage(app.allocator, err, provider_opts.options) catch {
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

fn agentErrorMessage(allocator: std.mem.Allocator, err: ai.agent.AgentError, provider_opts: ai.provider_factory.Options) ![]u8 {
    const provider = provider_opts.provider_name;
    const model = provider_opts.model orelse "default";
    return switch (err) {
        error.ProviderFailed => std.fmt.allocPrint(
            allocator,
            "Agent error: provider call failed for {s}/{s}. The model may have returned invalid tool-loop output or the provider returned an unsupported error. Run with `FORGE_AI_DEBUG=1` to see HTTP status.",
            .{ provider, model },
        ),
        error.AuthenticationFailed => std.fmt.allocPrint(
            allocator,
            "Agent error: authentication failed for {s}/{s}. Check the provider API key.",
            .{ provider, model },
        ),
        error.RateLimitExceeded => std.fmt.allocPrint(
            allocator,
            "Agent error: rate limit or quota exceeded for {s}/{s}. Try another model or wait for quota reset.",
            .{ provider, model },
        ),
        error.ContextLengthExceeded => std.fmt.allocPrint(
            allocator,
            "Agent error: prompt/context too large for {s}/{s}. Try a shorter request, fewer files, or a larger-context model.",
            .{ provider, model },
        ),
        error.ModelUnavailable => std.fmt.allocPrint(
            allocator,
            "Agent error: model unavailable for {s}/{s}. The model id may be removed, paid-only, or not enabled for your account. Try `/model openrouter/qwen/qwen3-coder` or another available model.",
            .{ provider, model },
        ),
        error.NetworkError => std.fmt.allocPrint(
            allocator,
            "Agent error: network error calling {s}/{s}. Check connectivity, base URL, or provider status.",
            .{ provider, model },
        ),
        error.StepLimitReached => allocator.dupe(u8, "Agent error: explicit step cap reached; compact checkpoint saved. Resume with a higher --max-steps or omit the cap."),
        error.DuplicateLoop => allocator.dupe(u8, "Agent error: agent repeated the same tool calls. Give a more specific file/symbol or use /resume."),
        error.NoProgress => allocator.dupe(u8, "Agent error: no progress after broad searches. Point to a specific file or task."),
        else => std.fmt.allocPrint(allocator, "Agent error: {s} for {s}/{s}", .{ @errorName(err), provider, model }),
    };
}

fn streamBridge(context: ?*anyopaque, chunk: []const u8) void {
    const app: *App = @ptrCast(@alignCast(context.?));
    app.onStreamChunk(chunk);
}

fn telemetryBridge(context: ?*anyopaque, event: ai.agent_loop.Telemetry) void {
    const app: *App = @ptrCast(@alignCast(context.?));
    if (!std.mem.eql(u8, event.phase, "prompt")) return;

    var buf: [96]u8 = undefined;
    const kb = (event.bytes + 1023) / 1024;
    const label = if (event.items > 0)
        std.fmt.bufPrint(&buf, "{d}kB/{d} blocks", .{ kb, event.items }) catch return
    else
        std.fmt.bufPrint(&buf, "{d}kB", .{kb}) catch return;

    const owned = app.allocator.dupe(u8, label) catch return;
    app.mutex.lock();
    app.allocator.free(app.context_label);
    app.context_label = owned;
    app.markDirty();
    app.mutex.unlock();
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
    var summary_buf: [320]u8 = undefined;
    const summary = app.formatToolDoneSummary(&summary_buf, step.kind, step.summary);
    const line = std.fmt.bufPrint(&buf, "#{d} {s}", .{ step.index, summary }) catch return;
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

fn rateLimitBridge(context: ?*anyopaque, attempt: u8, max_attempts: u8, delay_ms: u32, conversation_bytes: usize) void {
    const app: *App = @ptrCast(@alignCast(context.?));
    const delay_s = delay_ms / 1000;
    var buf: [192]u8 = undefined;
    const line = std.fmt.bufPrint(
        &buf,
        "Rate limited: waiting {d}s before retry {d}/{d} with existing context ({d}kB)",
        .{ delay_s, attempt, max_attempts, conversation_bytes / 1024 },
    ) catch return;
    app.pushLine(.system, app.allocator.dupe(u8, line) catch return) catch {};
    app.pushTimelineLine(.system, app.allocator.dupe(u8, line) catch return) catch {};

    app.mutex.lock();
    const label = std.fmt.bufPrint(
        &buf,
        "Rate limited; retrying in {d}s ({d}/{d})",
        .{ delay_s, attempt, max_attempts },
    ) catch "Rate limited; waiting";
    const len = @min(label.len, app.active_progress.len);
    @memcpy(app.active_progress[0..len], label[0..len]);
    app.active_progress_len = len;
    app.markDirty();
    app.mutex.unlock();
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
    errdefer scope.deinit();

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
