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
const search_engine = @import("search/engine.zig");
const git_status_mod = @import("git/status.zig");
const git_diff_mod = @import("git/diff.zig");
const diagnostics_store_mod = @import("workbench/diagnostics_store.zig");
const completion_store_mod = @import("workbench/completion_store.zig");
const hover_store_mod = @import("workbench/hover_store.zig");
const references_store_mod = @import("workbench/references_store.zig");
const terminal_session_mod = @import("workbench/terminal_session.zig");
const terminal_group_mod = @import("workbench/terminal_group.zig");
const lsp_sync_mod = @import("workbench/lsp_sync.zig");
const rename_preview_mod = @import("workbench/rename_preview.zig");
const debug_lldb_session_mod = @import("workbench/debug_lldb_session.zig");
const debug_stop_mod = @import("workbench/debug_stop.zig");
const debug_variables_mod = @import("workbench/debug_variables.zig");
const debug_callstack_mod = @import("workbench/debug_callstack.zig");
const recent_workspaces_mod = @import("workbench/recent_workspaces.zig");
const debug_console_mod = @import("workbench/debug_console.zig");
const breakpoints_mod = @import("workbench/breakpoints.zig");
const workspace_symbol_picker_mod = @import("workbench/workspace_symbol_picker.zig");
const editor_find_mod = @import("workbench/editor_find.zig");
const settings_mod = @import("workbench/settings.zig");
const ai_config_io = @import("workbench/ai_config_io.zig");
const navigation_history_mod = @import("workbench/navigation_history.zig");
const session_restore_mod = @import("workbench/session_restore.zig");
const chat_persistence_mod = @import("workbench/chat_persistence.zig");
const agent_ui_queue_mod = @import("workbench/agent_ui_queue.zig");
const ghost_completion_mod = @import("workbench/ghost_completion.zig");

pub const PanelFocus = enum { editor, agent, explorer, search, git, run, extensions, ai, ai_settings, proposal_review, terminal, palette, conflict, recovery, find, goto_line, rename };
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

pub const Workbench = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
    workspace_name: []const u8,
    workspace_root: workspace.WorkspaceRoot,
    tabs: editor.TabGroup,
    explorer: explorer_tree.Tree,
    extension_host: plugin.Host,
    keybindings: keybindings_mod.Registry,
    lsp_registry: lsp.Registry,
    lsp_proxy: lsp.Proxy,
    marketplace_catalog: ?plugin.MarketplaceCatalog = null,
    extensions_panel_mode: @import("ui/sidebar/extensions_panel.zig").PanelMode = .installed,
    extensions_filter: [128]u8 = undefined,
    extensions_filter_len: usize = 0,
    extensions_detail_index: ?usize = null,
    bottom_panel_mode: commands_mod.BottomPanelMode = .output,
    search_buffer: editor.Buffer,
    search_results: ?search_engine.ResultSet = null,
    search_scroll_y: f32 = 0,
    git_status: ?git_status_mod.Status = null,
    git_scroll_y: f32 = 0,
    run_scroll_y: f32 = 0,
    breakpoints: breakpoints_mod.Store,
    debug_console: debug_console_mod.DebugConsole,
    debug_lldb: debug_lldb_session_mod.Session,
    debug_stop_path: ?[]const u8 = null,
    debug_stop_line: ?usize = null,
    debug_variables: debug_variables_mod.Store,
    debug_callstack: debug_callstack_mod.Store,
    recent_workspace_paths: []const []const u8 = &.{},
    terminals: terminal_group_mod.Group,
    lsp_sync: lsp_sync_mod.Store,
    diagnostics: diagnostics_store_mod.Store,
    completions: completion_store_mod.Store,
    hover: hover_store_mod.Store,
    references: references_store_mod.Store,
    rename_preview: rename_preview_mod.Store,
    events: kernel.EventBus(Event),
    palette: palette_mod.Palette,
    workspace_symbol_picker: workspace_symbol_picker_mod.Picker,
    task_output: task_output_mod.TaskOutput,
    agent: agent_session.Session,
    agent_ui_queue: agent_ui_queue_mod.Queue = .{},
    agent_cancel_source: ?*kernel.cancellation.CancellationTokenSource = null,
    scope_picker_paths: std.ArrayList([]const u8),
    scope_picker_filtered: std.ArrayList(usize),
    prompt_buffer: editor.Buffer,
    rename_buffer: editor.Buffer,
    // Ghost text / inline AI completion
    ghost: ghost_completion_mod.Store,
    chat_history: std.ArrayList(ChatMessage),
    focused_panel: PanelFocus = .editor,
    previous_focus: PanelFocus = .editor,
    renaming: bool = false,
    agent_panel_width: f32 = 380.0,
    explorer_panel_width: f32 = 250.0,
    bottom_panel_height: f32 = @import("ui/core/layout.zig").task_panel_height,
    sidebar_visible: bool = true,
    bottom_panel_visible: bool = true,
    agent_panel_visible: bool = true,
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
    explorer_scroll_y: f32 = 0,
    extensions_scroll_y: f32 = 0,
    ai_settings_scroll_y: f32 = 0,
    ai_settings_open: bool = false,
    proposal_review_open: bool = false,
    proposal_review_scroll_y: f32 = 0,
    proposal_review_file_index: usize = 0,
    ai_mcp_status: ?[]const u8 = null,
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
    terminal_prompt_refresh_cooldown: f32 = 3.0,
    terminal_boot_pending: bool = false,
    explorer_boot_pending: bool = false,
    explorer_root_expanded: bool = true,
    theme: workspace.Theme = workspace.Theme.darkDefault(),
    active_extension_theme: []const u8 = "",
    find_bar: editor_find_mod.FindBar,
    goto_bar: editor_find_mod.GotoBar,
    rename_bar: editor_find_mod.RenameBar,
    user_settings: settings_mod.Settings = .{},
    ide_launcher: []const u8 = "forge-ide",
    environ_map: ?*const std.process.Environ.Map = null,
    ai_provider: []const u8 = "auto",
    ai_model: ?[]const u8 = null,
    ai_ollama_url: ?[]const u8 = null,
    ai_openrouter_url: ?[]const u8 = null,
    ai_embedding_provider: ?[]const u8 = null,
    ai_embedding_model: ?[]const u8 = null,
    ai_embedding_url: ?[]const u8 = null,
    ai_mcp_enabled: bool = true,
    ai_models: []const @import("ui/agent/agent_composer.zig").ModelOption = &.{},

    git_commit_msg: editor.Buffer,
    git_staged_collapsed: bool = false,
    git_changes_collapsed: bool = false,

    code_scroll_x: std.AutoHashMap(u64, CodeScrollState),
    rendered_code_blocks: std.ArrayList(RenderedCodeBlock),
    wrap_cache: std.AutoHashMap(u64, *WrapCache),
    max_line_len_cache: std.AutoHashMap(u64, MaxLineLenCache),

    bracket_match_cache: BracketMatchCache = .{},
    review_hunks_cache: ReviewHunksCache = .{},

    pub const MaxLineLenCache = struct { revision: u64, len: usize };

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

    pub const RenderedCodeBlock = struct {
        hash: u64,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
    };

    pub const WrapCache = @import("ui/editor/word_wrap.zig").WrapCache;

    pub fn init(self: *Workbench, allocator: std.mem.Allocator, io: std.Io, workspace_path: []const u8, ide_launcher: []const u8, environ_map: ?*const std.process.Environ.Map) !void {
        var root = try workspace.WorkspaceRoot.open(io, workspace_path);
        errdefer root.close(io);
        ai.index_warm.scheduleBackground(allocator, io, environ_map, root, workspace_path);

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        var final_path: []const u8 = workspace_path;
        if (std.mem.eql(u8, workspace_path, ".")) {
            if (std.process.currentPath(io, &buf)) |len| {
                final_path = buf[0..len];
            } else |_| {}
        }

        var normalized_path = final_path;
        while (normalized_path.len > 1 and (normalized_path[normalized_path.len - 1] == '/' or normalized_path[normalized_path.len - 1] == '\\')) {
            normalized_path = normalized_path[0 .. normalized_path.len - 1];
        }
        var name = std.fs.path.basename(normalized_path);
        if (name.len == 0 or std.mem.eql(u8, name, ".")) {
            name = "WORKSPACE";
        }
        const workspace_name = try allocator.dupe(u8, name);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .workspace_path = try allocator.dupe(u8, workspace_path),
            .workspace_name = workspace_name,
            .workspace_root = root,
            .tabs = editor.TabGroup.init(allocator),
            .explorer = explorer_tree.Tree.init(allocator),
            .extension_host = plugin.Host.init(allocator, io),
            .keybindings = keybindings_mod.Registry.init(allocator),
            .nav_history = navigation_history_mod.History.init(allocator),
            .lsp_registry = lsp.Registry.init(allocator),
            .lsp_proxy = try lsp.Proxy.init(allocator, io, workspace_path),
            .events = kernel.EventBus(Event).init(allocator),
            .palette = try palette_mod.Palette.init(allocator),
            .workspace_symbol_picker = try workspace_symbol_picker_mod.Picker.init(allocator, &self.lsp_proxy),
            .task_output = task_output_mod.TaskOutput.init(allocator, io),
            .agent = agent_session.Session.init(allocator, io),
            .scope_picker_paths = .empty,
            .scope_picker_filtered = .empty,
            .prompt_buffer = try editor.Buffer.init(allocator),
            .rename_buffer = try editor.Buffer.init(allocator),
            .search_buffer = try editor.Buffer.init(allocator),
            .git_commit_msg = try editor.Buffer.init(allocator),
            .chat_history = .empty,
            .breakpoints = breakpoints_mod.Store.init(allocator),
            .debug_console = debug_console_mod.DebugConsole.init(allocator, io),
            .debug_variables = debug_variables_mod.Store.init(allocator),
            .debug_callstack = debug_callstack_mod.Store.init(allocator),
            .debug_lldb = undefined,
            .find_bar = try editor_find_mod.FindBar.init(allocator),
            .goto_bar = try editor_find_mod.GotoBar.init(allocator),
            .rename_bar = try editor_find_mod.RenameBar.init(allocator),
            .ide_launcher = try allocator.dupe(u8, ide_launcher),
            .environ_map = environ_map,
            .ai_provider = try allocator.dupe(u8, "auto"),
            .ai_ollama_url = null,
            .ai_openrouter_url = null,
            .ai_embedding_provider = null,
            .ai_embedding_model = null,
            .ai_embedding_url = null,
            .terminals = undefined,
            .lsp_sync = undefined,
            .diagnostics = undefined,
            .completions = undefined,
            .hover = undefined,
            .references = references_store_mod.Store.init(allocator),
            .rename_preview = rename_preview_mod.Store.init(allocator),
            .code_scroll_x = std.AutoHashMap(u64, CodeScrollState).init(allocator),
            .rendered_code_blocks = .empty,
            .wrap_cache = std.AutoHashMap(u64, *WrapCache).init(allocator),
            .max_line_len_cache = std.AutoHashMap(u64, MaxLineLenCache).init(allocator),
            // Ghost completion: will be fully initialized after settings load below.
            .ghost = ghost_completion_mod.Store.init(allocator, io, .{}),
        };
        errdefer self.deinit();

        self.terminals = try terminal_group_mod.Group.init(allocator, io, self.workspace_path);
        self.lsp_sync = lsp_sync_mod.Store.init(allocator, self.workspace_path, &self.lsp_proxy, &self.lsp_registry);
        self.diagnostics = diagnostics_store_mod.Store.init(allocator, io, self.workspace_path, self.workspace_root, &self.lsp_proxy, &self.lsp_registry);
        self.completions = completion_store_mod.Store.init(allocator, io, self.workspace_path, self.workspace_root, &self.lsp_proxy, &self.lsp_registry);
        self.hover = hover_store_mod.Store.init(allocator, self.workspace_path, &self.lsp_proxy, &self.lsp_registry);
        try self.lsp_proxy.start();
        workspace.recovery.recoverPending(allocator, io, self.workspace_root) catch {};

        try self.extension_host.registerBuiltin(&builtin_ext.hello_extension);
        try self.extension_host.registerBuiltin(&builtin_ext.lsp_extension);
        self.extension_host.setHostCallbacks(wasm_bridge.hostCallbacks());
        self.marketplace_catalog = plugin.marketplace.loadCatalog(allocator, io, root) catch null;
        try self.ensureBundledExtensions();
        try self.extension_host.discoverWorkspace(self.workspace_root);
        try self.extension_host.activateAll();
        try self.syncContributions();
        try self.palette.addExtensionCommands(&self.extension_host);
        try recent_workspaces_mod.record(allocator, io, final_path);
        try self.refreshRecentWorkspaces();

        self.theme = try @import("theme_loader.zig").loadTheme(allocator, io, root, &self.extension_host);
        self.user_settings = settings_mod.load(allocator, io, root) catch .{};
        settings_mod.applyToTheme(self.user_settings, &self.theme);
        @import("theme_loader.zig").syncFontMetrics(&self.theme);
        @import("theme_loader.zig").applyToRenderer(&self.theme);
        // Re-initialize ghost completion with config read from user settings.
        self.ghost.deinit();
        self.ghost = ghost_completion_mod.Store.init(allocator, io, .{
            .provider = self.user_settings.ghost_provider,
            .model = self.user_settings.ghost_model,
            .ollama_url = self.user_settings.ghost_ollama_url,
            .enabled = self.user_settings.ghost_enabled,
        });

        if (loadAiConfig(allocator, io, root)) |cfg| {
            self.allocator.free(self.ai_provider);
            self.ai_provider = cfg.provider;
            if (self.ai_model) |model| self.allocator.free(model);
            self.ai_model = cfg.model;
            if (self.ai_ollama_url) |url| self.allocator.free(url);
            self.ai_ollama_url = cfg.ollama_url;
            if (self.ai_openrouter_url) |url| self.allocator.free(url);
            self.ai_openrouter_url = cfg.openrouter_url;
            if (self.ai_embedding_provider) |provider| self.allocator.free(provider);
            self.ai_embedding_provider = cfg.embedding_provider;
            if (self.ai_embedding_model) |model| self.allocator.free(model);
            self.ai_embedding_model = cfg.embedding_model;
            if (self.ai_embedding_url) |url| self.allocator.free(url);
            self.ai_embedding_url = cfg.embedding_url;
            self.ai_mcp_enabled = cfg.mcp_enabled;
            var models_parsed = false;
            if (cfg.custom_models) |custom_models_str| {
                defer self.allocator.free(custom_models_str);
                if (@import("ui/agent/agent_composer.zig").parseCustomModels(self.allocator, custom_models_str)) |models_list| {
                    self.ai_models = models_list;
                    models_parsed = true;
                } else |err| {
                    std.debug.print("parseCustomModels error: {}\n", .{err});
                }
            }
            if (!models_parsed) {
                if (@import("ui/agent/agent_composer.zig").parseCustomModels(self.allocator, @import("ui/agent/agent_composer.zig").default_models_str)) |models_list| {
                    self.ai_models = models_list;
                } else |err| {
                    std.debug.print("parseCustomModels default error: {}\n", .{err});
                }
            }
        } else |err| {
            std.debug.print("global_store.loadConfig error: {}\n", .{err});
            if (@import("ui/agent/agent_composer.zig").parseCustomModels(self.allocator, @import("ui/agent/agent_composer.zig").default_models_str)) |models_list| {
                self.ai_models = models_list;
            } else |err2| {
                std.debug.print("parseCustomModels default error 2: {}\n", .{err2});
            }
        }
        std.debug.print("wb.ai_models.len = {}\n", .{self.ai_models.len});

        self.explorer_boot_pending = true;
        try self.restoreSessionTabs();
        if (self.tabs.tabs.items.len == 0) {
            try self.dispatch(.{ .open_file = "apps/forge-ide/src/main.zig" });
        }
        self.recovery_count = recovery_mod.countRecoveryFiles(allocator, io, root) catch 0;
        if (self.recovery_count > 0) {
            self.previous_focus = .editor;
            self.focused_panel = .recovery;
        }
        agent_workflow.refreshRunHistory(&self.agentHost()) catch {};
        agent_workflow.scanResumableSession(&self.agentHost());
        try self.restoreChatHistory();
        self.debug_lldb = .{
            .allocator = allocator,
            .on_line = onDebugLine,
            .on_finished = onDebugLldbFinished,
            .context = null,
        };
    }

    pub fn deinit(self: *Workbench) void {
        self.persistSessionState() catch {};
        recovery_mod.snapshotDirtyDocs(self.allocator, self.io, self.workspace_root, &self.tabs) catch {};
        if (self.conflict_path) |path| self.allocator.free(path);
        if (self.status_message.len > 0) self.allocator.free(self.status_message);
        for (self.chat_history.items) |msg| freeChatMessage(self.allocator, msg);
        self.chat_history.deinit(self.allocator);
        self.chat_layout.deinit(self.allocator);
        self.rename_buffer.deinit();
        self.search_buffer.deinit();
        self.git_commit_msg.deinit();
        if (self.search_results) |*results| results.deinit(self.allocator);
        if (self.git_status) |*status| status.deinit(self.allocator);
        if (self.debug_stop_path) |path| self.allocator.free(path);
        self.debug_variables.deinit();
        self.debug_callstack.deinit();
        recent_workspaces_mod.freePaths(self.allocator, self.recent_workspace_paths);
        self.breakpoints.deinit();
        self.debug_console.deinit();
        self.debug_lldb.deinit();
        self.terminals.deinit();
        self.lsp_sync.deinit();
        self.diagnostics.deinit();
        self.completions.deinit();
        self.ghost.deinit();
        self.code_scroll_x.deinit();
        self.rendered_code_blocks.deinit(self.allocator);

        var wrap_cache_iter = self.wrap_cache.iterator();
        while (wrap_cache_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.wrap_cache.deinit();
        self.max_line_len_cache.deinit();

        self.hover.deinit();
        self.references.deinit();
        self.rename_preview.deinit();
        self.events.deinit();
        self.palette.deinit();
        self.workspace_symbol_picker.deinit();
        self.lsp_proxy.deinit();
        self.agent_ui_queue.deinit(self.allocator);
        self.prompt_buffer.deinit();
        self.task_output.deinit();
        self.agent.deinit();
        self.clearScopePickerPaths();
        self.scope_picker_paths.deinit(self.allocator);
        self.scope_picker_filtered.deinit(self.allocator);
        self.find_bar.deinit();
        self.goto_bar.deinit();
        self.rename_bar.deinit();
        self.user_settings.deinit(self.allocator);
        self.allocator.free(self.ai_provider);
        if (self.ai_model) |model| self.allocator.free(model);
        if (self.ai_ollama_url) |url| self.allocator.free(url);
        if (self.ai_openrouter_url) |url| self.allocator.free(url);
        if (self.ai_embedding_provider) |provider| self.allocator.free(provider);
        if (self.ai_embedding_model) |model| self.allocator.free(model);
        if (self.ai_embedding_url) |url| self.allocator.free(url);
        if (self.ai_models.len > 0) {
            for (self.ai_models) |opt| {
                self.allocator.free(opt.id);
                self.allocator.free(opt.label);
                self.allocator.free(opt.provider);
            }
            self.allocator.free(self.ai_models);
        }
        if (self.ai_mcp_status) |status| self.allocator.free(status);
        self.allocator.free(self.ide_launcher);
        self.palette.deinit();
        self.theme.deinit();
        if (self.active_extension_theme.len > 0) self.allocator.free(self.active_extension_theme);
        if (self.marketplace_catalog) |*catalog| catalog.deinit(self.allocator);
        self.nav_history.deinit();
        self.keybindings.deinit();
        self.lsp_registry.deinit(self.allocator);
        self.lsp_proxy.deinit();
        self.events.deinit();
        self.extension_host.deinit();
        self.explorer.deinit();
        self.tabs.deinit();
        self.workspace_root.close(self.io);
        self.allocator.free(self.workspace_path);
    }

    pub fn layoutGeometry(self: *const Workbench, window_w: f32, window_h: f32) @import("ui/core/layout.zig").Geometry {
        return @import("ui/core/layout.zig").compute(
            self.shell_mode,
            window_w,
            window_h,
            self.explorer_panel_width,
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
            .open_settings => try self.openAiSettings(),
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
        for (self.tabs.tabs.items, 0..) |doc, i| {
            if (std.mem.eql(u8, doc.path, entry.path)) {
                try self.activateTab(i);
                return;
            }
        }
        try self.openFile(entry.path);
    }

    fn recordNavigation(self: *Workbench, path: []const u8) !void {
        try self.nav_history.record(path, self.tabs.active);
    }

    pub fn dispatch(self: *Workbench, command: Command) anyerror!void {
        return @import("workbench/dispatch.zig").dispatch(self, command);
    }

    fn clearScopePickerPaths(self: *Workbench) void {
        @import("workbench/agent_ops.zig").clearScopePickerPaths(self);
    }

    pub fn openScopePicker(self: *Workbench) !void {
        return @import("workbench/agent_ops.zig").openScopePicker(self);
    }

    pub fn applyScopePickerFilter(self: *Workbench) !void {
        return @import("workbench/agent_ops.zig").applyScopePickerFilter(self);
    }

    pub fn setAgentModelIndex(self: *Workbench, index: usize) !void {
        return @import("workbench/agent_ops.zig").setAgentModelIndex(self, index);
    }

    pub fn refreshAiMcpStatus(self: *Workbench) !void {
        return @import("workbench/agent_ops.zig").refreshAiMcpStatus(self);
    }

    pub fn toggleAiMcp(self: *Workbench) !void {
        return @import("workbench/agent_ops.zig").toggleAiMcp(self);
    }

    pub fn openSettingsToml(self: *Workbench) !void {
        return @import("workbench/agent_ops.zig").openSettingsToml(self);
    }

    pub fn openMcpConfig(self: *Workbench) !void {
        return @import("workbench/agent_ops.zig").openMcpConfig(self);
    }

    fn ensureMcpConfigFile(self: *Workbench) !void {
        return @import("workbench/agent_ops.zig").ensureMcpConfigFile(self);
    }

    pub fn openAiSettings(self: *Workbench) !void {
        return @import("workbench/agent_ops.zig").openAiSettings(self);
    }

    pub fn closeAiSettings(self: *Workbench) void {
        @import("workbench/agent_ops.zig").closeAiSettings(self);
    }

    pub fn openProposalReview(self: *Workbench) void {
        @import("workbench/agent_ops.zig").openProposalReview(self);
    }

    pub fn closeProposalReview(self: *Workbench) void {
        @import("workbench/agent_ops.zig").closeProposalReview(self);
    }

    pub fn handleProposalReviewClick(self: *Workbench, hit: @import("ui/editor/proposal_review_panel.zig").Hit) !void {
        return @import("workbench/agent_ops.zig").handleProposalReviewClick(self, hit);
    }

    pub fn clampProposalReviewScroll(self: *Workbench, editor_h: f32) void {
        @import("workbench/scroll.zig").clampProposalReviewScroll(self, editor_h);
    }

    pub fn handleAiSettingsClick(self: *Workbench, hit: @import("ui/agent/ai_settings_panel.zig").Hit) !void {
        return @import("workbench/agent_ops.zig").handleAiSettingsClick(self, hit);
    }

    fn resolveWorkbenchHome(environ_map: ?*const std.process.Environ.Map) ?[]const u8 {
        return @import("workbench/agent_ops.zig").resolveWorkbenchHome(environ_map);
    }

    pub fn pasteIntoAgent(self: *Workbench) !void {
        return @import("workbench/agent_ops.zig").pasteIntoAgent(self);
    }

    pub fn composerInputHeight(self: *Workbench, agent_w: f32) f32 {
        const ac = @import("ui/agent/agent_composer.zig");
        self.agent.lock();
        const attachment_count = self.agent.attachments.items.len;
        self.agent.unlock();
        const visual_lines = ac.visualLineCount(&self.prompt_buffer, agent_w);
        return ac.inputTextHeight(attachment_count, visual_lines);
    }

    pub fn clampPromptScroll(self: *Workbench, agent_w: f32) void {
        @import("workbench/scroll.zig").clampPromptScroll(self, agent_w);
    }

    pub fn ensurePromptCursorVisible(self: *Workbench) void {
        @import("workbench/agent_ops.zig").ensurePromptCursorVisible(self);
    }

    fn ensureAgentAttachmentsDir(self: *Workbench) !void {
        return @import("workbench/agent_ops.zig").ensureAgentAttachmentsDir(self);
    }

    pub fn refreshAgentContextPreview(self: *Workbench) void {
        @import("workbench/agent_ops.zig").refreshAgentContextPreview(self);
    }

    pub fn selectScopePickerEntry(self: *Workbench) !void {
        return @import("workbench/agent_ops.zig").selectScopePickerEntry(self);
    }

    pub fn updateTabPath(self: *Workbench, old_path: []const u8, new_path: []const u8) !void {
        for (self.tabs.tabs.items) |*doc| {
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
        if (self.tabs.tabs.items.len == 0) return null;
        const idx = if (!self.editor_split or pane == .primary) self.tabs.active else self.split_tab_index;
        if (idx >= self.tabs.tabs.items.len) return null;
        return &self.tabs.tabs.items[idx];
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
        const path = self.tabs.tabs.items[index].path;
        const base = std.fs.path.basename(path);
        return std.fmt.bufPrint(out, "{s}{s}", .{
            base,
            if (self.tabs.tabs.items[index].isDirty()) " •" else "",
        }) catch base;
    }

    pub fn activePathBasename(self: *const Workbench) []const u8 {
        if (self.tabs.tabs.items.len == 0) return "untitled";
        if (self.tabs.active >= self.tabs.tabs.items.len) return "untitled";
        return std.fs.path.basename(self.tabs.tabs.items[self.tabs.active].path);
    }

    pub fn activeFilePath(self: *const Workbench) ?[]const u8 {
        if (self.tabs.tabs.items.len == 0) return null;
        const idx = if (!self.editor_split or self.editor_pane_focus == .primary) self.tabs.active else self.split_tab_index;
        if (idx >= self.tabs.tabs.items.len) return null;
        return self.tabs.tabs.items[idx].path;
    }

    pub fn splitEditorRight(self: *Workbench) !void {
        if (self.tabs.tabs.items.len == 0) return;
        self.editor_split = true;
        self.split_tab_index = self.tabs.active;
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
                if (self.rename_preview.active) {
                    break :blk self.rename_preview.lines.len + 1;
                }
                if (self.references.active) break :blk self.references.items.len;
                break :blk self.task_output.lines.items.len;
            },
            .problems => self.diagnostics.list.items.len,
            .terminal => blk: {
                const terminals: *terminal_group_mod.Group = @constCast(&self.terminals);
                const terminal = terminals.activeSession();
                terminal.lock();
                defer terminal.unlock();
                const partial: usize = if (terminal.local_input != null or terminal.isActive()) 1 else 0;
                break :blk terminal.lines.items.len + partial;
            },
            .debug_console => self.debug_console.lines.items.len,
            .debug_variables => self.debug_variables.items.items.len,
            .debug_callstack => self.debug_callstack.items.items.len,
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

    pub fn clampChatScroll(self: *Workbench, agent_h: f32) void {
        @import("workbench/scroll.zig").clampChatScroll(self, agent_h);
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

    pub fn toggleBreakpointAtCursor(self: *Workbench) !void {
        return @import("workbench/debug_ops.zig").toggleBreakpointAtCursor(self);
    }

    pub fn runLaunchConfig(self: *Workbench, index: usize) !void {
        return @import("workbench/debug_ops.zig").runLaunchConfig(self, index);
    }

    fn onDebugLine(context: ?*anyopaque, line: []const u8) void {
        @import("workbench/debug_ops.zig").onDebugLine(context, line);
    }

    fn clearDebugStop(self: *Workbench) void {
        @import("workbench/debug_ops.zig").clearDebugStop(self);
    }

    fn applyDebugStop(self: *Workbench, parsed_path: []const u8, line: usize) void {
        @import("workbench/debug_ops.zig").applyDebugStop(self, parsed_path, line);
    }

    fn scrollEditorToLine(self: *Workbench, line: usize) void {
        @import("workbench/debug_ops.zig").scrollEditorToLine(self, line);
    }

    fn clearDebugInspect(self: *Workbench) void {
        @import("workbench/debug_ops.zig").clearDebugInspect(self);
    }

    fn onDebugLldbFinished(context: ?*anyopaque, exit_code: i32) void {
        @import("workbench/debug_ops.zig").onDebugLldbFinished(context, exit_code);
    }

    fn onDebugFinished(context: ?*anyopaque, exit_code: i32) void {
        @import("workbench/debug_ops.zig").onDebugFinished(context, exit_code);
    }

    pub fn debugContinue(self: *Workbench) !void {
        return @import("workbench/debug_ops.zig").debugContinue(self);
    }

    pub fn debugStepOver(self: *Workbench) !void {
        return @import("workbench/debug_ops.zig").debugStepOver(self);
    }

    pub fn debugStepInto(self: *Workbench) !void {
        return @import("workbench/debug_ops.zig").debugStepInto(self);
    }

    pub fn debugStepOut(self: *Workbench) !void {
        return @import("workbench/debug_ops.zig").debugStepOut(self);
    }

    pub fn debugStop(self: *Workbench) void {
        @import("workbench/debug_ops.zig").debugStop(self);
    }

    pub fn handleDebugClick(self: *Workbench, hit: @import("ui/sidebar/debug_panel.zig").Hit) !void {
        return @import("workbench/debug_ops.zig").handleDebugClick(self, hit);
    }

    pub fn runSearch(self: *Workbench) !void {
        return @import("workbench/search_ops.zig").runSearch(self);
    }

    pub fn refreshGitStatus(self: *Workbench) !void {
        return @import("workbench/git_ops.zig").refreshGitStatus(self);
    }

    pub fn updateTerminalPrompt(self: *Workbench) !void {
        var buf: [256]u8 = undefined;
        const git_ptr: ?*const git_status_mod.Status = if (self.git_status) |*status| status else null;
        const prompt = @import("ui/panel/terminal_prompt.zig").format(self.workspace_path, git_ptr, &buf);
        try self.activeTerminal().setPromptLine(prompt);
    }

    pub fn handleSearchClick(self: *Workbench, hit: @import("ui/sidebar/search_panel.zig").Hit) !void {
        return @import("workbench/search_ops.zig").handleSearchClick(self, hit);
    }

    pub fn handleGitClick(self: *Workbench, hit: @import("ui/sidebar/git_panel.zig").Hit) !void {
        return @import("workbench/git_ops.zig").handleGitClick(self, hit);
    }

    pub fn commitStagedChanges(self: *Workbench) !void {
        return @import("workbench/git_ops.zig").commitStagedChanges(self);
    }

    pub fn canUninstallExtension(self: *const Workbench, ext: *const plugin.LoadedExtension) bool {
        return @import("workbench/extensions_ops.zig").canUninstallExtension(self, ext);
    }

    pub fn handleExtensionsClick(self: *Workbench, hit: @import("ui/sidebar/extensions_panel.zig").Hit) !void {
        return @import("workbench/extensions_ops.zig").handleExtensionsClick(self, hit);
    }

    pub fn reloadExtensions(self: *Workbench) !void {
        return @import("workbench/extensions_ops.zig").reloadExtensions(self);
    }

    pub fn ensureBundledExtensions(self: *Workbench) !void {
        return @import("workbench/extensions_ops.zig").ensureBundledExtensions(self);
    }

    pub fn requestEditorHover(
        self: *Workbench,
        doc_path: []const u8,
        row: usize,
        col: usize,
        anchor_x: f32,
        anchor_y: f32,
    ) void {
        self.hover.requestAt(doc_path, @intCast(row), @intCast(col), anchor_x, anchor_y);
    }

    pub fn syncContributions(self: *Workbench) !void {
        try self.keybindings.rebuild(&self.extension_host);
        self.lsp_registry.clear(self.allocator);
        for (self.extension_host.contributions.languages.items) |lang| {
            try self.lsp_registry.add(self.allocator, .{
                .language_id = lang.id,
                .server = lang.server,
                .args = lang.args,
                .file_pattern = lang.file_pattern,
                .extension_id = lang.extension_id,
                .state = .configured,
            });
        }
        try self.lsp_proxy.syncRegistry(&self.lsp_registry);
        try self.palette.addExtensionCommands(&self.extension_host);
        try self.palette.addContributionCommands(&self.extension_host);

        if (self.tabs.activeDoc()) |doc| self.warmLspForPath(doc.path);
    }

    fn warmLspForPath(self: *Workbench, path: []const u8) void {
        const owned = self.lsp_registry.copyMatchForPath(self.allocator, path) catch return;
        const config = owned orelse return;
        defer lsp.Registry.freeConfig(self.allocator, config);
        self.lsp_proxy.warmLanguage(config);
    }

    pub fn persistExtensionTheme(self: *Workbench, qualified: []const u8) !void {
        return @import("workbench/extensions_ops.zig").persistExtensionTheme(self, qualified);
    }

    pub fn reloadTheme(self: *Workbench) !void {
        self.theme.deinit();
        self.theme = try @import("theme_loader.zig").loadTheme(self.allocator, self.io, self.workspace_root, &self.extension_host);
        settings_mod.applyToTheme(self.user_settings, &self.theme);
        @import("theme_loader.zig").syncFontMetrics(&self.theme);
        @import("theme_loader.zig").applyToRenderer(&self.theme);
        try self.setStatus("Theme reloaded");
    }

    pub fn reloadUserSettings(self: *Workbench) !void {
        self.user_settings.deinit(self.allocator);
        self.user_settings = settings_mod.load(self.allocator, self.io, self.workspace_root) catch .{};
        settings_mod.applyToTheme(self.user_settings, &self.theme);
        @import("theme_loader.zig").syncFontMetrics(&self.theme);
        @import("theme_loader.zig").applyToRenderer(&self.theme);
        try self.setStatus("Settings reloaded");
    }

    pub fn toggleWordWrap(self: *Workbench) !void {
        const next = !self.user_settings.word_wrap;
        try settings_mod.writeWordWrap(self.allocator, self.io, self.workspace_root, next);
        try self.reloadUserSettings();
        const msg = if (next) "Word wrap enabled" else "Word wrap disabled";
        try self.setStatus(msg);
    }

    pub fn copyDebugVariable(self: *Workbench, index: usize) !void {
        return @import("workbench/debug_ops.zig").copyDebugVariable(self, index);
    }

    pub fn showAgentReview(self: *Workbench) !void {
        return @import("workbench/agent_ops.zig").showAgentReview(self);
    }

    pub fn gotoDebugStackFrame(self: *Workbench, index: usize) !void {
        return @import("workbench/debug_ops.zig").gotoDebugStackFrame(self, index);
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

    pub fn quickFixAtCursor(self: *Workbench) !void {
        const doc = self.tabs.activeDoc() orelse {
            try self.setStatus("No file open for quick fix");
            return;
        };
        const row: u32 = @intCast(doc.buffer.cursor.row);
        const col: u32 = @intCast(doc.buffer.cursor.col);

        var diag_match: ?lsp.diagnostics.Diagnostic = null;
        for (self.diagnostics.list.items) |diag| {
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

        _ = try self.lsp_sync.ensureSyncedBlocking(doc);

        const uri = try lsp.diagnostics.fileUri(self.allocator, self.workspace_path, doc.path);
        defer self.allocator.free(uri);

        const req = try lsp.code_action.buildCodeActionRequest(self.allocator, 95, uri, diag);
        defer self.allocator.free(req);

        const owned = try self.lsp_registry.copyMatchForPath(self.allocator, doc.path);
        const config = owned orelse {
            try self.setStatus("No language server for quick fix");
            return;
        };
        defer lsp.Registry.freeConfig(self.allocator, config);

        var response_buf: [256 * 1024]u8 = undefined;
        const len = self.lsp_proxy.request(config.language_id, req, &response_buf, response_buf.len) catch |err| {
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

        if (actions[0].edit) |*edit| {
            try @import("workbench/editor_ops.zig").applyWorkspaceEdit(self, edit);
            try self.setStatus(actions[0].title);
            return;
        }
        try self.setStatus("Quick fix has no edit");
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
        if (self.tabs.tabs.items.len > 0) {
            const visible_w = @max(10, geo.editor_w - 60);
            tabs_ui.scrollToTab(self, self.tabs.active, geo.editor_x, visible_w);
        } else {
            self.tab_scroll_x = 0;
        }
    }

    pub fn closeTabAt(self: *Workbench, index: usize) !void {
        if (index >= self.tabs.tabs.items.len) return;
        const path = self.tabs.tabs.items[index].path;
        self.lsp_sync.onDocumentClosed(path);
        self.tabs.closeAt(index);
        if (self.editor_split and self.split_tab_index >= self.tabs.tabs.items.len) {
            if (self.tabs.tabs.items.len == 0) {
                self.editor_split = false;
            } else {
                self.split_tab_index = @min(self.split_tab_index, self.tabs.tabs.items.len - 1);
            }
        }
        if (self.tabs.tabs.items.len > 0) {
            try self.explorer.select(self.tabs.tabs.items[self.tabs.active].path);
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
        self.task_output.appendLine(line) catch {};
    }

    pub fn onTaskFinished(context: ?*anyopaque, exit_code: i32) void {
        const self: *Workbench = @ptrCast(@alignCast(context.?));
        self.task_output.setRunning(false);
        self.task_output.setExitCode(exit_code);
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Task finished (exit {d})", .{exit_code}) catch "Task finished";
        self.debug_console.log(msg) catch {};
        self.setStatus(if (exit_code == 0) "Task finished" else "Task failed") catch {};
    }

    pub fn scrollEditorToCursor(self: *Workbench) void {
        @import("workbench/editor_ops.zig").scrollEditorToCursor(self);
    }

    pub fn openEditorFind(self: *Workbench, replace_mode: bool) !void {
        return @import("workbench/editor_ops.zig").openEditorFind(self, replace_mode);
    }

    pub fn openGotoLine(self: *Workbench) !void {
        return @import("workbench/editor_ops.zig").openGotoLine(self);
    }

    pub fn closeEditorOverlay(self: *Workbench) void {
        @import("workbench/editor_ops.zig").closeEditorOverlay(self);
    }

    pub fn openRenameSymbol(self: *Workbench) !void {
        return @import("workbench/editor_ops.zig").openRenameSymbol(self);
    }

    pub fn commitRenameSymbol(self: *Workbench) !void {
        return @import("workbench/editor_ops.zig").commitRenameSymbol(self);
    }

    pub fn previewRenameSymbol(self: *Workbench, new_name: []const u8) !void {
        return @import("workbench/editor_ops.zig").previewRenameSymbol(self, new_name);
    }

    pub fn acceptRenamePreview(self: *Workbench) !void {
        return @import("workbench/editor_ops.zig").acceptRenamePreview(self);
    }

    pub fn rejectRenamePreview(self: *Workbench) void {
        @import("workbench/editor_ops.zig").rejectRenamePreview(self);
    }

    pub fn gotoReference(self: *Workbench, index: usize) !void {
        return @import("workbench/editor_ops.zig").gotoReference(self, index);
    }

    pub fn gotoLocation(self: *Workbench, loc: lsp.navigation.Location) !void {
        return @import("workbench/editor_ops.zig").gotoLocation(self, loc);
    }

    pub fn findReferences(self: *Workbench) !void {
        return @import("workbench/editor_ops.zig").findReferences(self);
    }

    pub fn renameSymbol(self: *Workbench, new_name: []const u8) !void {
        return @import("workbench/editor_ops.zig").renameSymbol(self, new_name);
    }

    pub fn formatDocument(self: *Workbench) !void {
        return @import("workbench/editor_ops.zig").formatDocument(self);
    }

    pub fn findNextMatch(self: *Workbench) !void {
        return @import("workbench/editor_ops.zig").findNextMatch(self);
    }

    pub fn findPrevMatch(self: *Workbench) !void {
        return @import("workbench/editor_ops.zig").findPrevMatch(self);
    }

    pub fn commitGotoLine(self: *Workbench) !void {
        return @import("workbench/editor_ops.zig").commitGotoLine(self);
    }

    pub fn gotoProblem(self: *Workbench, index: usize) !void {
        return @import("workbench/editor_ops.zig").gotoProblem(self, index);
    }

    pub fn handleProblemsClick(self: *Workbench, index: usize) !void {
        try self.dispatch(.{ .problems_goto = index });
    }

    pub fn persistSessionState(self: *Workbench) !void {
        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(self.allocator);
        for (self.tabs.tabs.items) |doc| {
            try paths.append(self.allocator, doc.path);
        }
        const layout: session_restore_mod.Layout = .{
            .active = self.tabs.active,
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
        try session_restore_mod.saveSession(self.allocator, self.io, self.workspace_root, paths.items, layout, &self.breakpoints);
        try self.persistChatHistory();
    }

    pub fn persistChatHistory(self: *Workbench) !void {
        var stored: std.ArrayList(chat_persistence_mod.StoredMessage) = .empty;
        defer stored.deinit(self.allocator);
        for (self.chat_history.items) |msg| {
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

        for (self.chat_history.items) |msg| freeChatMessage(self.allocator, msg);
        self.chat_history.clearRetainingCapacity();

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
            try self.chat_history.append(self.allocator, .{
                .role = role,
                .content = owned,
                .tool_index = msg.tool_index,
                .tool_kind = owned_kind,
                .tool_content = owned_tool_content,
                .tool_running = false,
            });
        }
        if (self.chat_history.items.len != loaded.len or normalized_history) {
            self.persistChatHistory() catch {};
        }
        self.chat_history_revision += 1;
        self.invalidateChatLayout();
        self.chat_scroll_to_end_on_ready = true;
        self.chat_follow_stream = false;
    }

    pub fn clearChatHistory(self: *Workbench) !void {
        for (self.chat_history.items) |msg| freeChatMessage(self.allocator, msg);
        self.chat_history.clearRetainingCapacity();
        self.invalidateChatLayout();
    }

    pub fn restoreSessionTabs(self: *Workbench) !void {
        const loaded = try session_restore_mod.loadSession(self.allocator, self.io, self.workspace_root);
        defer session_restore_mod.freeLoadedSession(self.allocator, loaded.paths, loaded.breakpoint_lines);
        if (loaded.paths.len == 0) return;

        self.closeAllTabsWithLsp();
        self.lsp_sync.resetEntries();

        for (loaded.paths) |path| {
            self.openFile(path) catch {};
        }
        if (loaded.layout.active < self.tabs.tabs.items.len) {
            try self.activateTab(loaded.layout.active);
        }

        self.editor_split = loaded.layout.editor_split;
        self.split_tab_index = if (loaded.layout.split_tab_index < self.tabs.tabs.items.len)
            loaded.layout.split_tab_index
        else
            self.tabs.active;
        self.editor_pane_focus = if (loaded.layout.editor_pane_secondary) .secondary else .primary;
        self.editor_scroll_y = loaded.layout.editor_scroll_y;
        self.editor_scroll_x = loaded.layout.editor_scroll_x;
        self.split_scroll_y = loaded.layout.split_scroll_y;
        self.split_scroll_x = loaded.layout.split_scroll_x;
        self.bottom_panel_mode = loaded.layout.bottom_panel_mode;
        self.sidebar_view = loaded.layout.sidebar_view;
        self.bottom_panel_height = loaded.layout.bottom_panel_height;

        try self.breakpoints.restoreAll(loaded.breakpoint_lines);

        try self.setStatus("Session restored");
    }

    fn closeAllTabsWithLsp(self: *Workbench) void {
        while (self.tabs.tabs.items.len > 0) {
            const idx = self.tabs.tabs.items.len - 1;
            const path = self.tabs.tabs.items[idx].path;
            self.lsp_sync.onDocumentClosed(path);
            self.tabs.closeAt(idx);
        }
        self.editor_split = false;
        self.tab_scroll_x = 0;
    }

    pub fn openFile(self: *Workbench, path: []const u8) !void {
        const doc = try self.tabs.openOrActivate(path);
        try workspace_io.loadDocument(self.io, self.workspace_root, doc);
        try self.explorer.select(path);
        self.focused_panel = .editor;
        self.syncTabScroll();
        self.warmLspForPath(path);
        try self.diagnostics.setActivePath(path);
        try self.recordNavigation(path);
        try self.events.publish(.{ .file_opened = path });
    }

    pub fn activateTab(self: *Workbench, index: usize) !void {
        if (index >= self.tabs.tabs.items.len) return;
        self.tabs.active = index;
        const doc = &self.tabs.tabs.items[index];
        try self.explorer.select(doc.path);
        self.focused_panel = .editor;
        self.syncTabScroll();
        self.warmLspForPath(doc.path);
        try self.diagnostics.setActivePath(doc.path);
        if (doc.external_conflict) try self.openConflictDialog(doc.path);
        try self.recordNavigation(doc.path);
    }

    pub fn agentHost(self: *Workbench) agent_workflow.Host {
        return @import("workbench/agent_ops.zig").agentHost(self);
    }

    pub fn snapshotContextSupplement(self: *Workbench, allocator: std.mem.Allocator) !ai.context_supplement.Supplement {
        return @import("workbench/agent_ops.zig").snapshotContextSupplement(self, allocator);
    }

    fn diagnosticSeverityLabel(severity: lsp.diagnostics.Severity) []const u8 {
        return @import("workbench/agent_ops.zig").diagnosticSeverityLabel(severity);
    }

    fn bridgeSnapshotContextSupplement(context: ?*anyopaque, allocator: std.mem.Allocator) ai.context_supplement.Supplement {
        return @import("workbench/agent_ops.zig").bridgeSnapshotContextSupplement(context, allocator);
    }

    fn bridgeFreeContextSupplement(context: ?*anyopaque, allocator: std.mem.Allocator, supplement: ai.context_supplement.Supplement) void {
        @import("workbench/agent_ops.zig").bridgeFreeContextSupplement(context, allocator, supplement);
    }

    pub fn snapshotRecentTabPaths(self: *Workbench, allocator: std.mem.Allocator) ![]const []const u8 {
        return @import("workbench/agent_ops.zig").snapshotRecentTabPaths(self, allocator);
    }

    fn bridgeSnapshotRecentFiles(context: ?*anyopaque, allocator: std.mem.Allocator) []const []const u8 {
        return @import("workbench/agent_ops.zig").bridgeSnapshotRecentFiles(context, allocator);
    }

    fn bridgeFreeRecentFilesSnapshot(context: ?*anyopaque, allocator: std.mem.Allocator, paths: []const []const u8) void {
        @import("workbench/agent_ops.zig").bridgeFreeRecentFilesSnapshot(context, allocator, paths);
    }

    pub fn snapshotAgentConversation(self: *Workbench, allocator: std.mem.Allocator) ![]ai.conversation.Turn {
        return @import("workbench/agent_ops.zig").snapshotAgentConversation(self, allocator);
    }

    fn bridgeSnapshotConversation(context: ?*anyopaque, allocator: std.mem.Allocator) []const ai.conversation.Turn {
        return @import("workbench/agent_ops.zig").bridgeSnapshotConversation(context, allocator);
    }

    fn bridgeFreeConversationSnapshot(context: ?*anyopaque, allocator: std.mem.Allocator, turns: []const ai.conversation.Turn) void {
        @import("workbench/agent_ops.zig").bridgeFreeConversationSnapshot(context, allocator, turns);
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
    } {
        _ = root;
        const settings_abs = try workspace.global_store.joinHome(allocator, "settings.toml");
        defer allocator.free(settings_abs);
        const content = try workspace.global_store.readAbsoluteFile(allocator, io, settings_abs);
        defer allocator.free(content);
        const config = workspace.Config.parse(content) catch workspace.Config{};
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
        };
    }

    fn bridgeAppendChat(context: ?*anyopaque, role: agent_workflow.ChatRole, content: []const u8) void {
        @import("workbench/agent_ops.zig").bridgeAppendChat(context, role, content);
    }

    fn bridgeSetStatus(context: ?*anyopaque, message: []const u8) void {
        @import("workbench/agent_ops.zig").bridgeSetStatus(context, message);
    }

    fn bridgeEnqueueAgentUi(context: ?*anyopaque, op: agent_ui_queue_mod.Op) void {
        @import("workbench/agent_ops.zig").bridgeEnqueueAgentUi(context, op);
    }

    pub fn flushAgentUi(self: *Workbench) !void {
        return @import("workbench/agent_ops.zig").flushAgentUi(self);
    }

    fn bridgeRefreshExplorer(context: ?*anyopaque) void {
        @import("workbench/agent_ops.zig").bridgeRefreshExplorer(context);
    }

    fn bridgeOpenFile(context: ?*anyopaque, path: []const u8) void {
        @import("workbench/agent_ops.zig").bridgeOpenFile(context, path);
    }

    pub fn appendChat(self: *Workbench, role: ChatRole, content: []const u8) !void {
        return @import("workbench/agent_ops.zig").appendChat(self, role, content);
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
        try self.flushAgentUi();

        if (self.agent.worker_running) {
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
            self.conflict_check_cooldown = 2.0;
            if (self.focused_panel != .palette and self.focused_panel != .recovery and self.focused_panel != .conflict) {
                for (self.tabs.tabs.items) |*doc| {
                    try doc.checkExternalConflict(self.io, self.workspace_root);
                    if (doc.external_conflict and !doc.isDirty()) {
                        try @import("workspace_io.zig").loadDocument(self.io, self.workspace_root, doc);
                    }
                }
                if (self.tabs.activeDoc()) |doc| {
                    if (doc.external_conflict) try self.openConflictDialog(doc.path);
                }
            }
        }

        self.diagnostics.tick(dt, self.tabs.activeDoc(), self.agent.worker_running);
        self.hover.tick(dt);
        @import("workbench/editor_ops.zig").tickGhostCompletion(self, dt);

        if (self.explorer_boot_pending) {
            self.explorer_boot_pending = false;
            self.explorer.rebuild(self.io, self.workspace_root) catch {};
        }

        if (self.terminal_boot_pending) {
            self.terminal_boot_pending = false;
            self.activeTerminal().ensureStarted() catch {};
            self.syncTerminalSize();
            self.refreshGitStatus() catch {};
            self.updateTerminalPrompt() catch {};
        }

        if (self.bottom_panel_mode == .terminal) {
            self.terminal_prompt_refresh_cooldown -= dt;
            if (self.terminal_prompt_refresh_cooldown <= 0) {
                self.terminal_prompt_refresh_cooldown = 3.0;
                self.refreshGitStatus() catch {};
                self.updateTerminalPrompt() catch {};
            }
            self.syncTerminalSize();
        }

        self.lsp_sync.tick(dt, &self.tabs);
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

    pub fn showGitDiff(self: *Workbench, path: []const u8, untracked: bool) !void {
        return @import("workbench/git_ops.zig").showGitDiff(self, path, untracked);
    }

    pub fn goToDefinition(self: *Workbench) !void {
        const doc = self.tabs.activeDoc() orelse return;
        const owned = try self.lsp_registry.copyMatchForPath(self.allocator, doc.path);
        const config = owned orelse {
            try self.setStatus("No language server for this file");
            return;
        };
        defer lsp.Registry.freeConfig(self.allocator, config);

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
        const len = self.lsp_proxy.request(config.language_id, def_req, &response_buf, response_buf.len) catch {
            try self.setStatus("Go to definition failed");
            return;
        };

        var location = try lsp.navigation.parseDefinitionResponse(self.allocator, response_buf[0..len]);
        if (location) |*loc| {
            defer loc.deinit(self.allocator);
            try self.gotoLocation(loc.*);
            try self.setStatus("Go to definition");
            return;
        }
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

            const doc = try self.tabs.openOrActivate(snap.path);
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
