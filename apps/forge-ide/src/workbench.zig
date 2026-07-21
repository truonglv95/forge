const std = @import("std");
const kernel = @import("forge-kernel");
const editor = @import("forge-editor");
const workspace = @import("forge-workspace");
const plugin = @import("forge-plugin");
const lsp = @import("forge-lsp");
const keybindings_mod = @import("keybindings.zig");
const workspace_io = @import("workspace_io.zig");
const explorer_tree = @import("explorer/tree.zig");
const explorer_ops = @import("explorer/ops.zig");
const builtin_ext = @import("extensions/builtin.zig");
const wasm_bridge = @import("extensions/wasm_bridge.zig");
const commands_mod = @import("workbench/commands.zig");
const palette_mod = @import("workbench/palette.zig");
const task_output_mod = @import("workbench/task_output.zig");
const tasks_mod = @import("workbench/tasks.zig");
const recovery_mod = @import("workbench/recovery.zig");
const agent_session = @import("agent/session.zig");
const agent_workflow = @import("agent/workflow.zig");
const ai = @import("forge-ai");
const agent_scope_picker = @import("agent/scope_picker.zig");
const renderer = @import("forge-renderer");
const SearchCtx = @import("workbench/search_ops.zig").SearchCtx;
const SearchController = @import("workbench/search_controller.zig").SearchController;
const GitController = @import("workbench/git_controller.zig").GitController;
const ExplorerController = @import("workbench/explorer_controller.zig").ExplorerController;
const LspController = @import("workbench/lsp_controller.zig").LspController;
const EditorController = @import("workbench/editor_controller.zig").EditorController;
const AgentController = @import("workbench/agent_controller.zig").AgentController;
const DebugController = @import("workbench/debug_controller.zig").DebugController;

const git_status_mod = @import("git/status.zig");
const git_diff_mod = @import("git/diff.zig");
const diagnostics_store_mod = @import("workbench/diagnostics_store.zig");
const completion_store_mod = @import("workbench/completion_store.zig");
const hover_store_mod = @import("workbench/hover_store.zig");
const references_store_mod = @import("workbench/references_store.zig");
const terminal_session_mod = @import("workbench/terminal_session.zig");
const terminal_group_mod = @import("workbench/terminal_group.zig");
const lsp_sync_mod = @import("workbench/lsp_sync.zig");
const lsp_config_mod = @import("workbench/lsp_config.zig");
const rename_preview_mod = @import("workbench/rename_preview.zig");
const debug_lldb_session_mod = @import("workbench/debug_lldb_session.zig");
const debug_dap_session_mod = @import("workbench/debug_dap_session.zig");
const debug_stop_mod = @import("workbench/debug_stop.zig");
const debug_variables_mod = @import("workbench/debug_variables.zig");
const debug_callstack_mod = @import("workbench/debug_callstack.zig");
const debug_recovery_mod = @import("workbench/debug_recovery.zig");
const recent_workspaces_mod = @import("workbench/recent_workspaces.zig");
const debug_console_mod = @import("workbench/debug_console.zig");
const breakpoints_mod = @import("workbench/breakpoints.zig");
const workspace_symbol_picker_mod = @import("workbench/workspace_symbol_picker.zig");
const git_branch_picker_mod = @import("workbench/git_branch_picker.zig");
const editor_find_mod = @import("workbench/editor_find.zig");
const settings_mod = @import("workbench/settings.zig");
const ai_config_io = @import("workbench/ai_config_io.zig");
const ai_model_config_mod = @import("workbench/ai_model_config.zig");
const navigation_history_mod = @import("workbench/navigation_history.zig");
const session_restore_mod = @import("workbench/session_restore.zig");
const chat_persistence_mod = @import("workbench/chat_persistence.zig");
const agent_ui_queue_mod = @import("workbench/agent_ui_queue.zig");
const ghost_completion_mod = @import("workbench/ghost_completion.zig");
const fold_controller_mod = @import("forge-editor").folding;
const multi_cursor_mod = @import("forge-editor").multi_cursor;
const inline_edit_mod = @import("workbench/inline_edit.zig");
const mention_picker_mod = @import("workbench/mention_picker.zig");
const mention_resolver_mod = @import("workbench/mention_resolver.zig");
const context_menu_mod = @import("workbench/context_menu.zig");
const inlay_hints_store_mod = @import("workbench/inlay_hints_store.zig");
const launch_config_mod = @import("workbench/launch_config.zig");
const notifications_mod = @import("workbench/notifications.zig");
const watch_expressions_mod = @import("workbench/watch_expressions.zig");
const sync_mod = @import("forge-util").sync;

pub const PanelFocus = enum { editor, agent, explorer, search, git, run, extensions, ai, settings_modal, proposal_review, terminal, palette, conflict, recovery, find, goto_line, rename, output_channels };
pub const EditorPane = enum { primary, secondary };
pub const ChatRole = @import("workbench/types.zig").ChatRole;
pub const ChatMessage = struct {
    role: ChatRole,
    content: [:0]const u8,
    tool_index: u32 = 0,
    tool_kind: ?[:0]const u8 = null,
    tool_content: ?[:0]const u8 = null,
    tool_running: bool = false,
};

fn freeChatMessage(allocator: std.mem.Allocator, msg: ChatMessage) void {
    allocator.free(msg.content);
    if (msg.tool_kind) |kind| allocator.free(kind);
    if (msg.tool_content) |content| allocator.free(content);
}
pub const Command = commands_mod.Command;
pub const Event = commands_mod.Event;

pub const InitOptions = struct {
    show_welcome: bool = false,
    record_workspace: bool = true,
};

pub const Workbench = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
    workspace_name: []const u8,
    workspace_root: workspace.WorkspaceRoot,
    git: GitController,
    git_initialized: bool = false,
    editor_initialized: bool = false,
    agent_ui_initialized: bool = false,
    debug_initialized: bool = false,
    explorer: explorer_tree.Tree,
    extension_host: plugin.Host,
    keybindings: keybindings_mod.Registry,
    lsp: LspController,
    editor: EditorController,
    agent_ui: AgentController,
    debug: DebugController,

    lsp_initialized: bool = false,
    marketplace_catalog: ?plugin.MarketplaceCatalog = null,
    extensions_panel_mode: @import("ui/sidebar/extensions_panel.zig").PanelMode = .installed,
    extensions_filter: [128]u8 = undefined,
    extensions_filter_len: usize = 0,
    extensions_detail_index: ?usize = null,
    bottom_panel_mode: commands_mod.BottomPanelMode = .output,
    search_buffer: editor.Buffer,
    search: SearchController = .{},
    sync_icon_angle: f32 = 0,
    run_scroll_y: f32 = 0,
    recent_workspace_paths: []const []const u8 = &.{},
    terminals: terminal_group_mod.Group,
    terminals_initialized: bool = false,
    events: kernel.EventBus(Event),
    palette: palette_mod.Palette,
    workspace_symbol_picker: workspace_symbol_picker_mod.Picker,
    git_branch_picker: git_branch_picker_mod.Picker,
    output_channels: std.StringHashMap(*@import("workbench/output_channel.zig").OutputChannel),
    active_output_channel_id: []const u8,
    output_channel_picker: @import("workbench/output_channel_picker.zig").Picker,
    scope_picker_paths: std.ArrayList([]const u8),
    scope_picker_filtered: std.ArrayList(usize),
    rename_buffer: editor.Buffer,
    // Inline edit (Cmd+K) state (P0-2)
    // Mention picker (@file/@symbol/@folder/@web) (P0-3)
    mention_picker: mention_picker_mod.Picker,
    // Context menu state (P0-5)
    context_menu: context_menu_mod.Menu,
    // Launch configurations (P0-7)
    launch_configs: []launch_config_mod.Config,
    // P1-4: Toast notifications
    notifications: notifications_mod.Store,
    // P1.5-2: Status bar clickable items (reused buffer per frame).
    status_bar_items: [16]@import("ui/render/status_bar.zig").Item = undefined,
    status_bar_item_count: usize = 0,
    // P1.5-3: Watch expressions for debugger
    focused_panel: PanelFocus = .editor,
    previous_focus: PanelFocus = .editor,
    renaming: bool = false,
    agent_panel_width: f32 = 380.0,
    sidebar_width: f32 = 250.0,
    explorer_scroll_y: f32 = 0,
    explorer_root_expanded: bool = true,
    explorer_boot_pending: bool = true,
    bottom_panel_height: f32 = @import("ui/core/layout.zig").task_panel_height,
    sidebar_visible: bool = true,
    bottom_panel_visible: bool = true,
    agent_panel_visible: bool = true,
    welcome_visible: bool = false,
    nav_history: navigation_history_mod.History = undefined,
    terminal_selection: ?@import("ui/panel/terminal_panel.zig").Selection = null,
    shell_mode: @import("ui/core/layout.zig").ShellMode = .ide,
    editor_scroll_y: f32 = 0,
    editor_scroll_x: f32 = 0,
    split_scroll_y: f32 = 0,
    split_scroll_x: f32 = 0,
    editor_split: bool = false,
    editor_pane_focus: EditorPane = .primary,
    split_tab_index: usize = 0,
    tab_scroll_x: f32 = 0,
    extensions_scroll_y: f32 = 0,
    settings_modal_scroll_y: f32 = 0,
    settings_modal_open: bool = false,
    settings_modal_tab: @import("ui/settings_modal.zig").Tab = .general,
    settings_embedding_picker_open: bool = false,
    settings_model_editor_open: bool = false,
    settings_model_editor_kind: ai_model_config_mod.ModelKind = .chat,
    settings_model_editor_index: ?usize = null,
    settings_model_editor_field: ai_model_config_mod.ModelEditorField = .label,
    settings_model_editor_label: [160]u8 = undefined,
    settings_model_editor_label_len: usize = 0,
    settings_model_editor_id: [220]u8 = undefined,
    settings_model_editor_id_len: usize = 0,
    settings_model_editor_provider: [80]u8 = undefined,
    settings_model_editor_provider_len: usize = 0,
    settings_model_editor_base_url: [260]u8 = undefined,
    settings_model_editor_base_url_len: usize = 0,

    proposal_review_open: bool = false,
    proposal_review_scroll_y: f32 = 0,
    proposal_review_file_index: usize = 0,
    ai_mcp_status: ?[]const u8 = null,
    ai_mcp_registry: ?ai.mcp_registry.Registry = null,
    ai_mcp_scroll_y: f32 = 0,
    sidebar_view: @import("ui/sidebar/sidebar_view.zig").SidebarView = .explorer,
    selected_extension_index: ?usize = null,
    chat_scroll_y: f32 = 0,
    chat_follow_stream: bool = false,
    chat_scroll_to_end_on_ready: bool = false,
    chat_history_revision: u32 = 0,
    chat_layout: @import("workbench/chat_layout.zig").Cache = .{},
    prompt_scroll_y: f32 = 0,
    task_scroll_y: f32 = 0,
    status_message: []const u8 = "",
    untitled_serial: u32 = 0,
    conflict_path: ?[]const u8 = null,
    recovery_count: usize = 0,
    conflict_check_cooldown: f32 = 0,
    conflict_full_check_cooldown: f32 = 30.0,
    terminal_prompt_refresh_cooldown: f32 = 3.0,
    git_refresh_cooldown: f32 = 3.0,
    terminal_boot_pending: bool = false,
    theme: workspace.Theme = workspace.Theme.darkDefault(),
    active_extension_theme: []const u8 = "",
    find_bar: editor_find_mod.FindBar,
    goto_bar: editor_find_mod.GotoBar,
    rename_bar: editor_find_mod.RenameBar,
    user_settings: settings_mod.Settings = .{},
    ide_launcher: []const u8 = "forge-ide",
    environ_map: ?*const std.process.Environ.Map = null,

    ime_text: ?[]const u8 = null,
    ime_cursor: i32 = -1,

    code_scroll_x: std.AutoHashMap(u64, CodeScrollState),
    rendered_code_blocks: std.ArrayList(RenderedCodeBlock),
    wrap_cache: std.AutoHashMap(u64, *WrapCache),
    max_line_len_cache: std.AutoHashMap(u64, MaxLineLenCache),

    bracket_match_cache: BracketMatchCache = .{},
    review_hunks_cache: ReviewHunksCache = .{},
    conflict_blocks_cache: ConflictBlocksCache = .{},
    conflict_action_rects: std.ArrayListUnmanaged(ConflictActionRect) = .empty,

    pub const ConflictActionRect = struct {
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        cmd: @import("workbench/commands.zig").Command,
    };

    pub const MaxLineLenCache = struct { revision: u64, len: usize };

    pub const ConflictBlocksCache = struct {
        file_path_hash: u64 = 0,
        buf_revision: u64 = 0,
        blocks: std.ArrayListUnmanaged(@import("workbench/conflict_resolver.zig").ConflictBlock) = .empty,
    };

    pub const BracketMatchCache = struct {
        file_path_hash: u64 = 0,
        revision: u64 = 0,
        row: usize = 0,
        col: usize = 0,
        match: ?@import("ui/editor/bracket_match.zig").Match = null,
    };

    pub const ReviewHunksCache = struct {
        file_path_hash: u64 = 0,
        buf_revision: u64 = 0,
        review_revision: u64 = 0,
        hunks: @import("ui/render/editor/review_overlay.zig").ReviewHunks = .{},
    };

    pub const CodeScrollState = struct {
        scroll_x: f32 = 0,
        max_scroll_x: f32 = 0,
    };

    pub const SplitterDragState = struct {
        active: bool = false,
        start_x: f32 = 0,
        start_y: f32 = 0,
        start_w: f32 = 0,
        start_h: f32 = 0,
    };

    pub const RenderedCodeBlock = struct {
        hash: u64,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
    };

    pub const WrapCache = @import("ui/editor/word_wrap.zig").WrapCache;

    pub fn init(self: *Workbench, allocator: std.mem.Allocator, io: std.Io, workspace_path: []const u8, ide_launcher: []const u8, environ_map: ?*const std.process.Environ.Map) !void {
        return initWithOptions(self, allocator, io, workspace_path, ide_launcher, environ_map, .{});
    }

    pub fn initWithOptions(self: *Workbench, allocator: std.mem.Allocator, io: std.Io, workspace_path: []const u8, ide_launcher: []const u8, environ_map: ?*const std.process.Environ.Map, options: InitOptions) !void {
        var root = try workspace.WorkspaceRoot.open(io, workspace_path);
        errdefer root.close(io);

        const canonical_workspace_path = workspace.global_store.canonicalWorkspacePathFromRoot(allocator, io, root) catch
            try workspace.global_store.canonicalWorkspacePath(allocator, io, workspace_path);
        errdefer allocator.free(canonical_workspace_path);
        ai.index_warm.scheduleBackground(allocator, io, environ_map, root, canonical_workspace_path);

        var normalized_path: []const u8 = canonical_workspace_path;
        while (normalized_path.len > 1 and (normalized_path[normalized_path.len - 1] == '/' or normalized_path[normalized_path.len - 1] == '\\')) {
            normalized_path = normalized_path[0 .. normalized_path.len - 1];
        }
        var name = std.fs.path.basename(normalized_path);
        if (name.len == 0 or std.mem.eql(u8, name, ".")) {
            name = "WORKSPACE";
        }
        const workspace_name = try allocator.dupe(u8, name);
        errdefer allocator.free(workspace_name);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .workspace_path = canonical_workspace_path,
            .workspace_name = workspace_name,
            .workspace_root = root,
            .git = undefined,
            .editor = undefined,
            .agent_ui = undefined,
            .debug = undefined,
            .welcome_visible = options.show_welcome,
            .explorer = explorer_tree.Tree.init(allocator),
            .extension_host = plugin.Host.init(allocator, io),
            .keybindings = keybindings_mod.Registry.init(allocator),
            .nav_history = navigation_history_mod.History.init(allocator),
            .lsp = undefined,
            .events = kernel.EventBus(Event).init(allocator),
            .palette = try palette_mod.Palette.init(allocator),
            .workspace_symbol_picker = try workspace_symbol_picker_mod.Picker.init(allocator, null),
            .git_branch_picker = try git_branch_picker_mod.Picker.init(allocator),
            .output_channels = std.StringHashMap(*@import("workbench/output_channel.zig").OutputChannel).init(allocator),
            .active_output_channel_id = "tasks",
            .output_channel_picker = try @import("workbench/output_channel_picker.zig").Picker.init(allocator),
            .scope_picker_paths = .empty,
            .scope_picker_filtered = .empty,
            .rename_buffer = try editor.Buffer.init(allocator),
            .search_buffer = try editor.Buffer.init(allocator),
            .find_bar = try editor_find_mod.FindBar.init(allocator),
            .goto_bar = try editor_find_mod.GotoBar.init(allocator),
            .rename_bar = try editor_find_mod.RenameBar.init(allocator),
            .ide_launcher = try allocator.dupe(u8, ide_launcher),
            .environ_map = environ_map,
            .terminals = undefined,
            .code_scroll_x = std.AutoHashMap(u64, CodeScrollState).init(allocator),
            .rendered_code_blocks = .empty,
            .wrap_cache = std.AutoHashMap(u64, *WrapCache).init(allocator),
            .max_line_len_cache = std.AutoHashMap(u64, MaxLineLenCache).init(allocator),
            .mention_picker = mention_picker_mod.Picker.init(allocator),
            .context_menu = context_menu_mod.Menu.init(allocator),
            .launch_configs = &.{},
            .notifications = notifications_mod.Store.init(allocator),
        };
        errdefer self.deinit();

        self.editor = try EditorController.init(allocator, io);
        self.agent_ui = try AgentController.init(allocator, io);
        self.debug = try DebugController.init(allocator, io, root);
        self.git = try GitController.init(allocator);
        self.git_initialized = true;

        self.terminals = try terminal_group_mod.Group.init(allocator, io, self.workspace_path);
        self.terminals_initialized = true;

        self.lsp = try LspController.init(allocator, io, canonical_workspace_path, root);
        self.lsp_initialized = true;
        self.workspace_symbol_picker.proxy = self.lsp.proxy;
        try self.lsp.start();
        workspace.recovery.recoverPending(allocator, io, self.workspace_root) catch {};

        try self.extension_host.registerBuiltin(&builtin_ext.hello_extension);
        try self.extension_host.registerBuiltin(&builtin_ext.lsp_extension);
        self.extension_host.setHostCallbacks(wasm_bridge.hostCallbacks());
        self.marketplace_catalog = plugin.marketplace.loadCatalog(allocator, io, root) catch null;
        try @import("workbench/extensions_ops.zig").ensureBundledExtensions(self);
        try self.extension_host.discoverWorkspace(self.workspace_root);
        try self.extension_host.activateAll();
        try self.syncContributions();
        try self.palette.addExtensionCommands(&self.extension_host);
        // Register default channels
        _ = try self.getOrCreateOutputChannel("tasks", "Tasks");
        _ = try self.getOrCreateOutputChannel("git", "Git");

        if (options.record_workspace) {
            try recent_workspaces_mod.record(allocator, io, self.workspace_path);
        }
        try self.refreshRecentWorkspaces();

        @import("git/logger.zig").global_log_ctx = self;
        @import("git/logger.zig").global_log_fn = struct {
            fn log(ctx: ?*anyopaque, args: []const []const u8) void {
                const s: *Workbench = @ptrCast(@alignCast(ctx orelse return));
                var buf: [1024]u8 = undefined;
                var len: usize = 0;

                const prefix = "[info] >";
                @memcpy(buf[len .. len + prefix.len], prefix);
                len += prefix.len;

                for (args) |arg| {
                    if (len + 1 + arg.len > buf.len) break;
                    buf[len] = ' ';
                    len += 1;
                    @memcpy(buf[len .. len + arg.len], arg);
                    len += arg.len;
                }
                if (len + 1 <= buf.len) {
                    buf[len] = '\n';
                    len += 1;
                }
                if (s.getOutputChannel("git")) |git_chan| {
                    git_chan.output.appendChunk(buf[0..len]) catch {};
                }
            }
        }.log;

        self.theme = try @import("theme_loader.zig").loadTheme(allocator, io, root, &self.extension_host);
        self.user_settings = settings_mod.load(allocator, io, root) catch |err| blk: {
            self.logBackgroundError("Load settings", err);
            break :blk .{};
        };
        settings_mod.writeAiPanelFontSize(allocator, io, root, self.user_settings.ai_panel_font_size) catch |err| {
            self.logBackgroundError("Persist AI panel font size", err);
        };
        self.agent_ui.edit_mode = self.user_settings.agent_edit_mode;
        settings_mod.applyToTheme(self.user_settings, &self.theme);
        @import("theme_loader.zig").syncFontMetrics(&self.theme);
        @import("theme_loader.zig").applyToRenderer(&self.theme);
        // Re-initialize ghost completion with config read from user settings.
        self.editor.ghost.deinit();
        self.editor.ghost = ghost_completion_mod.Store.init(allocator, io, .{
            .provider = self.user_settings.ghost_provider,
            .model = self.user_settings.ghost_model,
            .ollama_url = self.user_settings.ghost_ollama_url,
            .enabled = self.user_settings.ghost_enabled,
            .ai_provider = self.user_settings.ghost_ai_provider,
            .ai_base_url = self.user_settings.ghost_ai_base_url,
        });
        self.editor.ghost.setEnvironMap(self.environ_map);

        try self.reloadAiConfigFromDisk();
        std.debug.print("wb.agent_ui.models.len = {}, embed_models.len = {}\n", .{ self.agent_ui.models.len, self.agent_ui.embedding_models.len });

        try self.restoreSessionTabs();
        if (self.editor.tabs.tabs.items.len == 0) {
            try self.dispatch(.{ .open_file = "apps/forge-ide/src/main.zig" });
        }
        self.recovery_count = recovery_mod.countRecoveryFiles(allocator, io, root) catch 0;
        if (self.recovery_count > 0) {
            self.settings_modal_open = true;

            self.previous_focus = .editor;
            self.focused_panel = .recovery;
        }
        agent_workflow.refreshRunHistory(&@import("workbench/agent_ops.zig").agentHost(self)) catch |err| {
            self.logBackgroundError("Refresh AI run history", err);
        };
        agent_workflow.scanResumableSession(&@import("workbench/agent_ops.zig").agentHost(self));
        try self.restoreChatHistory();
    }

    pub fn getOutputChannel(self: *Workbench, id: []const u8) ?*@import("workbench/output_channel.zig").OutputChannel {
        return self.output_channels.get(id);
    }

    pub fn getOrCreateOutputChannel(self: *Workbench, id: []const u8, name: []const u8) !*@import("workbench/output_channel.zig").OutputChannel {
        if (self.getOutputChannel(id)) |existing| {
            return existing;
        }
        const channel = try @import("workbench/output_channel.zig").OutputChannel.init(self.allocator, self.io, id, name);
        try self.output_channels.put(channel.id, channel);
        return channel;
    }

    pub fn deinit(self: *Workbench) void {
        self.persistSessionState() catch |err| self.logBackgroundError("Persist session state", err);
        recovery_mod.snapshotDirtyDocs(self.allocator, self.io, self.workspace_root, &self.editor.tabs) catch |err| {
            self.logBackgroundError("Snapshot dirty documents", err);
        };
        if (self.conflict_path) |path| self.allocator.free(path);
        if (self.status_message.len > 0) self.allocator.free(self.status_message);
        for (self.agent_ui.chat_history.items) |msg| freeChatMessage(self.allocator, msg);
        self.agent_ui.chat_history.deinit(self.allocator);
        self.conflict_blocks_cache.blocks.deinit(self.allocator);
        self.conflict_action_rects.deinit(self.allocator);
        self.chat_layout.deinit(self.allocator);
        self.rename_buffer.deinit();
        self.search_buffer.deinit();
        self.search.deinit();
        if (self.git_initialized) self.git.deinit(self.allocator);
        recent_workspaces_mod.freePaths(self.allocator, self.recent_workspace_paths);
        if (self.terminals_initialized) self.terminals.deinit();
        if (self.lsp_initialized) self.lsp.deinit();
        self.mention_picker.deinit();
        self.git_branch_picker.deinit();
        self.context_menu.deinit();
        launch_config_mod.freeConfigs(self.allocator, self.launch_configs);
        self.notifications.deinit();
        self.code_scroll_x.deinit();
        self.rendered_code_blocks.deinit(self.allocator);

        var wrap_cache_iter = self.wrap_cache.iterator();
        while (wrap_cache_iter.next()) |entry| {
            entry.value_ptr.*.deinit();

            self.editor.deinit();
            self.agent_ui.deinit();
            self.debug.deinit();
        }
        self.wrap_cache.deinit();
        self.max_line_len_cache.deinit();

        self.events.deinit();
        self.palette.deinit();
        self.workspace_symbol_picker.deinit();
        self.agent_ui.ui_queue.deinit(self.allocator);
        self.agent_ui.prompt_buffer.deinit();
        var it = self.output_channels.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.output_channels.deinit();
        self.output_channel_picker.deinit();
        self.agent_ui.session.deinit();
        @import("workbench/agent_ops.zig").clearScopePickerPaths(self);
        self.scope_picker_paths.deinit(self.allocator);
        self.scope_picker_filtered.deinit(self.allocator);
        self.find_bar.deinit();
        self.goto_bar.deinit();
        self.rename_bar.deinit();
        self.user_settings.deinit(self.allocator);
        self.allocator.free(self.agent_ui.provider);
        if (self.agent_ui.model) |model| self.allocator.free(model);
        if (self.agent_ui.ollama_url) |url| self.allocator.free(url);
        if (self.agent_ui.openrouter_url) |url| self.allocator.free(url);
        if (self.agent_ui.embedding_provider) |provider| self.allocator.free(provider);
        if (self.agent_ui.embedding_model) |model| self.allocator.free(model);
        if (self.agent_ui.embedding_url) |url| self.allocator.free(url);
        if (self.agent_ui.models.len > 0) {
            for (self.agent_ui.models) |opt| {
                self.allocator.free(opt.id);
                self.allocator.free(opt.label);
                self.allocator.free(opt.provider);
            }
            self.allocator.free(self.agent_ui.models);
        }
        if (self.ai_mcp_status) |status| self.allocator.free(status);
        if (self.ai_mcp_registry) |*reg| reg.deinit();
        self.allocator.free(self.ide_launcher);
        self.palette.deinit();
        self.theme.deinit();
        if (self.active_extension_theme.len > 0) self.allocator.free(self.active_extension_theme);
        if (self.marketplace_catalog) |*catalog| catalog.deinit(self.allocator);
        self.nav_history.deinit();
        self.keybindings.deinit();
        self.events.deinit();
        self.extension_host.deinit();
        self.explorer.deinit();
        self.editor.tabs.deinit();
        self.workspace_root.close(self.io);
        self.allocator.free(self.workspace_path);
    }

    pub fn layoutGeometry(self: *const Workbench, window_w: f32, window_h: f32) @import("ui/core/layout.zig").Geometry {
        return @import("ui/core/layout.zig").compute(
            self.shell_mode,
            window_w,
            window_h,
            self.sidebar_width,
            self.agent_panel_width,
            self.bottom_panel_height,
            self.sidebar_visible,
            self.agent_panel_visible,
            self.bottom_panel_visible,
        );
    }

    pub fn headerToolbarState(self: *const Workbench) @import("ui/chrome/header_toolbar.zig").ToolbarState {
        return .{
            .shell_mode = self.shell_mode,
            .sidebar_visible = self.sidebar_visible,
            .bottom_panel_visible = self.bottom_panel_visible,
            .agent_panel_visible = self.agent_panel_visible,
            .can_go_back = self.nav_history.canGoBack(),
            .can_go_forward = self.nav_history.canGoForward(),
        };
    }

    pub fn handleHeaderAction(self: *Workbench, action: @import("ui/chrome/header_toolbar.zig").Action) !void {
        switch (action) {
            .toggle_sidebar => {
                self.sidebar_visible = !self.sidebar_visible;
                try self.setStatus(if (self.sidebar_visible) "Sidebar shown" else "Sidebar hidden");
            },
            .nav_back => try self.navBack(),
            .nav_forward => try self.navForward(),
            .toggle_bottom_panel => {
                self.bottom_panel_visible = !self.bottom_panel_visible;
                try self.setStatus(if (self.bottom_panel_visible) "Panel shown" else "Panel hidden");
            },
            .toggle_agent => {
                self.agent_panel_visible = !self.agent_panel_visible;
                try self.setStatus(if (self.agent_panel_visible) "Agent panel shown" else "Agent panel hidden");
            },
            .open_settings => try @import("workbench/agent_ops.zig").openSettingsModal(self),
            .toggle_agent_window => try self.dispatch(.toggle_shell_mode),
        }
    }

    pub fn navBack(self: *Workbench) !void {
        const entry = self.nav_history.back() orelse return;
        try self.goToNavEntry(entry);
    }

    pub fn navForward(self: *Workbench) !void {
        const entry = self.nav_history.forward() orelse return;
        try self.goToNavEntry(entry);
    }

    fn goToNavEntry(self: *Workbench, entry: navigation_history_mod.Entry) !void {
        self.nav_history.suppress = true;
        defer self.nav_history.suppress = false;
        for (self.editor.tabs.tabs.items, 0..) |doc, i| {
            if (std.mem.eql(u8, doc.path, entry.path)) {
                try self.activateTab(i);
                return;
            }
        }
        try self.openFile(entry.path);
    }

    fn recordNavigation(self: *Workbench, path: []const u8) !void {
        try self.nav_history.record(path, self.editor.tabs.active);
    }

    pub fn dispatch(self: *Workbench, command: Command) anyerror!void {
        return @import("workbench/dispatch.zig").dispatch(self, command);
    }

    pub fn clampProposalReviewScroll(self: *Workbench, editor_h: f32) void {
        @import("workbench/scroll.zig").clampProposalReviewScroll(self, editor_h);
    }

    pub fn composerInputHeight(self: *Workbench, agent_w: f32) f32 {
        const ac = @import("ui/agent/agent_composer.zig");
        self.agent_ui.session.lock();
        const attachment_count = self.agent_ui.session.attachments.items.len;
        self.agent_ui.session.unlock();
        const visual_lines = ac.visualLineCount(&self.agent_ui.prompt_buffer, agent_w);
        return ac.inputTextHeight(attachment_count, visual_lines);
    }

    pub fn clampPromptScroll(self: *Workbench, agent_w: f32) void {
        @import("workbench/scroll.zig").clampPromptScroll(self, agent_w);
    }

    pub fn updateTabPath(self: *Workbench, old_path: []const u8, new_path: []const u8) !void {
        for (self.editor.tabs.tabs.items) |*doc| {
            if (!std.mem.eql(u8, doc.path, old_path)) continue;
            self.allocator.free(doc.path);
            doc.path = try self.allocator.dupe(u8, new_path);
        }
    }

    pub fn commitRename(self: *Workbench) !void {
        const path = self.explorer.selected_path orelse return;
        const content = try self.rename_buffer.content();
        defer self.rename_buffer.allocator.free(content);
        if (content.len == 0) {
            self.renaming = false;
            return;
        }
        const new_name = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(new_name);
        try self.dispatch(.{ .explorer_rename = .{ .path = path, .new_name = new_name } });
    }

    pub fn cancelRename(self: *Workbench) void {
        self.renaming = false;
    }

    pub fn explorerKind(self: *const Workbench, path: []const u8) ?std.Io.File.Kind {
        for (self.explorer.entries) |entry| {
            if (std.mem.eql(u8, entry.path, path)) return entry.kind;
        }
        return null;
    }

    pub fn setStatus(self: *Workbench, message: []const u8) !void {
        if (self.status_message.len > 0) self.allocator.free(self.status_message);
        self.status_message = try self.allocator.dupeZ(u8, message);
        try self.events.publish(.{ .status_message = self.status_message });
    }

    pub fn logBackgroundError(self: *Workbench, action: []const u8, err: anyerror) void {
        std.debug.print("[forge] {s} failed: {s}\n", .{ action, @errorName(err) });
        var line_buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "[warn] {s} failed: {s}\n", .{ action, @errorName(err) }) catch return;
        if (self.getOrCreateOutputChannel("forge", "Forge") catch null) |chan| {
            chan.output.appendChunk(line) catch {};
        }
        var status_buf: [128]u8 = undefined;
        const status = std.fmt.bufPrint(&status_buf, "{s} failed: {s}", .{ action, @errorName(err) }) catch "Background task failed";
        self.setStatus(status) catch {};
    }

    pub fn activeTerminal(self: *Workbench) *terminal_session_mod.TerminalSession {
        return self.terminals.activeSession();
    }

    pub fn paneWidth(self: *const Workbench, editor_w: f32) f32 {
        if (!self.editor_split) return editor_w;
        return (editor_w - 4) / 2;
    }

    pub fn paneOriginX(self: *const Workbench, editor_x: f32, editor_w: f32, pane: EditorPane) f32 {
        if (!self.editor_split or pane == .primary) return editor_x;
        return editor_x + self.paneWidth(editor_w) + 4;
    }

    pub fn paneAt(self: *const Workbench, editor_x: f32, editor_w: f32, x: f32) EditorPane {
        if (!self.editor_split) return .primary;
        if (x < editor_x + self.paneWidth(editor_w)) return .primary;
        return .secondary;
    }

    pub fn docForPane(self: *Workbench, pane: EditorPane) ?*editor.Document {
        if (self.editor.tabs.tabs.items.len == 0) return null;
        const idx = if (!self.editor_split or pane == .primary) self.editor.tabs.active else self.split_tab_index;
        if (idx >= self.editor.tabs.tabs.items.len) return null;
        return &self.editor.tabs.tabs.items[idx];
    }

    pub fn focusedPane(self: *const Workbench) EditorPane {
        if (!self.editor_split) return .primary;
        return self.editor_pane_focus;
    }

    pub fn focusedDoc(self: *Workbench) ?*editor.Document {
        return self.docForPane(self.focusedPane());
    }

    pub fn activeBuffer(self: *Workbench) ?*editor.Buffer {
        const doc = self.focusedDoc() orelse return null;
        return &doc.buffer;
    }

    pub fn tabLabel(self: *const Workbench, index: usize, out: []u8) []const u8 {
        const path = self.editor.tabs.tabs.items[index].path;
        const base = std.fs.path.basename(path);
        return std.fmt.bufPrint(out, "{s}{s}", .{
            base,
            if (self.editor.tabs.tabs.items[index].isDirty()) " •" else "",
        }) catch base;
    }

    pub fn activePathBasename(self: *const Workbench) []const u8 {
        if (self.editor.tabs.tabs.items.len == 0) return "untitled";
        if (self.editor.tabs.active >= self.editor.tabs.tabs.items.len) return "untitled";
        return std.fs.path.basename(self.editor.tabs.tabs.items[self.editor.tabs.active].path);
    }

    pub fn activeFilePath(self: *const Workbench) ?[]const u8 {
        if (self.editor.tabs.tabs.items.len == 0) return null;
        const idx = if (!self.editor_split or self.editor_pane_focus == .primary) self.editor.tabs.active else self.split_tab_index;
        if (idx >= self.editor.tabs.tabs.items.len) return null;
        return self.editor.tabs.tabs.items[idx].path;
    }

    pub fn splitEditorRight(self: *Workbench) !void {
        if (self.editor.tabs.tabs.items.len == 0) return;
        self.editor_split = true;
        self.split_tab_index = self.editor.tabs.active;
        self.editor_pane_focus = .primary;
        try self.setStatus("Editor split");
    }

    pub fn closeEditorSplit(self: *Workbench) !void {
        if (!self.editor_split) return;
        self.editor_split = false;
        self.editor_pane_focus = .primary;
        try self.setStatus("Split closed");
    }

    pub fn clampEditorScroll(self: *Workbench, editor_w: f32, editor_h: f32) void {
        @import("workbench/scroll.zig").clampEditorScroll(self, editor_w, editor_h);
    }

    pub fn clampExplorerScroll(self: *Workbench, window_h: f32) void {
        @import("workbench/scroll.zig").clampExplorerScroll(self, window_h);
    }

    pub fn clampExtensionsScroll(self: *Workbench, window_h: f32) void {
        @import("workbench/scroll.zig").clampExtensionsScroll(self, window_h);
    }

    pub fn clampAiSettingsScroll(self: *Workbench, editor_h: f32) void {
        @import("workbench/scroll.zig").clampAiSettingsScroll(self, editor_h);
    }

    pub fn extensionsFilterSlice(self: *const Workbench) []const u8 {
        return self.extensions_filter[0..self.extensions_filter_len];
    }

    pub fn clampSearchScroll(self: *Workbench, window_h: f32) void {
        @import("workbench/scroll.zig").clampSearchScroll(self, window_h);
    }

    pub fn clampGitScroll(self: *Workbench, window_h: f32) void {
        @import("workbench/scroll.zig").clampGitScroll(self, window_h);
    }

    pub fn clampRunScroll(self: *Workbench, window_h: f32) void {
        @import("workbench/scroll.zig").clampRunScroll(self, window_h);
    }

    pub fn bottomPanelLineCount(self: *const Workbench) usize {
        return switch (self.bottom_panel_mode) {
            .output => blk: {
                if (self.lsp.rename_preview.active) {
                    break :blk self.lsp.rename_preview.lines.len + 1;
                }
                if (self.lsp.references.active) break :blk self.lsp.references.items.len;
                if (@constCast(self).getOutputChannel(self.active_output_channel_id)) |chan| {
                    break :blk chan.output.lines.items.len;
                }
                break :blk 0;
            },
            .problems => self.lsp.diagnostics.list.items.len,
            .terminal => blk: {
                const terminals: *terminal_group_mod.Group = @constCast(&self.terminals);
                const terminal = terminals.activeSession();
                terminal.lock();
                defer terminal.unlock();
                const partial: usize = if (terminal.local_input != null or terminal.isActive()) 1 else 0;
                break :blk terminal.lines.items.len + partial;
            },
            .debug_console => self.debug.console.lines.items.len,
            .debug_variables => self.debug.variables.items.items.len,
            .debug_callstack => self.debug.callstack.items.items.len,
        };
    }

    pub fn clampBottomPanelScroll(self: *Workbench, panel_h: f32) void {
        @import("workbench/scroll.zig").clampBottomPanelScroll(self, panel_h);
    }

    pub fn copyTerminalSelection(self: *Workbench) !void {
        const terminal_panel = @import("ui/panel/terminal_panel.zig");
        const sel = self.terminal_selection orelse return;
        if (sel.isEmpty()) return;

        const terminal = self.activeTerminal();
        terminal.lock();
        const text = terminal_panel.extractText(self.allocator, terminal.lines.items, sel) catch {
            terminal.unlock();
            return;
        };
        terminal.unlock();
        defer self.allocator.free(text);

        if (text.len == 0) return;
        renderer.Renderer.setClipboardText(text);
        try self.setStatus("Terminal selection copied");
    }

    pub fn clampChatScroll(self: *Workbench, agent_h: f32, agent_w: f32) void {
        @import("workbench/scroll.zig").clampChatScroll(self, agent_h, agent_w);
    }

    pub fn invalidateChatLayout(self: *Workbench) void {
        @import("workbench/chat_layout.zig").invalidate(self);
    }

    pub fn scrollChatToEnd(self: *Workbench) void {
        var win_w: f32 = 0;
        var win_h: f32 = 0;
        renderer.Renderer.getWindowSize(&win_w, &win_h);
        @import("workbench/chat_layout.zig").scrollToEnd(self, win_h);
    }

    pub fn clampReviewScroll(self: *Workbench, agent_h: f32) void {
        @import("workbench/scroll.zig").clampReviewScroll(self, agent_h);
    }

    pub fn updateTerminalPrompt(self: *Workbench) !void {
        var buf: [256]u8 = undefined;
        const git_ptr: ?*const git_status_mod.Status = if (self.git.status) |*status| status else null;
        const prompt = @import("ui/panel/terminal_prompt.zig").format(self.workspace_path, git_ptr, &buf);
        try self.activeTerminal().setPromptLine(prompt);
    }

    pub fn requestEditorHover(
        self: *Workbench,
        doc_path: []const u8,
        row: usize,
        col: usize,
        anchor_x: f32,
        anchor_y: f32,
    ) void {
        self.lsp.hover.requestAt(doc_path, @intCast(row), @intCast(col), anchor_x, anchor_y);
    }

    pub fn syncContributions(self: *Workbench) !void {
        try self.keybindings.rebuild(&self.extension_host);
        self.lsp.registry.clear(self.allocator);
        try lsp_config_mod.loadBundledExtensions(self.allocator, self.io, self.lsp.registry);
        for (self.extension_host.contributions.languages.items) |lang| {
            try lsp_config_mod.addContribution(self.allocator, self.io, self.lsp.registry, .{
                .language_id = lang.id,
                .server = lang.server,
                .args = lang.args,
                .file_pattern = lang.file_pattern,
                .server_resolver = lang.server_resolver,
                .extension_id = lang.extension_id,
            });
        }
        try lsp_config_mod.loadGlobalAndWorkspace(self.allocator, self.io, self.workspace_root, self.lsp.registry);
        try self.lsp.proxy.syncRegistry(self.lsp.registry);
        try self.palette.addExtensionCommands(&self.extension_host);
        try self.palette.addContributionCommands(&self.extension_host);

        if (self.editor.tabs.activeDoc()) |doc| self.warmLspForPath(doc.path);
    }

    fn warmLspForPath(self: *Workbench, path: []const u8) void {
        const owned = self.lsp.registry.copyMatchForPath(self.allocator, path) catch return;
        const config = owned orelse return;
        defer lsp.Registry.freeConfig(self.allocator, config);
        self.lsp.proxy.warmLanguage(config);
    }

    pub fn reloadTheme(self: *Workbench) !void {
        self.theme.deinit();
        self.theme = try @import("theme_loader.zig").loadTheme(self.allocator, self.io, self.workspace_root, &self.extension_host);
        settings_mod.applyToTheme(self.user_settings, &self.theme);
        @import("theme_loader.zig").syncFontMetrics(&self.theme);
        @import("theme_loader.zig").applyToRenderer(&self.theme);
        try self.setStatus("Theme reloaded");
    }

    fn freeModelOptions(allocator: std.mem.Allocator, models: []const @import("ui/agent/agent_composer.zig").ModelOption) void {
        for (models) |m| {
            allocator.free(m.id);
            allocator.free(m.label);
            allocator.free(m.provider);
            if (m.base_url) |url| allocator.free(url);
        }
        if (models.len > 0) allocator.free(models);
    }

    fn parseModelOptionsOrDefault(
        allocator: std.mem.Allocator,
        custom_models: ?[]const u8,
        default_models: []const u8,
        debug_label: []const u8,
    ) ![]@import("ui/agent/agent_composer.zig").ModelOption {
        const composer = @import("ui/agent/agent_composer.zig");
        if (custom_models) |custom| {
            if (composer.parseCustomModels(allocator, custom)) |models_list| {
                return models_list;
            } else |err| {
                std.debug.print("parseCustomModels {s} error: {}\n", .{ debug_label, err });
            }
        }
        return composer.parseCustomModels(allocator, default_models);
    }

    fn reloadAiConfigFromDisk(self: *Workbench) !void {
        const composer = @import("ui/agent/agent_composer.zig");
        const cfg = loadAiConfig(self.allocator, self.io, self.workspace_root) catch |err| {
            std.debug.print("global_store.loadConfig error: {}\n", .{err});

            const models_list = parseModelOptionsOrDefault(self.allocator, null, composer.default_models_str, "default") catch return;
            const embed_models_list = parseModelOptionsOrDefault(self.allocator, null, composer.default_embedding_models_str, "embed default") catch {
                freeModelOptions(self.allocator, models_list);
                return;
            };
            freeModelOptions(self.allocator, self.agent_ui.models);
            freeModelOptions(self.allocator, self.agent_ui.embedding_models);
            self.agent_ui.models = models_list;
            self.agent_ui.embedding_models = embed_models_list;
            if (self.agent_ui.model == null and self.agent_ui.models.len > 0) {
                self.agent_ui.model = try self.allocator.dupe(u8, self.agent_ui.models[0].id);
                self.allocator.free(self.agent_ui.provider);
                self.agent_ui.provider = try self.allocator.dupe(u8, self.agent_ui.models[0].provider);
            }
            return;
        };
        defer if (cfg.custom_models) |custom| self.allocator.free(custom);
        defer if (cfg.custom_embedding_models) |custom| self.allocator.free(custom);

        const models_list = try parseModelOptionsOrDefault(self.allocator, cfg.custom_models, composer.default_models_str, "agent");
        errdefer freeModelOptions(self.allocator, models_list);
        const embed_models_list = try parseModelOptionsOrDefault(self.allocator, cfg.custom_embedding_models, composer.default_embedding_models_str, "embed");
        errdefer freeModelOptions(self.allocator, embed_models_list);

        self.allocator.free(self.agent_ui.provider);
        self.agent_ui.provider = cfg.provider;
        if (self.agent_ui.model) |model| self.allocator.free(model);
        self.agent_ui.model = cfg.model;
        if (self.agent_ui.ollama_url) |url| self.allocator.free(url);
        self.agent_ui.ollama_url = cfg.ollama_url;
        if (self.agent_ui.openrouter_url) |url| self.allocator.free(url);
        self.agent_ui.openrouter_url = cfg.openrouter_url;
        if (self.agent_ui.embedding_provider) |provider| self.allocator.free(provider);
        self.agent_ui.embedding_provider = cfg.embedding_provider;
        if (self.agent_ui.embedding_model) |model| self.allocator.free(model);
        self.agent_ui.embedding_model = cfg.embedding_model;
        if (self.agent_ui.embedding_url) |url| self.allocator.free(url);
        self.agent_ui.embedding_url = cfg.embedding_url;
        self.agent_ui.mcp_enabled = cfg.mcp_enabled;
        self.agent_ui.enable_hyde = cfg.enable_hyde;

        freeModelOptions(self.allocator, self.agent_ui.models);
        freeModelOptions(self.allocator, self.agent_ui.embedding_models);
        self.agent_ui.models = models_list;
        self.agent_ui.embedding_models = embed_models_list;

        if (self.agent_ui.model == null and self.agent_ui.models.len > 0) {
            self.agent_ui.model = try self.allocator.dupe(u8, self.agent_ui.models[0].id);
            self.allocator.free(self.agent_ui.provider);
            self.agent_ui.provider = try self.allocator.dupe(u8, self.agent_ui.models[0].provider);
        }
    }

    pub fn reloadUserSettings(self: *Workbench) !void {
        self.user_settings.deinit(self.allocator);
        self.user_settings = settings_mod.load(self.allocator, self.io, self.workspace_root) catch .{};
        self.agent_ui.edit_mode = self.user_settings.agent_edit_mode;
        settings_mod.applyToTheme(self.user_settings, &self.theme);
        @import("theme_loader.zig").syncFontMetrics(&self.theme);
        @import("theme_loader.zig").applyToRenderer(&self.theme);
        self.invalidateChatLayout();
        try self.reloadAiConfigFromDisk();
        try self.setStatus("Settings reloaded");
    }

    pub fn toggleWordWrap(self: *Workbench) !void {
        const next = !self.user_settings.word_wrap;
        try settings_mod.writeWordWrap(self.allocator, self.io, self.workspace_root, next);
        self.reloadOpenSettingsDocuments();
        try self.reloadUserSettings();
        const msg = if (next) "Word wrap enabled" else "Word wrap disabled";
        try self.setStatus(msg);
    }

    pub fn setAiPanelFontSize(self: *Workbench, font_size: f32) !void {
        const next = std.math.clamp(font_size, 12.0, 20.0);
        self.user_settings.ai_panel_font_size = next;
        settings_mod.applyToTheme(self.user_settings, &self.theme);
        self.invalidateChatLayout();
        self.chat_scroll_to_end_on_ready = true;

        try settings_mod.writeAiPanelFontSize(self.allocator, self.io, self.workspace_root, next);
        self.reloadOpenSettingsDocuments();
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "AI panel font size set to {d:.1}px", .{next}) catch "AI panel font size updated";
        try self.setStatus(msg);
    }

    pub fn setAgentEditMode(self: *Workbench, mode: @import("workbench/agent_edit_mode.zig").Mode) !void {
        self.user_settings.agent_edit_mode = mode;
        self.agent_ui.edit_mode = mode;
        try settings_mod.writeAgentEditMode(self.allocator, self.io, self.workspace_root, mode);
        self.reloadOpenSettingsDocuments();
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Agent edit mode set to {s}", .{mode.label()}) catch "Agent edit mode updated";
        try self.setStatus(msg);
    }

    pub fn setEditorFontSize(self: *Workbench, font_size: f32) !void {
        const next = std.math.clamp(font_size, 8.0, 32.0);
        self.user_settings.font_size = next;
        self.applyEditorTypographyRuntime();
        try settings_mod.writeEditorFontSize(self.allocator, self.io, self.workspace_root, next);
        self.reloadOpenSettingsDocuments();
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Editor font size set to {d:.1}px", .{next}) catch "Editor font size updated";
        try self.setStatus(msg);
    }

    pub fn setEditorLineHeight(self: *Workbench, line_height: f32) !void {
        const next = std.math.clamp(line_height, 1.0, 2.5);
        self.user_settings.line_height = next;
        self.applyEditorTypographyRuntime();
        try settings_mod.writeEditorLineHeight(self.allocator, self.io, self.workspace_root, next);
        self.reloadOpenSettingsDocuments();
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Editor line height set to {d:.2}", .{next}) catch "Editor line height updated";
        try self.setStatus(msg);
    }

    fn applyEditorTypographyRuntime(self: *Workbench) void {
        settings_mod.applyToTheme(self.user_settings, &self.theme);
        @import("theme_loader.zig").syncFontMetrics(&self.theme);
        @import("theme_loader.zig").applyToRenderer(&self.theme);
        self.invalidateChatLayout();
    }

    fn reloadOpenSettingsDocuments(self: *Workbench) void {
        for (self.editor.tabs.tabs.items) |*doc| {
            if (std.mem.endsWith(u8, doc.path, "settings.toml")) {
                workspace_io.loadDocument(self.io, self.workspace_root, doc) catch {};
            }
        }
    }

    pub fn refreshRecentWorkspaces(self: *Workbench) !void {
        recent_workspaces_mod.freePaths(self.allocator, self.recent_workspace_paths);
        self.recent_workspace_paths = try recent_workspaces_mod.loadAll(self.allocator, self.io);
        try self.palette.addRecentWorkspaces(self.recent_workspace_paths);
    }

    pub fn openRecentWorkspace(self: *Workbench, index: usize) !void {
        if (index >= self.recent_workspace_paths.len) return;
        const path = self.recent_workspace_paths[index];
        if (std.mem.eql(u8, path, self.workspace_path)) {
            try self.setStatus("Already in this workspace");
            return;
        }
        try recent_workspaces_mod.spawnIde(self.allocator, self.ide_launcher, path);
        try self.setStatus("Opened workspace in new Forge window");
    }

    /// P1-1: Refresh document symbols for the active file from the LSP.
    /// Skipped if the file hasn't changed since the last fetch.
    pub fn refreshOutlineSymbols(self: *Workbench) !void {
        const doc = self.editor.tabs.activeDoc() orelse return;

        // Skip if same path + same revision as last fetch.
        const path_changed = (self.lsp.outline_last_path == null or
            !std.mem.eql(u8, self.lsp.outline_last_path.?, doc.path));
        const revision_changed = (self.lsp.outline_last_revision != doc.buffer.revision);
        if (!path_changed and !revision_changed) return;

        // Update tracking.
        if (self.lsp.outline_last_path) |old| self.allocator.free(old);
        self.lsp.outline_last_path = try self.allocator.dupe(u8, doc.path);
        self.lsp.outline_last_revision = doc.buffer.revision;

        // Free existing symbols.
        for (self.lsp.outline_symbols) |*sym| sym.deinit(self.allocator);
        if (self.lsp.outline_symbols.len > 0) self.allocator.free(self.lsp.outline_symbols);
        self.lsp.outline_symbols = &.{};

        // Skip if no LSP for this file.
        const owned = try self.lsp.registry.copyMatchForPath(self.allocator, doc.path);
        const config = owned orelse return;
        defer lsp.Registry.freeConfig(self.allocator, config);

        // Ensure doc is synced with LSP.
        const uri = self.lsp.sync.ensureSyncedBlocking(doc) catch return;
        defer self.allocator.free(uri);

        // Build and send documentSymbol request.
        const req = try lsp.document_symbol.buildDocumentSymbolRequest(self.allocator, 99, uri);
        defer self.allocator.free(req);

        var response_buf: [65536]u8 = undefined;
        const len = self.lsp.proxy.request(config.language_id, req, &response_buf, response_buf.len) catch return;
        if (len == 0) return;

        var list = lsp.document_symbol.parseDocumentSymbolResponse(self.allocator, response_buf[0..len]) catch return;
        defer list.deinit(self.allocator);

        // Steal the items array — we'll own it.
        const items = list.items;
        list.items = &.{};
        self.lsp.outline_symbols = items;
    }

    /// P1.5-3: Evaluate all watch expressions via the DAP session.
    pub fn refreshWatchExpressions(self: *Workbench) !void {
        if (!self.debug.dap.isActive()) return;
        if (self.debug.watch_expressions.count() == 0) return;
        // Evaluate each expression with frame_id 0 (no frame context).
        // A future improvement would be to use the top frame from the
        // last stackTrace response.
        for (0..self.debug.watch_expressions.count()) |i| {
            const entry = self.debug.watch_expressions.get(i) orelse continue;
            const result = self.debug.dap.evaluate(entry.expression, 0) catch {
                self.debug.watch_expressions.setResult(i, "evaluation failed", false);
                continue;
            };
            defer self.allocator.free(result);
            self.debug.watch_expressions.setResult(i, result, true);
        }
    }

    pub fn quickFixAtCursor(self: *Workbench, action_index: ?usize, screen_x: f32, screen_y: f32) !void {
        const doc = self.editor.tabs.activeDoc() orelse {
            try self.setStatus("No file open for quick fix");
            return;
        };
        const row: u32 = @intCast(doc.buffer.cursor.row);
        const col: u32 = @intCast(doc.buffer.cursor.col);

        var diag_match: ?lsp.diagnostics.Diagnostic = null;
        for (self.lsp.diagnostics.list.items) |diag| {
            if (diag.line != row) continue;
            if (col >= diag.character and col <= diag.end_character) {
                diag_match = diag;
                break;
            }
        }
        const diag = diag_match orelse {
            try self.setStatus("No diagnostic at cursor");
            return;
        };

        _ = try self.lsp.sync.ensureSyncedBlocking(doc);

        const uri = try lsp.diagnostics.fileUri(self.allocator, self.workspace_path, doc.path);
        defer self.allocator.free(uri);

        const req = try lsp.code_action.buildCodeActionRequest(self.allocator, 95, uri, diag);
        defer self.allocator.free(req);

        const owned = try self.lsp.registry.copyMatchForPath(self.allocator, doc.path);
        const config = owned orelse {
            try self.setStatus("No language server for quick fix");
            return;
        };
        defer lsp.Registry.freeConfig(self.allocator, config);

        var response_buf: [256 * 1024]u8 = undefined;
        const len = self.lsp.proxy.request(config.language_id, req, &response_buf, response_buf.len) catch |err| {
            try self.setStatus(@errorName(err));
            return;
        };

        const actions = try lsp.code_action.parseCodeActionResponse(self.allocator, response_buf[0..len]);
        defer {
            for (actions) |*action| action.deinit(self.allocator);
            self.allocator.free(actions);
        }
        if (actions.len == 0) {
            try self.setStatus("No quick fixes available");
            return;
        }

        if (action_index) |idx| {
            if (idx >= actions.len) return;
            if (actions[idx].edit) |*edit| {
                try self.lsp.rename_preview.setPreview(self.workspace_path, &self.editor.tabs, actions[idx].title, edit.*);
                self.bottom_panel_mode = .output;
                self.bottom_panel_visible = true;
                return;
            }
            try self.setStatus("Quick fix has no edit");
            return;
        }

        var titles: std.ArrayList([]const u8) = .empty;
        defer titles.deinit(self.allocator);
        for (actions) |action| try titles.append(self.allocator, self.allocator.dupe(u8, action.title) catch action.title);
        try self.context_menu.openQuickFix(screen_x, screen_y, titles.items);
    }

    pub fn clampTabScroll(self: *Workbench, editor_w: f32) void {
        @import("workbench/scroll.zig").clampTabScroll(self, editor_w);
    }

    pub fn syncTabScroll(self: *Workbench) void {
        const renderer_mod = @import("forge-renderer");
        const tabs_ui = @import("ui/editor/tabs.zig");
        var w: f32 = 0;
        var h: f32 = 0;
        renderer_mod.Renderer.getWindowSize(&w, &h);
        const geo = self.layoutGeometry(w, h);
        if (self.editor.tabs.tabs.items.len > 0) {
            const visible_w = @max(10, geo.editor_w - 60);
            tabs_ui.scrollToTab(self, self.editor.tabs.active, geo.editor_x, visible_w);
        } else {
            self.tab_scroll_x = 0;
        }
    }

    pub fn closeTabAt(self: *Workbench, index: usize) !void {
        if (index >= self.editor.tabs.tabs.items.len) return;
        const path = self.editor.tabs.tabs.items[index].path;
        self.lsp.sync.onDocumentClosed(path);
        self.editor.tabs.closeAt(index);
        if (self.editor_split and self.split_tab_index >= self.editor.tabs.tabs.items.len) {
            if (self.editor.tabs.tabs.items.len == 0) {
                self.editor_split = false;
            } else {
                self.split_tab_index = @min(self.split_tab_index, self.editor.tabs.tabs.items.len - 1);
            }
        }
        if (self.editor.tabs.tabs.items.len > 0) {
            try self.explorer.select(self.editor.tabs.tabs.items[self.editor.tabs.active].path);
            self.focused_panel = .editor;
            self.syncTabScroll();
        } else {
            self.tab_scroll_x = 0;
        }
    }

    pub fn handleExplorerClick(self: *Workbench, row_index: usize, click_x: f32, explorer_x: f32) !void {
        _ = click_x;
        _ = explorer_x;
        if (self.renaming) return;
        const path = self.explorer.hitTestRow(row_index) orelse return;
        const kind = self.explorerKind(path) orelse return;
        try self.explorer.select(path);
        switch (kind) {
            .file => {
                try self.dispatch(.{ .open_file = path });
                self.focused_panel = .editor;
            },
            .directory => {
                self.focused_panel = .explorer;
                try self.dispatch(.{ .explorer_toggle = path });
            },
            else => {},
        }
    }

    pub fn explorerPathDepth(self: *const Workbench, path: []const u8) u32 {
        _ = self;
        if (path.len == 0) return 0;
        return @intCast(std.mem.count(u8, path, "/"));
    }

    pub fn nextUntitledName(self: *Workbench, buf: []u8) []const u8 {
        self.untitled_serial += 1;
        return std.fmt.bufPrint(buf, "untitled-{d}.txt", .{self.untitled_serial}) catch "untitled.txt";
    }

    pub fn executePaletteSelection(self: *Workbench) !void {
        const entry = self.palette.selectedEntry() orelse return;
        try self.dispatch(.palette_close);
        switch (entry.command) {
            .run_extension_command => |id| {
                const owned = try self.allocator.dupe(u8, id);
                defer self.allocator.free(owned);
                try self.dispatch(.{ .run_extension_command = owned });
            },
            .open_extensions_dir => |path| {
                const owned = try self.allocator.dupe(u8, path);
                defer self.allocator.free(owned);
                try self.dispatch(.{ .open_extensions_dir = owned });
            },
            .run_task => |name| {
                const owned = try self.allocator.dupe(u8, name);
                defer self.allocator.free(owned);
                try self.dispatch(.{ .run_task = owned });
            },
            .install_marketplace_extension => |id| {
                const owned = try self.allocator.dupe(u8, id);
                defer self.allocator.free(owned);
                try self.dispatch(.{ .install_marketplace_extension = owned });
            },
            .apply_extension_theme => |qualified| {
                const owned = try self.allocator.dupe(u8, qualified);
                defer self.allocator.free(owned);
                try self.dispatch(.{ .apply_extension_theme = owned });
            },
            else => try self.dispatch(entry.command),
        }
    }

    pub fn onTaskLine(context: ?*anyopaque, line: []const u8) void {
        const self: *Workbench = @ptrCast(@alignCast(context.?));
        if (self.getOutputChannel("tasks")) |chan| {
            chan.output.appendLine(line) catch {};
        }
    }

    pub fn onTaskFinished(context: ?*anyopaque, exit_code: i32) void {
        const self: *Workbench = @ptrCast(@alignCast(context.?));
        if (self.getOutputChannel("tasks")) |chan| {
            chan.output.setRunning(false);
            chan.output.setExitCode(exit_code);
        }
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Task finished (exit {d})", .{exit_code}) catch "Task finished";
        self.debug.console.log(msg) catch {};
        self.setStatus(if (exit_code == 0) "Task finished" else "Task failed") catch {};
    }

    pub fn handleProblemsClick(self: *Workbench, index: usize) !void {
        try self.dispatch(.{ .problems_goto = index });
    }

    pub fn persistSessionState(self: *Workbench) !void {
        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(self.allocator);
        for (self.editor.tabs.tabs.items) |doc| {
            try paths.append(self.allocator, doc.path);
        }
        const layout: session_restore_mod.Layout = .{
            .active = self.editor.tabs.active,
            .editor_split = self.editor_split,
            .split_tab_index = self.split_tab_index,
            .editor_pane_secondary = self.editor_pane_focus == .secondary,
            .editor_scroll_y = self.editor_scroll_y,
            .editor_scroll_x = self.editor_scroll_x,
            .split_scroll_y = self.split_scroll_y,
            .split_scroll_x = self.split_scroll_x,
            .bottom_panel_mode = self.bottom_panel_mode,
            .sidebar_view = self.sidebar_view,
            .bottom_panel_height = self.bottom_panel_height,
        };
        try session_restore_mod.saveSession(self.allocator, self.io, self.workspace_root, paths.items, layout, &self.debug.breakpoints);
        try self.persistChatHistory();
        debug_recovery_mod.snapshotDebugState(self.allocator, self.io, self.workspace_root, &self.debug.breakpoints, &self.debug.watch_expressions) catch {};
    }

    pub fn persistChatHistory(self: *Workbench) !void {
        var stored: std.ArrayList(chat_persistence_mod.StoredMessage) = .empty;
        defer stored.deinit(self.allocator);
        for (self.agent_ui.chat_history.items) |msg| {
            const role: []const u8 = switch (msg.role) {
                .user => "user",
                .agent => "agent",
                .tool => "tool",
            };
            try stored.append(self.allocator, .{
                .role = role,
                .content = msg.content,
                .tool_index = msg.tool_index,
                .tool_kind = msg.tool_kind,
                .tool_content = msg.tool_content,
                .tool_running = msg.tool_running,
            });
        }
        try chat_persistence_mod.saveMessages(self.allocator, self.io, self.workspace_root, stored.items);
    }

    fn isNoiseChatMessage(content: []const u8) bool {
        return std.mem.eql(u8, content, "Forge workbench ready.") or
            std.mem.eql(u8, content, "Try Cmd+Shift+P for command palette.");
    }

    pub fn restoreChatHistory(self: *Workbench) !void {
        const loaded = try chat_persistence_mod.loadMessages(self.allocator, self.io, self.workspace_root);
        defer chat_persistence_mod.freeLoadedMessages(self.allocator, loaded);
        if (loaded.len == 0) return;

        const agent_panel_mod = @import("ui/agent/agent_panel.zig");

        for (self.agent_ui.chat_history.items) |msg| freeChatMessage(self.allocator, msg);
        self.agent_ui.chat_history.clearRetainingCapacity();

        var normalized_history = false;
        for (loaded) |msg| {
            const role: ChatRole = if (std.mem.eql(u8, msg.role, "user"))
                .user
            else if (std.mem.eql(u8, msg.role, "tool"))
                .tool
            else
                .agent;
            if (role != .tool and !agent_panel_mod.chatHasVisibleContent(msg.content)) continue;
            if (role != .tool and isNoiseChatMessage(msg.content)) continue;
            const compact_tool = if (role == .tool)
                try chat_persistence_mod.compactToolSummaryAlloc(self.allocator, msg.content)
            else
                null;
            defer if (compact_tool) |text| self.allocator.free(text);
            const fallback_tool = if (role == .tool and compact_tool != null and std.mem.eql(u8, compact_tool.?, "Tool"))
                chat_persistence_mod.fallbackToolSummary(msg.tool_kind)
            else
                null;
            if (compact_tool) |text| {
                if (!std.mem.eql(u8, text, msg.content) or fallback_tool != null) normalized_history = true;
            }
            const source = fallback_tool orelse compact_tool orelse msg.content;
            const owned = try self.allocator.dupeZ(u8, source);
            errdefer self.allocator.free(owned);
            const owned_kind = if (msg.tool_kind) |kind| try self.allocator.dupeZ(u8, kind) else null;
            errdefer if (owned_kind) |kind| self.allocator.free(kind);
            const owned_tool_content = if (msg.tool_content) |content| try self.allocator.dupeZ(u8, content) else null;
            errdefer if (owned_tool_content) |content| self.allocator.free(content);
            try self.agent_ui.chat_history.append(self.allocator, .{
                .role = role,
                .content = owned,
                .tool_index = msg.tool_index,
                .tool_kind = owned_kind,
                .tool_content = owned_tool_content,
                .tool_running = false,
            });
        }
        if (self.agent_ui.chat_history.items.len != loaded.len or normalized_history) {
            self.persistChatHistory() catch |err| self.logBackgroundError("Normalize chat history", err);
        }
        self.chat_history_revision += 1;
        self.invalidateChatLayout();
        self.chat_scroll_to_end_on_ready = true;
        self.chat_follow_stream = false;
    }

    pub fn clearChatHistory(self: *Workbench) !void {
        for (self.agent_ui.chat_history.items) |msg| freeChatMessage(self.allocator, msg);
        self.agent_ui.chat_history.clearRetainingCapacity();
        self.invalidateChatLayout();
    }

    pub fn restoreSessionTabs(self: *Workbench) !void {
        const loaded = try session_restore_mod.loadSession(self.allocator, self.io, self.workspace_root);
        defer session_restore_mod.freeLoadedSession(self.allocator, loaded.paths, loaded.breakpoint_lines);
        if (loaded.paths.len == 0) return;

        self.closeAllTabsWithLsp();
        self.lsp.sync.resetEntries();

        for (loaded.paths) |path| {
            self.openFile(path) catch {};
        }
        if (loaded.layout.active < self.editor.tabs.tabs.items.len) {
            try self.activateTab(loaded.layout.active);
        }

        self.editor_split = loaded.layout.editor_split;
        self.split_tab_index = if (loaded.layout.split_tab_index < self.editor.tabs.tabs.items.len)
            loaded.layout.split_tab_index
        else
            self.editor.tabs.active;
        self.editor_pane_focus = if (loaded.layout.editor_pane_secondary) .secondary else .primary;
        self.editor_scroll_y = loaded.layout.editor_scroll_y;
        self.editor_scroll_x = loaded.layout.editor_scroll_x;
        self.split_scroll_y = loaded.layout.split_scroll_y;
        self.split_scroll_x = loaded.layout.split_scroll_x;
        self.bottom_panel_mode = loaded.layout.bottom_panel_mode;
        self.sidebar_view = loaded.layout.sidebar_view;
        self.bottom_panel_height = loaded.layout.bottom_panel_height;

        try self.debug.breakpoints.restoreAll(loaded.breakpoint_lines);

        try self.setStatus("Session restored");
    }

    fn closeAllTabsWithLsp(self: *Workbench) void {
        while (self.editor.tabs.tabs.items.len > 0) {
            const idx = self.editor.tabs.tabs.items.len - 1;
            const path = self.editor.tabs.tabs.items[idx].path;
            self.lsp.sync.onDocumentClosed(path);
            self.editor.tabs.closeAt(idx);
        }
        self.editor_split = false;
        self.tab_scroll_x = 0;
    }

    pub fn openFile(self: *Workbench, path: []const u8) !void {
        const doc = try self.editor.tabs.openOrActivate(path);
        try workspace_io.loadDocument(self.io, self.workspace_root, doc);
        try self.explorer.select(path);
        self.focused_panel = .editor;
        self.syncTabScroll();
        self.warmLspForPath(path);
        try self.lsp.diagnostics.setActivePath(path);
        try self.recordNavigation(path);
        try self.events.publish(.{ .file_opened = path });
    }

    pub fn activateTab(self: *Workbench, index: usize) !void {
        if (index >= self.editor.tabs.tabs.items.len) return;
        self.editor.tabs.active = index;
        const doc = &self.editor.tabs.tabs.items[index];
        try self.explorer.select(doc.path);
        self.focused_panel = .editor;
        self.syncTabScroll();
        self.warmLspForPath(doc.path);
        try self.lsp.diagnostics.setActivePath(doc.path);
        if (doc.external_conflict) try self.openConflictDialog(doc.path);
        try self.recordNavigation(doc.path);
    }

    fn loadAiConfig(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot) !struct {
        provider: []const u8,
        model: ?[]const u8,
        ollama_url: ?[]const u8,
        openrouter_url: ?[]const u8,
        embedding_provider: ?[]const u8,
        embedding_model: ?[]const u8,
        embedding_url: ?[]const u8,
        mcp_enabled: bool,
        custom_models: ?[]const u8,
        custom_embedding_models: ?[]const u8,
        enable_hyde: bool,
    } {
        _ = root;
        const settings_abs = try workspace.global_store.joinHome(allocator, "settings.toml");
        defer allocator.free(settings_abs);
        const content = try workspace.global_store.readAbsoluteFile(allocator, io, settings_abs);
        defer allocator.free(content);
        const config = parseAiSettingsContent(content);
        const provider = try allocator.dupe(u8, config.ai_provider);
        errdefer allocator.free(provider);
        const model = if (config.ai_model) |value| try allocator.dupe(u8, value) else null;
        errdefer if (model) |owned| allocator.free(owned);
        const ollama_url = if (config.ai_ollama_url) |value| try allocator.dupe(u8, value) else null;
        errdefer if (ollama_url) |owned| allocator.free(owned);
        const openrouter_url = if (config.ai_openrouter_url) |value| try allocator.dupe(u8, value) else null;
        errdefer if (openrouter_url) |owned| allocator.free(owned);
        const embedding_provider = if (config.ai_embedding_provider) |value| try allocator.dupe(u8, value) else null;
        errdefer if (embedding_provider) |owned| allocator.free(owned);
        const embedding_model = if (config.ai_embedding_model) |value| try allocator.dupe(u8, value) else null;
        errdefer if (embedding_model) |owned| allocator.free(owned);
        const embedding_url = if (config.ai_embedding_url) |value| try allocator.dupe(u8, value) else null;
        errdefer if (embedding_url) |owned| allocator.free(owned);
        const custom_models = if (config.ai_custom_models) |value| try allocator.dupe(u8, value) else null;
        const custom_embedding_models = if (config.ai_custom_embedding_models) |value| try allocator.dupe(u8, value) else null;
        errdefer if (custom_models) |owned| allocator.free(owned);
        return .{
            .provider = provider,
            .model = model,
            .ollama_url = ollama_url,
            .openrouter_url = openrouter_url,
            .embedding_provider = embedding_provider,
            .embedding_model = embedding_model,
            .embedding_url = embedding_url,
            .mcp_enabled = config.ai_mcp_enabled,
            .custom_models = custom_models,
            .custom_embedding_models = custom_embedding_models,
            .enable_hyde = config.ai_enable_hyde,
        };
    }

    const AiSettings = struct {
        ai_provider: []const u8 = "auto",
        ai_model: ?[]const u8 = null,
        ai_ollama_url: ?[]const u8 = null,
        ai_openrouter_url: ?[]const u8 = null,
        ai_custom_models: ?[]const u8 = null,
        ai_custom_embedding_models: ?[]const u8 = null,
        ai_embedding_provider: ?[]const u8 = null,
        ai_embedding_model: ?[]const u8 = null,
        ai_embedding_url: ?[]const u8 = null,
        ai_mcp_enabled: bool = true,
        ai_enable_hyde: bool = false,
    };

    fn parseAiSettingsContent(content: []const u8) AiSettings {
        var config: AiSettings = .{};
        var section: []const u8 = "";
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |raw_line| {
            const without_comment = if (std.mem.indexOfScalar(u8, raw_line, '#')) |index|
                raw_line[0..index]
            else
                raw_line;
            const line = std.mem.trim(u8, &std.ascii.whitespace, without_comment);
            if (line.len == 0) continue;
            if (line[0] == '[') {
                if (line.len < 3 or line[line.len - 1] != ']') continue;
                section = std.mem.trim(u8, &std.ascii.whitespace, line[1 .. line.len - 1]);
                continue;
            }
            if (!std.mem.eql(u8, section, "ai")) continue;

            const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, &std.ascii.whitespace, line[0..equals]);
            const value = std.mem.trim(u8, &std.ascii.whitespace, line[equals + 1 ..]);

            if (std.mem.eql(u8, key, "provider")) {
                config.ai_provider = parseTomlString(value) orelse config.ai_provider;
            } else if (std.mem.eql(u8, key, "model")) {
                config.ai_model = parseTomlString(value) orelse config.ai_model;
            } else if (std.mem.eql(u8, key, "ollama_url")) {
                config.ai_ollama_url = parseTomlString(value) orelse config.ai_ollama_url;
            } else if (std.mem.eql(u8, key, "openrouter_url")) {
                config.ai_openrouter_url = parseTomlString(value) orelse config.ai_openrouter_url;
            } else if (std.mem.eql(u8, key, "embedding_provider")) {
                config.ai_embedding_provider = parseTomlString(value) orelse config.ai_embedding_provider;
            } else if (std.mem.eql(u8, key, "embedding_model")) {
                config.ai_embedding_model = parseTomlString(value) orelse config.ai_embedding_model;
            } else if (std.mem.eql(u8, key, "embedding_url")) {
                config.ai_embedding_url = parseTomlString(value) orelse config.ai_embedding_url;
            } else if (std.mem.eql(u8, key, "custom_models")) {
                config.ai_custom_models = parseTomlString(value) orelse config.ai_custom_models;
            } else if (std.mem.eql(u8, key, "custom_embedding_models")) {
                config.ai_custom_embedding_models = parseTomlString(value) orelse config.ai_custom_embedding_models;
            } else if (std.mem.eql(u8, key, "mcp")) {
                config.ai_mcp_enabled = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1");
            } else if (std.mem.eql(u8, key, "enable_hyde")) {
                config.ai_enable_hyde = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1");
            }
        }
        return config;
    }

    fn parseTomlString(value: []const u8) ?[]const u8 {
        if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return null;
        return value[1 .. value.len - 1];
    }

    pub fn openConflictDialog(self: *Workbench, path: []const u8) !void {
        if (self.conflict_path) |existing| {
            if (std.mem.eql(u8, existing, path)) return;
            self.allocator.free(existing);
        }
        self.conflict_path = try self.allocator.dupe(u8, path);
        self.previous_focus = self.focused_panel;
        self.focused_panel = .conflict;
    }

    pub fn closeConflictDialog(self: *Workbench) !void {
        if (self.conflict_path) |path| self.allocator.free(path);
        self.conflict_path = null;
        if (self.focused_panel == .conflict) self.focused_panel = self.previous_focus;
    }

    pub fn tickFrame(self: *Workbench, dt: f32) !void {
        self.workspace_symbol_picker.tick(dt);
        try @import("workbench/agent_ops.zig").flushAgentUi(self);
        _ = try @import("workbench/search_ops.zig").flushSearchResults(self);
        if (try @import("workbench/git_ops.zig").flushGitStatusRefresh(self)) {
            if (self.bottom_panel_mode == .terminal) self.updateTerminalPrompt() catch {};
        }

        if (self.agent_ui.session.worker_running) {
            var win_w: f32 = 0;
            var win_h: f32 = 0;
            renderer.Renderer.getWindowSize(&win_w, &win_h);
            const was_near_end = self.chat_scroll_y >= self.chat_layout.max_scroll - 48;
            @import("workbench/chat_layout.zig").ensure(self, win_h);
            if (self.chat_follow_stream or was_near_end) {
                self.chat_scroll_y = self.chat_layout.max_scroll;
            } else {
                self.chat_scroll_y = std.math.clamp(self.chat_scroll_y, 0, self.chat_layout.max_scroll);
            }
        }

        self.conflict_check_cooldown -= dt;
        if (self.conflict_check_cooldown <= 0) {
            self.conflict_check_cooldown = 5.0;
            if (self.focused_panel != .palette and self.focused_panel != .recovery and self.focused_panel != .conflict) {
                self.conflict_full_check_cooldown -= 5.0;
                const full_check = self.conflict_full_check_cooldown <= 0;
                if (full_check) self.conflict_full_check_cooldown = 30.0;
                if (full_check) {
                    for (self.editor.tabs.tabs.items) |*doc| {
                        try doc.checkExternalConflict(self.io, self.workspace_root);
                        if (doc.external_conflict and !doc.isDirty()) {
                            try @import("workspace_io.zig").loadDocument(self.io, self.workspace_root, doc);
                        }
                    }
                } else if (self.editor.tabs.activeDoc()) |doc| {
                    try doc.checkExternalConflict(self.io, self.workspace_root);
                    if (doc.external_conflict and !doc.isDirty()) {
                        try @import("workspace_io.zig").loadDocument(self.io, self.workspace_root, doc);
                    }
                }
                if (self.editor.tabs.activeDoc()) |active_doc| {
                    if (active_doc.external_conflict) try self.openConflictDialog(active_doc.path);
                }
            }
        }

        self.lsp.diagnostics.tick(dt, self.editor.tabs.activeDoc(), self.agent_ui.session.worker_running);
        self.lsp.hover.tick(dt);
        @import("workbench/editor_ops.zig").tickGhostCompletion(self, dt);

        if (self.explorer_boot_pending) {
            self.explorer_boot_pending = false;
            self.explorer.rebuild(self.io, self.workspace_root) catch {};
        }

        if (self.terminal_boot_pending) {
            self.terminal_boot_pending = false;
            self.activeTerminal().ensureStarted() catch {};
            self.syncTerminalSize();
            self.updateTerminalPrompt() catch {};
            @import("workbench/git_ops.zig").scheduleGitStatusRefresh(self);
        }

        if (self.bottom_panel_mode == .terminal) {
            self.terminal_prompt_refresh_cooldown -= dt;
            if (self.terminal_prompt_refresh_cooldown <= 0) {
                self.terminal_prompt_refresh_cooldown = 3.0;
                self.updateTerminalPrompt() catch {};
            }
            self.syncTerminalSize();
        }

        self.git_refresh_cooldown -= dt;
        if (self.git_refresh_cooldown <= 0) {
            self.git_refresh_cooldown = 3.0;
            @import("workbench/git_ops.zig").scheduleGitStatusRefresh(self);
        }

        if (self.git.push_done) {
            self.git.push_done = false;
            self.git.push_running = false;
            try @import("workbench/git_ops.zig").refreshGitStatus(self);
        }
        if (self.git.pull_done) {
            self.git.pull_done = false;
            self.git.pull_running = false;
            try @import("workbench/git_ops.zig").refreshGitStatus(self);
        }

        if (self.git.push_running or self.git.pull_running) {
            self.setStatus("Git operation running...") catch {};
            self.git.sync_icon_angle += dt * 360.0;
            if (self.git.sync_icon_angle >= 360.0) {
                self.git.sync_icon_angle -= 360.0;
            }
            @import("forge-renderer").Renderer.requestRedraw();
        } else {
            self.git.sync_icon_angle = 0;
        }

        self.lsp.sync.tick(dt, &self.editor.tabs);

        // P0-4: Recompute fold ranges when active buffer changes.
        if (self.editor.fold_dirty) {
            if (self.editor.tabs.activeDoc()) |doc| {
                self.editor.fold_controller.computeRanges(&doc.buffer) catch {};
                self.editor.fold_dirty = false;
            }
        }

        // P0-7: Lazy-load launch configs on first tick.
        if (self.launch_configs.len == 0) {
            if (launch_config_mod.loadFromWorkspace(self.allocator, self.io, self.workspace_path)) |configs| {
                self.launch_configs = configs;
            } else |_| {}
        }

        // P1-4: Tick notifications (auto-expire after their duration).
        self.notifications.tick(dt);

        // P1-1: Refresh document symbols for active file when it changes.
        // We do this at most every ~0.5s to avoid hammering the LSP.
        self.lsp.outline_refresh_cooldown -= dt;
        if (self.lsp.outline_refresh_cooldown <= 0) {
            self.lsp.outline_refresh_cooldown = 0.5;
            self.refreshOutlineSymbols() catch {};
        }
    }

    pub fn syncTerminalSize(self: *Workbench) void {
        if (!self.activeTerminal().isActive()) return;
        if (self.bottom_panel_mode != .terminal) return;

        const renderer_mod = @import("forge-renderer");
        const panel_scroll = @import("ui/core/panel_scroll.zig");
        const terminal_panel = @import("ui/panel/terminal_panel.zig");

        var w: f32 = 0;
        var h: f32 = 0;
        renderer_mod.Renderer.getWindowSize(&w, &h);
        const geo = self.layoutGeometry(w, h);
        const viewport = panel_scroll.bottomViewportHeight(geo.task_panel_h) - terminal_panel.session_tab_h;
        const char_w = @max(1.0, renderer_mod.Renderer.measureText("M", terminal_panel.font_size));
        const cols: u16 = @intFromFloat(@floor(@max(10.0, (geo.editor_w - terminal_panel.text_inset_x * 2) / char_w)));
        const rows: u16 = @intFromFloat(@floor(@max(3.0, viewport / terminal_panel.line_h)));
        self.activeTerminal().resize(cols, rows);
    }

    pub fn goToDefinition(self: *Workbench) !void {
        const doc = self.editor.tabs.activeDoc() orelse return;
        const symbol = @import("workbench/editor_ops.zig").wordAtCursor(&doc.buffer);
        if (symbol.len == 0) {
            std.debug.print("[ide][definition] no symbol at cursor path={s} row={d} col={d}\n", .{ doc.path, doc.buffer.cursor.row, doc.buffer.cursor.col });
            try self.setStatus("No symbol at cursor");
            return;
        }
        const symbol_owned = try self.allocator.dupe(u8, symbol);
        defer self.allocator.free(symbol_owned);
        std.debug.print("[ide][definition] path={s} symbol={s} row={d} col={d}\n", .{ doc.path, symbol_owned, doc.buffer.cursor.row, doc.buffer.cursor.col });

        const owned = try self.lsp.registry.copyMatchForPath(self.allocator, doc.path);
        if (owned) |config| {
            defer lsp.Registry.freeConfig(self.allocator, config);
            std.debug.print("[ide][definition] lsp language={s} server={s} args={s}\n", .{ config.language_id, config.server, config.args });

            const uri = try @import("workbench/editor_ops.zig").lspSyncDocument(self, doc);
            defer self.allocator.free(uri);

            const line: u32 = @intCast(doc.buffer.cursor.row);
            const character: u32 = @intCast(doc.buffer.cursor.col);
            const def_req = try lsp.navigation.buildDefinitionRequest(
                self.allocator,
                88,
                uri,
                line,
                character,
            );
            defer self.allocator.free(def_req);

            var response_buf: [65536]u8 = undefined;
            if (self.lsp.proxy.request(config.language_id, def_req, &response_buf, response_buf.len)) |len| {
                std.debug.print("[ide][definition] lsp response bytes={d}\n", .{len});
                var location = try lsp.navigation.parseDefinitionResponse(self.allocator, response_buf[0..len]);
                if (location) |*loc| {
                    defer loc.deinit(self.allocator);
                    std.debug.print("[ide][definition] lsp hit uri={s} line={d} char={d}\n", .{ loc.uri, loc.line, loc.character });
                    try @import("workbench/editor_ops.zig").gotoLocation(self, loc.*);
                    try self.setStatus("Go to definition");
                    return;
                }
                std.debug.print("[ide][definition] lsp no location response={s}\n", .{response_buf[0..@min(len, 512)]});
            } else |err| {
                std.debug.print("[ide][definition] lsp request failed error={}\n", .{err});
            }
        } else {
            std.debug.print("[ide][definition] no lsp config for path={s}\n", .{doc.path});
        }

        if (try @import("workbench/editor_ops.zig").gotoIndexedDefinition(self, symbol_owned)) {
            std.debug.print("[ide][definition] index hit symbol={s}\n", .{symbol_owned});
            try self.setStatus("Go to definition (index)");
            return;
        }
        std.debug.print("[ide][definition] index miss symbol={s}\n", .{symbol_owned});
        try self.setStatus("No definition found");
    }

    pub fn restoreRecoverySnapshots(self: *Workbench) !void {
        const paths = try recovery_mod.listRecoveryFiles(self.allocator, self.io, self.workspace_root);
        defer {
            for (paths) |path| self.allocator.free(path);
            self.allocator.free(paths);
        }

        for (paths) |snap_path| {
            const snap = try recovery_mod.readSnapshot(self.allocator, self.io, self.workspace_root, snap_path);
            defer self.allocator.free(snap.path);
            defer self.allocator.free(snap.content);

            const doc = try self.editor.tabs.openOrActivate(snap.path);
            try doc.buffer.loadFromSlice(snap.content);
            doc.external_conflict = false;
            doc.saved_hash = 0;
            doc.disk_hash = 0;

            try recovery_mod.deleteSnapshot(self.allocator, self.io, self.workspace_root, snap_path);
        }
    }

    pub fn discardRecoverySnapshots(self: *Workbench) !void {
        const paths = try recovery_mod.listRecoveryFiles(self.allocator, self.io, self.workspace_root);
        defer {
            for (paths) |path| self.allocator.free(path);
            self.allocator.free(paths);
        }
        for (paths) |snap_path| {
            try recovery_mod.deleteSnapshot(self.allocator, self.io, self.workspace_root, snap_path);
        }
    }
};

test "workbench opens workspace and loads extensions" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var wb: Workbench = undefined;
    try Workbench.init(&wb, allocator, io, ".", "forge-ide", null);
    defer wb.deinit();

    try std.testing.expect(wb.extension_host.extensionCount() >= 1);
    try std.testing.expect(wb.activeBuffer() != null);
    try std.testing.expect(wb.palette.entries.len >= 12);
}

test "ai settings parser ignores user settings sections and keeps latest ai values" {
    const content =
        \\[theme]
        \\font_size = 14
        \\
        \\[ai]
        \\provider = "ollama"
        \\model = "qwen3.5:35b"
        \\
        \\[editor]
        \\word_wrap = true
        \\
        \\[ai_panel]
        \\font_size = 16.0
        \\
        \\[ai]
        \\provider = "openrouter"
        \\model = "nvidia/nemotron-3-super-120b-a12b:free"
        \\embedding_provider = "openrouter"
        \\
    ;

    const parsed = Workbench.parseAiSettingsContent(content);
    try std.testing.expectEqualStrings("openrouter", parsed.ai_provider);
    try std.testing.expectEqualStrings("nvidia/nemotron-3-super-120b-a12b:free", parsed.ai_model.?);
    try std.testing.expectEqualStrings("openrouter", parsed.ai_embedding_provider.?);
}
