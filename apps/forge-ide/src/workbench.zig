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
const editor_find_mod = @import("workbench/editor_find.zig");
const settings_mod = @import("workbench/settings.zig");
const session_restore_mod = @import("workbench/session_restore.zig");
const chat_persistence_mod = @import("workbench/chat_persistence.zig");
const agent_ui_queue_mod = @import("workbench/agent_ui_queue.zig");

pub const PanelFocus = enum { editor, agent, explorer, search, git, run, extensions, terminal, palette, conflict, recovery, find, goto_line, rename };
pub const EditorPane = enum { primary, secondary };
pub const ChatRole = enum { user, agent };
pub const ChatMessage = struct {
    role: ChatRole,
    content: [:0]const u8,
};
pub const Command = commands_mod.Command;
pub const Event = commands_mod.Event;

pub const Workbench = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
    workspace_root: workspace.WorkspaceRoot,
    tabs: editor.TabGroup,
    explorer: explorer_tree.Tree,
    extension_host: plugin.Host,
    keybindings: keybindings_mod.Registry,
    lsp_registry: lsp.Registry,
    lsp_proxy: lsp.Proxy,
    marketplace_catalog: ?plugin.MarketplaceCatalog = null,
    extensions_panel_mode: @import("ui/extensions_panel.zig").PanelMode = .installed,
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
    task_output: task_output_mod.TaskOutput,
    agent: agent_session.Session,
    agent_ui_queue: agent_ui_queue_mod.Queue = .{},
    agent_cancel_source: ?*kernel.cancellation.CancellationTokenSource = null,
    scope_picker_paths: std.ArrayList([]const u8),
    scope_picker_filtered: std.ArrayList(usize),
    prompt_buffer: editor.Buffer,
    rename_buffer: editor.Buffer,
    chat_history: std.ArrayList(ChatMessage),
    focused_panel: PanelFocus = .editor,
    previous_focus: PanelFocus = .editor,
    renaming: bool = false,
    agent_panel_width: f32 = 380.0,
    explorer_panel_width: f32 = 250.0,
    bottom_panel_height: f32 = @import("ui/layout.zig").task_panel_height,
    terminal_selection: ?@import("ui/terminal_panel.zig").Selection = null,
    shell_mode: @import("ui/layout.zig").ShellMode = .ide,
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
    sidebar_view: @import("ui/sidebar_view.zig").SidebarView = .explorer,
    selected_extension_index: ?usize = null,
    chat_scroll_y: f32 = 0,
    prompt_scroll_y: f32 = 0,
    task_scroll_y: f32 = 0,
    status_message: []const u8 = "",
    untitled_serial: u32 = 0,
    conflict_path: ?[]const u8 = null,
    recovery_count: usize = 0,
    conflict_check_cooldown: f32 = 0,
    terminal_prompt_refresh_cooldown: f32 = 3.0,
    terminal_boot_pending: bool = false,
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

    pub fn init(self: *Workbench, allocator: std.mem.Allocator, io: std.Io, workspace_path: []const u8, ide_launcher: []const u8, environ_map: ?*const std.process.Environ.Map) !void {
        var root = try workspace.WorkspaceRoot.open(io, workspace_path);
        errdefer root.close(io);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .workspace_path = try allocator.dupe(u8, workspace_path),
            .workspace_root = root,
            .tabs = editor.TabGroup.init(allocator),
            .explorer = explorer_tree.Tree.init(allocator),
            .extension_host = plugin.Host.init(allocator, io),
            .keybindings = keybindings_mod.Registry.init(allocator),
            .lsp_registry = lsp.Registry.init(allocator),
            .lsp_proxy = try lsp.Proxy.init(allocator, io, workspace_path),
            .events = kernel.EventBus(Event).init(allocator),
            .palette = try palette_mod.Palette.init(allocator),
            .task_output = task_output_mod.TaskOutput.init(allocator, io),
            .agent = agent_session.Session.init(allocator, io),
            .scope_picker_paths = .empty,
            .scope_picker_filtered = .empty,
            .prompt_buffer = try editor.Buffer.init(allocator),
            .rename_buffer = try editor.Buffer.init(allocator),
            .search_buffer = try editor.Buffer.init(allocator),
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
            .terminals = undefined,
            .lsp_sync = undefined,
            .diagnostics = undefined,
            .completions = undefined,
            .hover = undefined,
            .references = references_store_mod.Store.init(allocator),
            .rename_preview = rename_preview_mod.Store.init(allocator),
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
        self.extension_host.setHostCallbacks(wasm_bridge.hostCallbacks());
        self.marketplace_catalog = plugin.marketplace.loadCatalog(allocator, io, root) catch null;
        try self.ensureBundledExtensions();
        try self.extension_host.discoverWorkspace(self.workspace_root);
        try self.extension_host.activateAll();
        try self.syncContributions();
        try self.palette.addExtensionCommands(&self.extension_host);
        try recent_workspaces_mod.record(allocator, io, workspace_path);
        try self.refreshRecentWorkspaces();

        self.theme = try @import("theme_loader.zig").loadTheme(allocator, io, root, &self.extension_host);
        self.user_settings = settings_mod.load(allocator, io, root) catch .{};
        settings_mod.applyToTheme(self.user_settings, &self.theme);
        @import("theme_loader.zig").syncFontMetrics(&self.theme);
        @import("theme_loader.zig").applyToRenderer(&self.theme);

        if (loadAiConfig(allocator, io, root)) |cfg| {
            self.allocator.free(self.ai_provider);
            self.ai_provider = cfg.provider;
            self.ai_model = cfg.model;
        } else |_| {}

        try self.explorer.rebuild(io, root);
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
        for (self.chat_history.items) |msg| self.allocator.free(msg.content);
        self.chat_history.deinit(self.allocator);
        self.rename_buffer.deinit();
        self.search_buffer.deinit();
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
        self.hover.deinit();
        self.references.deinit();
        self.rename_preview.deinit();
        self.prompt_buffer.deinit();
        self.task_output.deinit();
        self.agent.deinit();
        self.agent_ui_queue.deinit(self.allocator);
        self.clearScopePickerPaths();
        self.scope_picker_paths.deinit(self.allocator);
        self.scope_picker_filtered.deinit(self.allocator);
        self.find_bar.deinit();
        self.goto_bar.deinit();
        self.rename_bar.deinit();
        self.user_settings.deinit(self.allocator);
        self.allocator.free(self.ai_provider);
        if (self.ai_model) |model| self.allocator.free(model);
        self.allocator.free(self.ide_launcher);
        self.palette.deinit();
        self.theme.deinit();
        if (self.active_extension_theme.len > 0) self.allocator.free(self.active_extension_theme);
        if (self.marketplace_catalog) |*catalog| catalog.deinit(self.allocator);
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

    pub fn dispatch(self: *Workbench, command: Command) !void {
        switch (command) {
            .open_file => |path| try self.openFile(path),
            .activate_tab => |index| try self.activateTab(index),
            .close_tab => |index| try self.closeTabAt(index),
            .close_active_tab => try self.closeTabAt(self.tabs.active),
            .close_all_tabs => {
                self.tabs.closeAll();
                self.tab_scroll_x = 0;
            },
            .reload_theme => try self.reloadTheme(),
            .save_active => {
                const doc = self.tabs.activeDoc() orelse return;
                if (doc.external_conflict) {
                    try self.openConflictDialog(doc.path);
                    return;
                }
                try workspace_io.saveDocument(self.io, self.workspace_root, doc);
                try recovery_mod.snapshotDirtyDocs(self.allocator, self.io, self.workspace_root, &self.tabs);
                try self.events.publish(.{ .file_saved = doc.path });
                if (std.mem.eql(u8, doc.path, ".forge/settings.toml")) {
                    try self.reloadUserSettings();
                }
                try self.setStatus("Saved");
            },
            .explorer_toggle => |path| {
                try self.explorer.toggleExpand(path);
            },
            .explorer_select => |path| try self.explorer.select(path),
            .explorer_create_file => |name| {
                const parent = self.explorer.selectedOrRoot();
                const created = try explorer_ops.createFileAlloc(self.allocator, self.io, self.workspace_root, parent, name);
                try self.explorer.rebuild(self.io, self.workspace_root);
                try self.explorer.select(created);
                const open_path = try self.allocator.dupe(u8, created);
                self.allocator.free(created);
                try self.dispatch(.{ .open_file = open_path });
                self.allocator.free(open_path);
                try self.events.publish(.{ .explorer_refreshed = {} });
            },
            .explorer_create_folder => |name| {
                const parent = self.explorer.selectedOrRoot();
                const created = try explorer_ops.createFolder(self.allocator, self.io, self.workspace_root, parent, name);
                defer self.allocator.free(created);
                try self.explorer.rebuild(self.io, self.workspace_root);
                try self.explorer.select(created);
                try self.events.publish(.{ .explorer_refreshed = {} });
            },
            .explorer_rename => |payload| {
                const old_path = self.explorer.selected_path orelse return;
                const new_path = try explorer_ops.renameEntry(self.allocator, self.io, self.workspace_root, old_path, payload.new_name);
                defer self.allocator.free(new_path);
                try self.updateTabPath(old_path, new_path);
                if (self.explorer.selected_path) |sel| self.allocator.free(sel);
                self.explorer.selected_path = try self.allocator.dupe(u8, new_path);
                self.renaming = false;
                try self.explorer.rebuild(self.io, self.workspace_root);
                try self.events.publish(.{ .explorer_refreshed = {} });
            },
            .explorer_begin_rename => {
                const path = self.explorer.selected_path orelse return;
                self.renaming = true;
                try self.rename_buffer.loadFromSlice(std.fs.path.basename(path));
            },
            .explorer_delete_selected => {
                const path = self.explorer.selected_path orelse return;
                const kind = self.explorerKind(path) orelse return;
                try explorer_ops.deleteEntry(self.io, self.workspace_root, path, kind);
                if (self.explorer.selected_path) |sel| self.allocator.free(sel);
                self.explorer.selected_path = null;
                try self.explorer.rebuild(self.io, self.workspace_root);
                try self.events.publish(.{ .explorer_refreshed = {} });
            },
            .run_extension_command => |command_id| try self.extension_host.executeCommand(command_id),
            .reload_extensions => try self.reloadExtensions(),
            .set_sidebar_view => |view| {
                self.sidebar_view = view;
                self.focused_panel = switch (view) {
                    .explorer => .explorer,
                    .search => .search,
                    .git => .git,
                    .run => .run,
                    .extensions => .extensions,
                };
                if (view == .git) try self.refreshGitStatus();
            },
            .extension_toggle => |index| {
                if (index >= self.extension_host.extensions.items.len) return;
                const ext = &self.extension_host.extensions.items[index];
                if (ext.active) {
                    try self.extension_host.deactivateExtension(ext.id);
                    try self.setStatus("Extension deactivated");
                } else {
                    try self.extension_host.activateExtension(ext.id);
                    try self.setStatus("Extension activated");
                }
                self.selected_extension_index = index;
            },
            .open_extensions_dir => |path| {
                const doc = try self.tabs.openOrActivate(path);
                try workspace_io.loadDocument(self.io, self.workspace_root, doc);
                self.sidebar_view = .extensions;
                self.focused_panel = .extensions;
                self.syncTabScroll();
            },
            .set_extensions_panel_mode => |mode| {
                self.extensions_panel_mode = mode;
                self.extensions_scroll_y = 0;
                self.extensions_detail_index = null;
            },
            .install_marketplace_extension => |extension_id| {
                const catalog = self.marketplace_catalog orelse {
                    try self.setStatus("Marketplace catalog not loaded");
                    return;
                };
                const entry = plugin.marketplace.findEntry(&catalog, extension_id) orelse {
                    try self.setStatus("Extension not found in catalog");
                    return;
                };
                const installed = try plugin.marketplace.install(self.allocator, self.io, self.workspace_root, entry);
                defer self.allocator.free(installed);
                try self.reloadExtensions();
                try self.setStatus("Extension installed");
            },
            .apply_extension_theme => |qualified| {
                if (self.active_extension_theme.len > 0) self.allocator.free(self.active_extension_theme);
                self.active_extension_theme = try self.allocator.dupe(u8, qualified);
                try self.persistExtensionTheme(qualified);
                try self.reloadTheme();
                try self.setStatus("Extension theme applied");
            },
            .refresh_explorer => {
                try self.explorer.rebuild(self.io, self.workspace_root);
                try self.events.publish(.{ .explorer_refreshed = {} });
            },
            .run_task => |task_name| {
                self.references.clear();
                if (self.task_output.isRunning()) {
                    try self.setStatus("Task already running");
                    return;
                }
                self.task_output.clear();
                self.task_output.setRunning(true);
                try tasks_mod.spawn(
                    self.allocator,
                    self.io,
                    task_name,
                    self.workspace_path,
                    Workbench.onTaskLine,
                    Workbench.onTaskFinished,
                    self,
                );
            },
            .check_external_conflicts => {
                for (self.tabs.tabs.items) |*doc| {
                    try doc.checkExternalConflict(self.io, self.workspace_root);
                }
                if (self.tabs.activeDoc()) |doc| {
                    if (doc.external_conflict) try self.openConflictDialog(doc.path);
                }
                try self.setStatus("Checked external changes");
            },
            .reload_active_from_disk => {
                const doc = self.tabs.activeDoc() orelse return;
                try workspace_io.loadDocument(self.io, self.workspace_root, doc);
                try self.closeConflictDialog();
                try self.setStatus("Reloaded from disk");
            },
            .dismiss_external_conflict => {
                if (self.tabs.activeDoc()) |doc| doc.external_conflict = false;
                try self.closeConflictDialog();
                try self.setStatus("Keeping local version");
            },
            .restore_recovery_snapshots => {
                try self.restoreRecoverySnapshots();
                self.recovery_count = 0;
                self.focused_panel = self.previous_focus;
                try self.setStatus("Restored recovery snapshots");
            },
            .discard_recovery_snapshots => {
                try self.discardRecoverySnapshots();
                self.recovery_count = 0;
                self.focused_panel = self.previous_focus;
                try self.setStatus("Discarded recovery snapshots");
            },
            .palette_open => {
                self.previous_focus = self.focused_panel;
                self.focused_panel = .palette;
                try self.palette.openPalette();
            },
            .palette_close => {
                self.palette.close();
                self.focused_panel = self.previous_focus;
            },
            .agent_set_mode => |mode| {
                self.agent.lock();
                self.agent.mode = mode;
                self.agent.mode_menu_open = false;
                self.agent.unlock();
                const label = switch (mode) {
                    .ask => "Ask mode",
                    .plan => "Plan mode",
                    .agent => "Agent mode",
                };
                try self.setStatus(label);
            },
            .agent_submit => {
                const prompt_text = try self.prompt_buffer.content();
                defer self.prompt_buffer.allocator.free(prompt_text);
                const trimmed = std.mem.trim(u8, prompt_text, &std.ascii.whitespace);
                if (trimmed.len == 0) return;
                const owned_prompt = try self.allocator.dupe(u8, trimmed);
                defer self.allocator.free(owned_prompt);

                self.prompt_buffer.deinit();
                self.prompt_buffer = try editor.Buffer.init(self.allocator);
                self.prompt_scroll_y = 0;
                self.focused_panel = .agent;

                try self.appendChat(.user, owned_prompt);
                self.scrollChatToEnd(768);
                const active = self.tabs.activeDoc();
                const active_path = if (active) |doc| doc.path else null;
                const scope = self.agent.effectiveScope(active_path);
                agent_workflow.spawnGenerate(&self.agentHost(), owned_prompt, scope, active_path) catch |err| {
                    const msg = switch (err) {
                        error.AgentBusy => "Agent is already running",
                        else => "Agent failed to start",
                    };
                    try self.setStatus(msg);
                    return;
                };
                try self.setStatus("Agent: building context…");
            },
            .agent_cancel => {
                agent_workflow.cancel(&self.agentHost());
                try self.setStatus("Cancelling agent...");
            },
            .agent_apply => {
                const tx_id = try agent_workflow.applyCurrentProposal(&self.agentHost());
                var buf: [64]u8 = undefined;
                const msg = try std.fmt.bufPrint(&buf, "Applied transaction {d}", .{tx_id});
                try self.setStatus(msg);
                try self.appendChat(.agent, "Changes applied to workspace.");
            },
            .agent_reject => {
                agent_workflow.rejectCurrentProposal(&self.agentHost());
                try self.appendChat(.agent, "Proposal rejected.");
                try self.setStatus("Proposal rejected");
            },
            .agent_show_review => try self.showAgentReview(),
            .agent_select_run => |index| {
                self.agent.lock();
                if (index < self.agent.run_history.items.len) {
                    self.agent.selected_run_index = index;
                    const entry = self.agent.run_history.items[index];
                    if (self.agent.run_id) |old| self.allocator.free(old);
                    self.agent.run_id = self.allocator.dupe(u8, entry.run_id) catch null;
                    if (self.agent.proposal_rel) |old| self.allocator.free(old);
                    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                    const proposal_rel = std.fmt.bufPrint(&path_buf, ".forge/proposals/{s}.json", .{entry.run_id}) catch "";
                    self.agent.proposal_rel = self.allocator.dupe(u8, proposal_rel) catch null;
                }
                self.agent.unlock();
                if (self.agent.proposal_rel) |rel| {
                    agent_workflow.loadProposalPreview(&self.agentHost(), rel) catch {};
                }
            },
            .agent_refresh_runs => try agent_workflow.refreshRunHistory(&self.agentHost()),
            .agent_add_scope => |path| {
                try self.agent.addScopeFile(path);
                self.refreshAgentContextPreview();
            },
            .agent_remove_scope => |path| {
                self.agent.removeScopeFile(path);
                self.refreshAgentContextPreview();
            },
            .agent_clear_scope => {
                self.agent.clearScope();
                self.refreshAgentContextPreview();
            },
            .agent_scope_picker_open => try self.openScopePicker(),
            .agent_scope_picker_close => self.agent.closeScopePicker(),
            .agent_scope_picker_select => try self.selectScopePickerEntry(),
            .agent_toggle_context_inspector => self.agent.toggleContextInspector(),
            .agent_toggle_mode_menu => self.agent.toggleModeMenu(),
            .agent_toggle_model_menu => self.agent.toggleModelMenu(),
            .agent_close_menus => self.agent.closeMenus(),
            .agent_set_model => |index| try self.setAgentModelIndex(index),
            .agent_remove_attachment => |index| {
                self.agent.removeAttachment(index);
                self.refreshAgentContextPreview();
                try self.setStatus("Attachment removed");
            },
            .set_shell_mode => |mode| {
                self.shell_mode = mode;
                if (mode == .agent_window) self.focused_panel = .agent;
                try self.setStatus(switch (mode) {
                    .ide => "IDE mode",
                    .agent_window => "Agent window",
                });
            },
            .toggle_shell_mode => {
                self.shell_mode = if (self.shell_mode == .ide) .agent_window else .ide;
                if (self.shell_mode == .agent_window) self.focused_panel = .agent;
                try self.setStatus(switch (self.shell_mode) {
                    .ide => "IDE mode",
                    .agent_window => "Agent window",
                });
            },
            .search_run => try self.runSearch(),
            .git_refresh => try self.refreshGitStatus(),
            .uninstall_extension => |extension_id| {
                try plugin.marketplace.uninstall(self.allocator, self.io, self.workspace_root, extension_id);
                try self.reloadExtensions();
                self.extensions_detail_index = null;
                try self.setStatus("Extension uninstalled");
            },
            .extensions_show_detail => |index| {
                self.extensions_detail_index = index;
                self.extensions_scroll_y = 0;
            },
            .extensions_back_from_detail => {
                self.extensions_detail_index = null;
                self.extensions_scroll_y = 0;
            },
            .set_bottom_panel_mode => |mode| {
                self.bottom_panel_mode = mode;
                self.task_scroll_y = 0;
                if (mode == .terminal) {
                    self.focused_panel = .terminal;
                    self.terminal_boot_pending = true;
                }
            },
            .terminal_submit => {
                try self.refreshGitStatus();
                try self.updateTerminalPrompt();
            },
            .terminal_new => {
                try self.terminals.addSession();
                self.bottom_panel_mode = .terminal;
                self.focused_panel = .terminal;
                self.terminal_boot_pending = true;
                try self.setStatus("New terminal");
            },
            .terminal_close => {
                if (self.terminals.closeActive()) {
                    try self.setStatus("Terminal closed");
                }
            },
            .terminal_next => {
                self.terminals.next();
                self.syncTerminalSize();
            },
            .terminal_prev => {
                self.terminals.prev();
                self.syncTerminalSize();
            },
            .terminal_activate => |index| {
                self.terminals.activate(index);
                self.syncTerminalSize();
            },
            .debug_toggle_breakpoint => try self.toggleBreakpointAtCursor(),
            .debug_clear_breakpoints => {
                self.breakpoints.clear();
                try self.debug_console.log("Breakpoints cleared");
            },
            .rename_accept => try self.acceptRenamePreview(),
            .rename_reject => self.rejectRenamePreview(),
            .debug_run_launch => |index| try self.runLaunchConfig(index),
            .debug_clear_console => self.debug_console.clear(),
            .debug_continue => try self.debugContinue(),
            .debug_step_over => try self.debugStepOver(),
            .debug_step_into => try self.debugStepInto(),
            .debug_step_out => try self.debugStepOut(),
            .debug_stop => self.debugStop(),
            .editor_completion => {
                if (self.tabs.activeDoc()) |doc| self.completions.requestForDocument(doc);
            },
            .editor_find => try self.openEditorFind(false),
            .editor_replace => try self.openEditorFind(true),
            .editor_goto_line => try self.openGotoLine(),
            .editor_find_next => try self.findNextMatch(),
            .editor_find_prev => try self.findPrevMatch(),
            .editor_find_close => self.closeEditorOverlay(),
            .editor_redo => {
                if (self.activeBuffer()) |buf| try buf.redo();
            },
            .editor_undo => {
                if (self.activeBuffer()) |buf| try buf.undo();
            },
            .editor_scroll_to_cursor => self.scrollEditorToCursor(),
            .editor_go_to_definition => try self.goToDefinition(),
            .editor_find_references => try self.findReferences(),
            .editor_rename_symbol => try self.openRenameSymbol(),
            .editor_format_document => try self.formatDocument(),
            .editor_split_right => try self.splitEditorRight(),
            .editor_close_split => try self.closeEditorSplit(),
            .references_goto => |index| try self.gotoReference(index),
            .problems_goto => |index| try self.gotoProblem(index),
            .completion_accept => {
                if (self.tabs.activeDoc()) |doc| try self.completions.acceptSelected(doc);
            },
            .completion_dismiss => self.completions.dismiss(),
            .save_session_state => try self.persistSessionState(),
            .restore_session_state => try self.restoreSessionTabs(),
            .settings_reload => try self.reloadUserSettings(),
            .settings_toggle_word_wrap => try self.toggleWordWrap(),
            .open_recent_workspace => |index| try self.openRecentWorkspace(index),
            .problem_quick_fix => try self.quickFixAtCursor(),
            .debug_stack_goto => |index| try self.gotoDebugStackFrame(index),
            .debug_copy_variable => |index| try self.copyDebugVariable(index),
        }
    }

    fn clearScopePickerPaths(self: *Workbench) void {
        for (self.scope_picker_paths.items) |path| self.allocator.free(path);
        self.scope_picker_paths.clearRetainingCapacity();
        self.scope_picker_filtered.clearRetainingCapacity();
    }

    pub fn openScopePicker(self: *Workbench) !void {
        self.clearScopePickerPaths();
        try agent_scope_picker.collectFilePaths(self.allocator, &self.explorer, &self.scope_picker_paths);
        self.agent.openScopePicker();
        try self.applyScopePickerFilter();
    }

    pub fn applyScopePickerFilter(self: *Workbench) !void {
        self.agent.lock();
        const query = self.agent.scope_query[0..self.agent.scope_query_len];
        self.agent.unlock();
        try agent_scope_picker.applyFilter(self.allocator, query, self.scope_picker_paths.items, &self.scope_picker_filtered);
        self.agent.lock();
        if (self.agent.scope_picker_selected >= self.scope_picker_filtered.items.len) {
            self.agent.scope_picker_selected = if (self.scope_picker_filtered.items.len > 0) self.scope_picker_filtered.items.len - 1 else 0;
        }
        self.agent.unlock();
    }

    pub fn setAgentModelIndex(self: *Workbench, index: usize) !void {
        const agent_composer = @import("ui/agent_composer.zig");
        if (index >= agent_composer.models.len) return;
        const model_id = agent_composer.models[index].id;
        if (self.ai_model) |old| self.allocator.free(old);
        self.ai_model = try self.allocator.dupe(u8, model_id);
        self.agent.closeMenus();
        try self.setStatus("Model updated");
    }

    pub fn pasteIntoAgent(self: *Workbench) !void {
        const timestamp_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const rel_path = try std.fmt.bufPrint(&path_buf, ".forge/attachments/att_{d}.png", .{timestamp_ms});
        var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs_path = try std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ self.workspace_path, rel_path });

        try self.ensureAgentAttachmentsDir();

        if (renderer.Renderer.saveClipboardPng(abs_path)) {
            var label_buf: [64:0]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, "image_{d}.png", .{timestamp_ms}) catch "image.png";
            label_buf[label.len] = 0;
            try self.agent.addAttachment(.{
                .kind = .image,
                .label = try self.allocator.dupe(u8, label_buf[0..label.len]),
                .stored_path = try self.allocator.dupe(u8, rel_path),
                .text_preview = null,
            });
            self.refreshAgentContextPreview();
            try self.setStatus("Pasted image attachment");
            return;
        }

        const text = renderer.Renderer.clipboardText(self.allocator) catch return;
        defer self.allocator.free(text);
        if (text.len == 0) return;

        if (text.len > 4096) {
            var label_buf: [32:0]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, "paste_{d}.txt", .{timestamp_ms}) catch "paste.txt";
            label_buf[label.len] = 0;
            const preview = try self.allocator.dupe(u8, text[0..4096]);
            try self.agent.addAttachment(.{
                .kind = .text_snippet,
                .label = try self.allocator.dupe(u8, label_buf[0..label.len]),
                .stored_path = null,
                .text_preview = preview,
            });
            self.refreshAgentContextPreview();
            try self.setStatus("Pasted text attachment");
            return;
        }

        try self.prompt_buffer.insertString(text);
        self.ensurePromptCursorVisible();
    }

    fn composerInputHeight(self: *Workbench, agent_w: f32) f32 {
        const ac = @import("ui/agent_composer.zig");
        self.agent.lock();
        const attachment_count = self.agent.attachments.items.len;
        self.agent.unlock();
        const visual_lines = ac.visualLineCount(&self.prompt_buffer, agent_w);
        const composer_h = ac.composerHeight(attachment_count, visual_lines);
        const attachment_extra = if (attachment_count > 0) ac.attachment_row_h else 0;
        return composer_h - ac.composer_chrome_h - attachment_extra;
    }

    pub fn clampPromptScroll(self: *Workbench, agent_w: f32) void {
        const ac = @import("ui/agent_composer.zig");
        const visual_lines = ac.visualLineCount(&self.prompt_buffer, agent_w);
        const input_h = self.composerInputHeight(agent_w);
        self.prompt_scroll_y = ac.clampPromptScroll(self.prompt_scroll_y, visual_lines, input_h);
    }

    pub fn ensurePromptCursorVisible(self: *Workbench) void {
        var w: f32 = 0;
        var h: f32 = 0;
        renderer.Renderer.getWindowSize(&w, &h);
        const geo = @import("ui/layout.zig").compute(self.shell_mode, w, h, self.explorer_panel_width, self.agent_panel_width, self.bottom_panel_height);
        const ac = @import("ui/agent_composer.zig");
        const max_w = ac.promptMaxWidth(geo.agent_w);
        const input_h = self.composerInputHeight(geo.agent_w);
        self.prompt_scroll_y = ac.ensureCursorVisible(self.prompt_scroll_y, &self.prompt_buffer, max_w, input_h);
    }

    fn ensureAgentAttachmentsDir(self: *Workbench) !void {
        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir_path = try std.fmt.bufPrint(&dir_buf, "{s}/.forge/attachments", .{self.workspace_path});
        std.Io.Dir.createDirPath(std.Io.Dir.cwd(), self.io, dir_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    pub fn refreshAgentContextPreview(self: *Workbench) void {
        const host = self.agentHost();
        const active = self.tabs.activeDoc();
        const active_path = if (active) |doc| doc.path else null;
        const intent_owned = blk: {
            self.agent.lock();
            defer self.agent.unlock();
            if (self.agent.intent) |text| break :blk self.allocator.dupe(u8, text) catch null;
            break :blk null;
        };
        if (intent_owned) |intent| {
            defer self.allocator.free(intent);
            agent_workflow.refreshContextPreview(&host, intent, active_path) catch {};
            return;
        }
        const prompt = self.prompt_buffer.content() catch return;
        defer self.prompt_buffer.allocator.free(prompt);
        const trimmed = std.mem.trim(u8, prompt, &std.ascii.whitespace);
        if (trimmed.len == 0) {
            agent_workflow.refreshContextPreview(&host, null, active_path) catch {};
        } else {
            agent_workflow.refreshContextPreview(&host, trimmed, active_path) catch {};
        }
    }

    pub fn selectScopePickerEntry(self: *Workbench) !void {
        const query = self.agent.scope_query[0..self.agent.scope_query_len];
        const total_rows = agent_scope_picker.visibleRowCount(self.scope_picker_filtered.items.len, query);
        if (total_rows == 0) {
            self.agent.closeScopePicker();
            return;
        }
        self.agent.lock();
        const selected = self.agent.scope_picker_selected;
        self.agent.unlock();

        if (agent_scope_picker.pinnedMarkerAt(query, selected)) |marker| {
            try self.agent.addScopeFile(marker);
        } else if (agent_scope_picker.fileListIndex(selected, query)) |list_index| {
            if (list_index >= self.scope_picker_filtered.items.len) return;
            const path_index = self.scope_picker_filtered.items[list_index];
            const path = self.scope_picker_paths.items[path_index];
            try self.agent.addScopeFile(path);
        }
        self.agent.closeScopePicker();
        self.refreshAgentContextPreview();
        try self.setStatus("Added to agent scope");
    }

    fn updateTabPath(self: *Workbench, old_path: []const u8, new_path: []const u8) !void {
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
        const scroll = @import("ui/editor_scroll.zig");
        const word_wrap = @import("ui/word_wrap.zig");
        const pane_w = self.paneWidth(editor_w);
        const viewport_w = scroll.viewportWidth(pane_w, &self.theme);
        const wrap = self.user_settings.word_wrap;

        if (self.docForPane(.primary)) |doc| {
            if (wrap) {
                self.editor_scroll_y = std.math.clamp(
                    self.editor_scroll_y,
                    0,
                    word_wrap.maxScrollY(&doc.buffer, editor_h, viewport_w, self.theme.editor_font_size, &self.theme),
                );
                self.editor_scroll_x = 0;
            } else {
                const max_line_len = scroll.longestLineLen(&doc.buffer);
                const content_w = @as(f32, @floatFromInt(max_line_len)) * scroll.charWidth(&self.theme);
                self.editor_scroll_y = scroll.clampScrollY(self.editor_scroll_y, doc.buffer.lineCount(), editor_h, &self.theme);
                self.editor_scroll_x = scroll.clampScrollX(self.editor_scroll_x, content_w, pane_w, &self.theme);
            }
        } else {
            self.editor_scroll_y = 0;
            self.editor_scroll_x = 0;
        }
        if (self.editor_split) {
            if (self.docForPane(.secondary)) |doc| {
                if (wrap) {
                    self.split_scroll_y = std.math.clamp(
                        self.split_scroll_y,
                        0,
                        word_wrap.maxScrollY(&doc.buffer, editor_h, viewport_w, self.theme.editor_font_size, &self.theme),
                    );
                    self.split_scroll_x = 0;
                } else {
                    const max_line_len = scroll.longestLineLen(&doc.buffer);
                    const content_w = @as(f32, @floatFromInt(max_line_len)) * scroll.charWidth(&self.theme);
                    self.split_scroll_y = scroll.clampScrollY(self.split_scroll_y, doc.buffer.lineCount(), editor_h, &self.theme);
                    self.split_scroll_x = scroll.clampScrollX(self.split_scroll_x, content_w, pane_w, &self.theme);
                }
            } else {
                self.split_scroll_y = 0;
                self.split_scroll_x = 0;
            }
        }
    }

    pub fn clampExplorerScroll(self: *Workbench, window_h: f32) void {
        const scroll = @import("ui/explorer_scroll.zig");
        self.explorer_scroll_y = scroll.clampScrollY(
            self.explorer_scroll_y,
            self.explorer.entries.len,
            window_h,
        );
    }

    pub fn clampExtensionsScroll(self: *Workbench, window_h: f32) void {
        const scroll = @import("ui/extensions_panel.zig");
        const catalog_ptr: ?*const plugin.MarketplaceCatalog = if (self.marketplace_catalog) |*catalog| catalog else null;
        self.extensions_scroll_y = scroll.clampScrollY(
            self.extensions_scroll_y,
            &self.extension_host,
            catalog_ptr,
            self.extensions_panel_mode,
            window_h,
            self.extensionsFilterSlice(),
            self.extensions_detail_index,
        );
    }

    pub fn extensionsFilterSlice(self: *const Workbench) []const u8 {
        return self.extensions_filter[0..self.extensions_filter_len];
    }

    pub fn clampSearchScroll(self: *Workbench, window_h: f32) void {
        const scroll = @import("ui/search_panel.zig");
        const count = if (self.search_results) |results| results.matches.len else 0;
        self.search_scroll_y = scroll.clampScrollY(self.search_scroll_y, count, window_h);
    }

    pub fn clampGitScroll(self: *Workbench, window_h: f32) void {
        const scroll = @import("ui/git_panel.zig");
        const count = if (self.git_status) |status| status.entries.len else 0;
        self.git_scroll_y = scroll.clampScrollY(self.git_scroll_y, count, window_h);
    }

    pub fn clampRunScroll(self: *Workbench, window_h: f32) void {
        const scroll = @import("ui/debug_panel.zig");
        const debug_active = self.debug_lldb.isActive();
        self.run_scroll_y = scroll.clampScrollY(self.run_scroll_y, self.breakpoints.items.items.len, window_h, debug_active);
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
        const panel_scroll = @import("ui/panel_scroll.zig");
        const viewport = panel_scroll.bottomViewportHeight(panel_h);
        self.task_scroll_y = panel_scroll.clampScrollY(
            self.task_scroll_y,
            self.bottomPanelLineCount(),
            viewport,
            panel_scroll.bottom_line_h,
        );
    }

    pub fn copyTerminalSelection(self: *Workbench) !void {
        const terminal_panel = @import("ui/terminal_panel.zig");
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
        const panel_scroll = @import("ui/panel_scroll.zig");
        const layout_mod = @import("ui/layout.zig");
        const context_inspector_mod = @import("ui/context_inspector.zig");
        const agent_panel_mod = @import("ui/agent_panel.zig");
        var estimated_lines: usize = 0;
        for (self.chat_history.items) |msg| {
            estimated_lines += std.mem.count(u8, msg.content, "\n") + 4;
        }
        self.agent.lock();
        if (self.agent.stream_text.items.len > 0) {
            estimated_lines += std.mem.count(u8, self.agent.stream_text.items, "\n") + 4;
        }
        if (self.agent.thinking_text.items.len > 0) {
            estimated_lines += std.mem.count(u8, self.agent.thinking_text.items, "\n") + 4;
        }
        const entry_count = self.agent.context_entries.items.len;
        const expanded = self.agent.context_inspector_expanded;
        const attachment_count = self.agent.attachments.items.len;
        self.agent.unlock();
        const bottom = agent_panel_mod.bottomReserved(attachment_count, self.agent_panel_width, &self.prompt_buffer) + context_inspector_mod.stripHeight(expanded, entry_count);
        const viewport = @max(0, agent_h - layout_mod.status_height - 110 - bottom);
        self.chat_scroll_y = panel_scroll.clampScrollY(
            self.chat_scroll_y,
            estimated_lines,
            viewport,
            16.0,
        );
    }

    pub fn scrollChatToEnd(self: *Workbench, agent_h: f32) void {
        const layout_mod = @import("ui/layout.zig");
        const context_inspector_mod = @import("ui/context_inspector.zig");
        const agent_panel_mod = @import("ui/agent_panel.zig");
        var estimated_lines: usize = 0;
        for (self.chat_history.items) |msg| {
            estimated_lines += std.mem.count(u8, msg.content, "\n") + 4;
        }
        self.agent.lock();
        if (self.agent.stream_text.items.len > 0) {
            estimated_lines += std.mem.count(u8, self.agent.stream_text.items, "\n") + 4;
        }
        if (self.agent.thinking_text.items.len > 0) {
            estimated_lines += std.mem.count(u8, self.agent.thinking_text.items, "\n") + 4;
        }
        const entry_count = self.agent.context_entries.items.len;
        const expanded = self.agent.context_inspector_expanded;
        const attachment_count = self.agent.attachments.items.len;
        self.agent.unlock();
        const bottom = agent_panel_mod.bottomReserved(attachment_count, self.agent_panel_width, &self.prompt_buffer) + context_inspector_mod.stripHeight(expanded, entry_count);
        const viewport = @max(0, agent_h - layout_mod.status_height - 110 - bottom);
        const content_h = @as(f32, @floatFromInt(estimated_lines)) * 16.0;
        self.chat_scroll_y = @max(0, content_h - viewport);
    }

    pub fn clampReviewScroll(self: *Workbench, agent_h: f32) void {
        const panel_scroll = @import("ui/panel_scroll.zig");
        const layout_mod = @import("ui/layout.zig");
        const agent_panel_mod = @import("ui/agent_panel.zig");
        self.agent.lock();
        const content_h = agent_panel_mod.reviewContentHeight(&self.agent);
        self.agent.unlock();
        const viewport = @max(0, agent_h - layout_mod.status_height - 200);
        self.agent.review_scroll_y = panel_scroll.clampScrollY(
            self.agent.review_scroll_y,
            @intFromFloat(content_h),
            viewport,
            1.0,
        );
    }

    pub fn toggleBreakpointAtCursor(self: *Workbench) !void {
        const doc = self.tabs.activeDoc() orelse return;
        const row = doc.buffer.cursor.row;
        const added = try self.breakpoints.toggle(doc.path, row);
        var buf: [128]u8 = undefined;
        const msg = if (added)
            try std.fmt.bufPrint(&buf, "Breakpoint set at {s}:{d}", .{ doc.path, row + 1 })
        else
            try std.fmt.bufPrint(&buf, "Breakpoint removed at {s}:{d}", .{ doc.path, row + 1 });
        try self.debug_console.log(msg);
        try self.setStatus(msg);
        try self.persistSessionState();
    }

    pub fn runLaunchConfig(self: *Workbench, index: usize) !void {
        const panel = @import("ui/debug_panel.zig");
        if (index >= panel.default_launches.len) return;
        const launch = panel.default_launches[index];

        if (std.mem.eql(u8, launch.task, "debug_current")) {
            const path = self.activeFilePath() orelse {
                try self.setStatus("No file open for debug");
                return;
            };
            if (self.task_output.isRunning()) {
                try self.setStatus("Task already running");
                return;
            }
            self.task_output.clear();
            self.task_output.setRunning(true);
            self.debug_console.clear();
            self.clearDebugStop();
            self.clearDebugInspect();
            try self.debug_console.log("Starting interactive lldb session…");
            try self.debug_lldb.start(
                self.allocator,
                self.workspace_path,
                path,
                &self.breakpoints,
                onDebugLine,
                onDebugLldbFinished,
                self,
            );
            self.bottom_panel_mode = .debug_console;
            self.focused_panel = .run;
            try self.setStatus("Debug session started");
            return;
        }

        var buf: [128]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "Launch: {s}", .{launch.label});
        try self.debug_console.log(msg);
        if (self.task_output.isRunning()) {
            try self.setStatus("Task already running");
            return;
        }
        self.task_output.clear();
        self.task_output.setRunning(true);
        try tasks_mod.spawn(
            self.allocator,
            self.io,
            launch.task,
            self.workspace_path,
            Workbench.onTaskLine,
            Workbench.onTaskFinished,
            self,
        );
        self.bottom_panel_mode = .debug_console;
        self.focused_panel = .run;
    }

    fn onDebugLine(context: ?*anyopaque, line: []const u8) void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        self.debug_console.log(line) catch {};
        if (debug_variables_mod.parseVariableLine(line)) |parsed| {
            self.debug_variables.addParsed(parsed) catch {};
            self.bottom_panel_mode = .debug_variables;
        }
        if (debug_callstack_mod.parseFrameLine(line)) |parsed| {
            self.debug_callstack.addFrame(parsed) catch {};
            self.bottom_panel_mode = .debug_callstack;
        }
        if (debug_stop_mod.parseStopLine(line)) |loc| {
            self.applyDebugStop(loc.path, loc.line);
        }
    }

    fn clearDebugStop(self: *Workbench) void {
        if (self.debug_stop_path) |path| self.allocator.free(path);
        self.debug_stop_path = null;
        self.debug_stop_line = null;
    }

    fn applyDebugStop(self: *Workbench, parsed_path: []const u8, line: usize) void {
        for (self.tabs.tabs.items) |doc| {
            if (!debug_stop_mod.pathsMatch(doc.path, parsed_path)) continue;
            if (self.debug_stop_path) |old| {
                if (std.mem.eql(u8, old, doc.path) and self.debug_stop_line == line) return;
                self.allocator.free(old);
            }
            self.debug_stop_path = self.allocator.dupe(u8, doc.path) catch return;
            self.debug_stop_line = line;
            if (self.debug_lldb.isActive()) {
                self.debug_lldb.refreshBacktrace() catch {};
            }
            if (self.activeFilePath()) |active| {
                if (std.mem.eql(u8, active, doc.path)) self.scrollEditorToLine(line);
            }
            return;
        }
    }

    fn scrollEditorToLine(self: *Workbench, line: usize) void {
        if (self.activeBuffer()) |buf| {
            buf.cursor.row = @intCast(@min(line, buf.lineCount() - 1));
            buf.cursor.col = 0;
        }
        self.scrollEditorToCursor();
    }

    fn clearDebugInspect(self: *Workbench) void {
        self.debug_variables.clear();
        self.debug_callstack.clear();
    }

    fn onDebugLldbFinished(context: ?*anyopaque, exit_code: i32) void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        self.clearDebugStop();
        self.clearDebugInspect();
        self.task_output.setRunning(false);
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Debug session ended (exit {d})", .{exit_code}) catch "Debug session ended";
        self.debug_console.log(msg) catch {};
        self.setStatus(if (exit_code == 0) "Debug session ended" else "Debug failed") catch {};
    }

    fn onDebugFinished(context: ?*anyopaque, exit_code: i32) void {
        onDebugLldbFinished(context, exit_code);
    }

    pub fn debugContinue(self: *Workbench) !void {
        if (!self.debug_lldb.isActive()) {
            try self.setStatus("No active debug session");
            return;
        }
        self.clearDebugInspect();
        try self.debug_lldb.continueExecution();
        try self.setStatus("Debug: continue");
    }

    pub fn debugStepOver(self: *Workbench) !void {
        if (!self.debug_lldb.isActive()) {
            try self.setStatus("No active debug session");
            return;
        }
        self.clearDebugInspect();
        try self.debug_lldb.stepOver();
        try self.setStatus("Debug: step over");
    }

    pub fn debugStepInto(self: *Workbench) !void {
        if (!self.debug_lldb.isActive()) {
            try self.setStatus("No active debug session");
            return;
        }
        self.clearDebugInspect();
        try self.debug_lldb.stepInto();
        try self.setStatus("Debug: step into");
    }

    pub fn debugStepOut(self: *Workbench) !void {
        if (!self.debug_lldb.isActive()) {
            try self.setStatus("No active debug session");
            return;
        }
        self.clearDebugInspect();
        try self.debug_lldb.stepOut();
        try self.setStatus("Debug: step out");
    }

    pub fn debugStop(self: *Workbench) void {
        if (!self.debug_lldb.isActive()) return;
        self.debug_lldb.stop();
        self.clearDebugStop();
        self.clearDebugInspect();
        self.task_output.setRunning(false);
        self.debug_console.log("Debug session stopped") catch {};
    }

    pub fn handleDebugClick(self: *Workbench, hit: @import("ui/debug_panel.zig").Hit) !void {
        switch (hit) {
            .run_launch => |index| try self.dispatch(.{ .debug_run_launch = index }),
            .toggle_breakpoint => try self.dispatch(.debug_toggle_breakpoint),
            .clear_breakpoints => try self.dispatch(.debug_clear_breakpoints),
            .debug_control => |control| switch (control) {
                .continue_exec => try self.dispatch(.debug_continue),
                .step_over => try self.dispatch(.debug_step_over),
                .step_into => try self.dispatch(.debug_step_into),
                .step_out => try self.dispatch(.debug_step_out),
                .stop => self.dispatch(.debug_stop) catch {},
            },
        }
    }

    pub fn runSearch(self: *Workbench) !void {
        const query = try self.search_buffer.content();
        defer self.search_buffer.allocator.free(query);
        if (self.search_results) |*results| results.deinit(self.allocator);
        self.search_results = try search_engine.searchWorkspace(
            self.allocator,
            self.io,
            self.workspace_root,
            &self.explorer,
            query,
        );
        self.search_scroll_y = 0;
        var buf: [96]u8 = undefined;
        const count = self.search_results.?.matches.len;
        const msg = try std.fmt.bufPrint(&buf, "Search: {d} result(s)", .{count});
        try self.setStatus(msg);
    }

    pub fn refreshGitStatus(self: *Workbench) !void {
        const new_status = try git_status_mod.refresh(self.allocator, self.workspace_path);
        if (self.git_status) |*status| status.deinit(self.allocator);
        self.git_status = new_status;
        self.git_scroll_y = 0;
        if (self.git_status.?.is_repo) {
            var buf: [96]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "Git: {d} change(s)", .{self.git_status.?.entries.len});
            try self.setStatus(msg);
        } else {
            try self.setStatus("Not a git repository");
        }
    }

    pub fn updateTerminalPrompt(self: *Workbench) !void {
        var buf: [256]u8 = undefined;
        const git_ptr: ?*const git_status_mod.Status = if (self.git_status) |*status| status else null;
        const prompt = @import("ui/terminal_prompt.zig").format(self.workspace_path, git_ptr, &buf);
        try self.activeTerminal().setPromptLine(prompt);
    }

    pub fn handleSearchClick(self: *Workbench, hit: @import("ui/search_panel.zig").Hit) !void {
        switch (hit) {
            .run_search => try self.dispatch(.search_run),
            .open_result => |index| {
                const results = self.search_results orelse return;
                if (index >= results.matches.len) return;
                const match = results.matches[index];
                const path = try self.allocator.dupe(u8, match.path);
                defer self.allocator.free(path);
                try self.dispatch(.{ .open_file = path });
                if (match.line) |line| {
                    if (self.activeBuffer()) |buf| {
                        if (line < buf.lineCount()) {
                            buf.cursor.row = line;
                            buf.cursor.col = 0;
                        }
                    }
                }
            },
        }
    }

    pub fn handleGitClick(self: *Workbench, hit: @import("ui/git_panel.zig").Hit) !void {
        switch (hit) {
            .refresh => try self.dispatch(.git_refresh),
            .open_file => |index| {
                const status = self.git_status orelse return;
                if (index >= status.entries.len) return;
                const entry = status.entries[index];
                const path = try self.allocator.dupe(u8, entry.path);
                defer self.allocator.free(path);
                const untracked = entry.status[0] == '?' or entry.status[1] == '?';
                try self.showGitDiff(path, untracked);
                const open_path = try self.allocator.dupe(u8, path);
                try self.dispatch(.{ .open_file = open_path });
            },
        }
    }

    pub fn canUninstallExtension(self: *const Workbench, ext: *const plugin.LoadedExtension) bool {
        _ = self;
        return std.mem.startsWith(u8, ext.root_path, ".forge/extensions/");
    }

    pub fn handleExtensionsClick(self: *Workbench, hit: @import("ui/extensions_panel.zig").Hit) !void {
        switch (hit) {
            .reload => try self.dispatch(.reload_extensions),
            .open_workspace_dir => try self.dispatch(.{ .open_file = "extensions/README.md" }),
            .open_user_dir => try self.dispatch(.{ .open_file = ".forge/extensions/README.md" }),
            .show_installed => try self.dispatch(.{ .set_extensions_panel_mode = .installed }),
            .show_marketplace => try self.dispatch(.{ .set_extensions_panel_mode = .marketplace }),
            .toggle => |index| try self.dispatch(.{ .extension_toggle = index }),
            .install => |index| {
                const catalog = self.marketplace_catalog orelse return;
                if (index >= catalog.entries.len) return;
                const id = try self.allocator.dupe(u8, catalog.entries[index].id);
                defer self.allocator.free(id);
                try self.dispatch(.{ .install_marketplace_extension = id });
            },
            .show_detail => |index| try self.dispatch(.{ .extensions_show_detail = index }),
            .back_from_detail => try self.dispatch(.extensions_back_from_detail),
            .uninstall => |index| {
                if (index >= self.extension_host.extensions.items.len) return;
                const ext = &self.extension_host.extensions.items[index];
                const id = try self.allocator.dupe(u8, ext.id);
                defer self.allocator.free(id);
                try self.dispatch(.{ .uninstall_extension = id });
            },
            .run_command => |sel| {
                if (sel.ext_index >= self.extension_host.extensions.items.len) return;
                const ext = &self.extension_host.extensions.items[sel.ext_index];
                if (sel.cmd_index >= ext.commands.items.len) return;
                const cmd_id = ext.commands.items[sel.cmd_index].id;
                try self.dispatch(.{ .run_extension_command = cmd_id });
                self.selected_extension_index = sel.ext_index;
            },
        }
    }

    pub fn reloadExtensions(self: *Workbench) !void {
        self.extension_host.deinit();
        self.extension_host = plugin.Host.init(self.allocator, self.io);
        try self.extension_host.registerBuiltin(&builtin_ext.hello_extension);
        self.extension_host.setHostCallbacks(wasm_bridge.hostCallbacks());
        try self.extension_host.discoverWorkspace(self.workspace_root);
        try self.extension_host.activateAll();
        if (self.marketplace_catalog) |*catalog| catalog.deinit(self.allocator);
        self.marketplace_catalog = plugin.marketplace.loadCatalog(self.allocator, self.io, self.workspace_root) catch null;
        try self.palette.rebuildCatalog();
        try self.syncContributions();
        try self.setStatus("Extensions reloaded");
    }

    pub fn ensureBundledExtensions(self: *Workbench) !void {
        const manifest_wp = workspace.WorkspacePath.parse(".forge/extensions/zig-lsp/forge.toml") catch return;
        if (workspace.FileSnapshot.read(self.allocator, self.io, self.workspace_root, manifest_wp)) |snap_val| {
            var snap = snap_val;
            defer snap.deinit();
            return;
        } else |_| {}

        const catalog = self.marketplace_catalog orelse return;
        const entry = plugin.marketplace.findEntry(&catalog, "forge.lsp.zig") orelse return;
        const dest = try plugin.marketplace.install(self.allocator, self.io, self.workspace_root, entry);
        defer self.allocator.free(dest);
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

    fn persistExtensionTheme(self: *Workbench, qualified: []const u8) !void {
        const existing = @import("theme_loader.zig").readUserSettings(self.allocator, self.io, self.workspace_root) catch null;
        defer if (existing) |content| self.allocator.free(content);

        const content = if (existing) |user_content|
            try settings_mod.mergeExtensionTheme(self.allocator, user_content, qualified)
        else
            try std.fmt.allocPrint(self.allocator,
                \\[extension_theme]
                \\active = "{s}"
                \\
            , .{qualified});
        defer self.allocator.free(content);

        const wp = try workspace.WorkspacePath.parse(".forge/settings.toml");
        try workspace.atomic.replaceFile(self.io, self.workspace_root, wp, content);
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
        if (index >= self.debug_variables.items.items.len) return;
        const entry = self.debug_variables.items.items[index];
        @import("forge-renderer").Renderer.setClipboardText(entry.value);
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Copied {s}", .{entry.name}) catch "Copied value";
        try self.setStatus(msg);
    }

    pub fn showAgentReview(self: *Workbench) !void {
        var owned_path: ?[]const u8 = null;
        defer if (owned_path) |path| self.allocator.free(path);

        const proposal_rel = blk: {
            self.agent.lock();
            defer self.agent.unlock();
            if (self.agent.proposal_rel) |path| break :blk path;
            if (self.agent.run_history.items.len == 0) break :blk null;
            const entry = self.agent.run_history.items[self.agent.selected_run_index];
            owned_path = try std.fmt.allocPrint(self.allocator, ".forge/proposals/{s}.json", .{entry.run_id});
            break :blk owned_path.?;
        };

        if (proposal_rel) |rel| {
            try agent_workflow.loadProposalPreview(&self.agentHost(), rel);
            self.focused_panel = .agent;
            try self.setStatus("Proposal review opened");
            return;
        }
        try self.setStatus("No proposal to review — submit an agent prompt first");
    }

    pub fn gotoDebugStackFrame(self: *Workbench, index: usize) !void {
        if (index >= self.debug_callstack.items.items.len) return;
        const frame = self.debug_callstack.items.items[index];
        for (self.tabs.tabs.items) |doc| {
            if (!debug_stop_mod.pathsMatch(doc.path, frame.path)) continue;
            for (self.tabs.tabs.items, 0..) |_, tab_index| {
                if (std.mem.eql(u8, self.tabs.tabs.items[tab_index].path, doc.path)) {
                    try self.activateTab(tab_index);
                    break;
                }
            }
            self.applyDebugStop(doc.path, frame.line);
            try self.setStatus("Jumped to stack frame");
            return;
        }
        try self.setStatus("Stack frame file not open");
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
            try self.applyWorkspaceEdit(edit);
            try self.setStatus(actions[0].title);
            return;
        }
        try self.setStatus("Quick fix has no edit");
    }

    pub fn clampTabScroll(self: *Workbench, editor_w: f32) void {
        const tabs_ui = @import("ui/tabs.zig");
        self.tab_scroll_x = tabs_ui.clampScroll(self.tab_scroll_x, self, editor_w);
    }

    pub fn syncTabScroll(self: *Workbench) void {
        const renderer_mod = @import("forge-renderer");
        const layout = @import("ui/layout.zig");
        const tabs_ui = @import("ui/tabs.zig");
        var w: f32 = 0;
        var h: f32 = 0;
        renderer_mod.Renderer.getWindowSize(&w, &h);
        const geo = layout.compute(self.shell_mode, w, h, self.explorer_panel_width, self.agent_panel_width, self.bottom_panel_height);
        if (self.tabs.tabs.items.len > 0) {
            tabs_ui.scrollToTab(self, self.tabs.active, geo.editor_x, geo.editor_w);
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

    fn onTaskLine(context: ?*anyopaque, line: []const u8) void {
        const self: *Workbench = @ptrCast(@alignCast(context.?));
        self.task_output.appendLine(line) catch {};
    }

    fn onTaskFinished(context: ?*anyopaque, exit_code: i32) void {
        const self: *Workbench = @ptrCast(@alignCast(context.?));
        self.task_output.setRunning(false);
        self.task_output.setExitCode(exit_code);
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Task finished (exit {d})", .{exit_code}) catch "Task finished";
        self.debug_console.log(msg) catch {};
        self.setStatus(if (exit_code == 0) "Task finished" else "Task failed") catch {};
    }

    pub fn scrollEditorToCursor(self: *Workbench) void {
        const renderer_mod = @import("forge-renderer");
        const layout_mod = @import("ui/layout.zig");
        var w: f32 = 0;
        var h: f32 = 0;
        renderer_mod.Renderer.getWindowSize(&w, &h);
        const geo = layout_mod.compute(self.shell_mode, w, h, self.explorer_panel_width, self.agent_panel_width, self.bottom_panel_height);
        const pane = self.focusedPane();
        const doc = self.docForPane(pane) orelse return;
        const pane_w = self.paneWidth(geo.editor_w);
        const scroll_y: *f32 = if (pane == .secondary) &self.split_scroll_y else &self.editor_scroll_y;
        const scroll_x: *f32 = if (pane == .secondary) &self.split_scroll_x else &self.editor_scroll_x;
        if (self.user_settings.word_wrap) {
            const word_wrap = @import("ui/word_wrap.zig");
            const viewport_w = @import("ui/editor_scroll.zig").viewportWidth(pane_w, &self.theme);
            scroll_y.* = word_wrap.scrollToCursor(scroll_y.*, &doc.buffer, geo.editor_h, viewport_w, self.theme.editor_font_size, &self.theme);
            scroll_x.* = 0;
        } else {
            const scrolled = @import("ui/editor_scroll.zig").scrollToCursor(
                scroll_y.*,
                scroll_x.*,
                &doc.buffer,
                pane_w,
                geo.editor_h,
                &self.theme,
            );
            scroll_y.* = scrolled.y;
            scroll_x.* = scrolled.x;
        }
    }

    pub fn openEditorFind(self: *Workbench, replace_mode: bool) !void {
        self.previous_focus = self.focused_panel;
        self.focused_panel = .find;
        self.find_bar.openFind(replace_mode);
        if (self.activeBuffer()) |buf| {
            try self.find_bar.refreshMatches(buf);
            self.scrollEditorToCursor();
        }
    }

    pub fn openGotoLine(self: *Workbench) !void {
        self.previous_focus = self.focused_panel;
        self.focused_panel = .goto_line;
        self.goto_bar.open = true;
        try self.goto_bar.input.loadFromSlice("");
    }

    pub fn closeEditorOverlay(self: *Workbench) void {
        self.find_bar.close();
        self.goto_bar.open = false;
        self.rename_bar.close();
        if (self.focused_panel == .find or self.focused_panel == .goto_line or self.focused_panel == .rename) {
            self.focused_panel = self.previous_focus;
        }
        self.completions.dismiss();
    }

    pub fn openRenameSymbol(self: *Workbench) !void {
        const buf = self.activeBuffer() orelse return;
        const word = wordAtCursor(buf);
        if (word.len == 0) {
            try self.setStatus("No symbol at cursor");
            return;
        }
        self.previous_focus = self.focused_panel;
        self.focused_panel = .rename;
        try self.rename_bar.openRename(word);
    }

    pub fn commitRenameSymbol(self: *Workbench) !void {
        const name = self.rename_bar.name();
        if (name.len == 0) return;
        try self.previewRenameSymbol(name);
        self.closeEditorOverlay();
    }

    pub fn previewRenameSymbol(self: *Workbench, new_name: []const u8) !void {
        const doc = self.tabs.activeDoc() orelse return;
        const owned = try self.lsp_registry.copyMatchForPath(self.allocator, doc.path);
        const config = owned orelse {
            try self.setStatus("No language server for this file");
            return;
        };
        defer lsp.Registry.freeConfig(self.allocator, config);

        const uri = try self.lspSyncDocument(doc);
        defer self.allocator.free(uri);

        const line: u32 = @intCast(doc.buffer.cursor.row);
        const character: u32 = @intCast(doc.buffer.cursor.col);
        const req = try lsp.rename.buildRenameRequest(self.allocator, 93, uri, line, character, new_name);
        defer self.allocator.free(req);

        var response_buf: [65536]u8 = undefined;
        const len = self.lsp_proxy.request(config.language_id, req, &response_buf, response_buf.len) catch {
            try self.setStatus("Rename failed");
            return;
        };

        const edit = try lsp.rename.parseRenameResponse(self.allocator, response_buf[0..len]);
        if (edit) |workspace_edit| {
            try self.rename_preview.setPreview(self.workspace_path, &self.tabs, new_name, workspace_edit);
            self.references.clear();
            self.bottom_panel_mode = .output;
            self.task_scroll_y = 0;
            var status_buf: [96]u8 = undefined;
            const msg = try std.fmt.bufPrint(&status_buf, "Rename preview: {d} change(s)", .{self.rename_preview.lines.len});
            try self.setStatus(msg);
            return;
        }
        try self.setStatus("Rename rejected by language server");
    }

    pub fn acceptRenamePreview(self: *Workbench) !void {
        if (self.rename_preview.edit) |*edit| {
            try self.applyWorkspaceEdit(edit);
            self.rename_preview.clear();
            try self.setStatus("Rename applied");
            return;
        }
        try self.setStatus("No rename preview");
    }

    pub fn rejectRenamePreview(self: *Workbench) void {
        if (!self.rename_preview.active) return;
        self.rename_preview.clear();
        self.setStatus("Rename cancelled") catch {};
    }

    pub fn gotoReference(self: *Workbench, index: usize) !void {
        if (index >= self.references.items.len) return;
        const item = self.references.items[index];
        try self.openFile(item.path);
        if (self.activeBuffer()) |buf| {
            buf.goToLine(@intCast(item.line + 1));
            buf.cursor.col = @intCast(item.character);
            self.scrollEditorToCursor();
        }
    }

    fn lspSyncDocument(self: *Workbench, doc: *editor.Document) ![]const u8 {
        return self.lsp_sync.ensureSyncedBlocking(doc);
    }

    pub fn gotoLocation(self: *Workbench, loc: lsp.navigation.Location) !void {
        const rel = try lsp.navigation.uriToRelativePath(self.allocator, self.workspace_path, loc.uri);
        if (rel) |path| {
            defer self.allocator.free(path);
            try self.openFile(path);
            if (self.activeBuffer()) |buf| {
                buf.goToLine(@intCast(loc.line + 1));
                buf.cursor.col = @intCast(loc.character);
                self.scrollEditorToCursor();
            }
            return;
        }
        try self.setStatus("Location outside workspace");
    }

    pub fn findReferences(self: *Workbench) !void {
        const doc = self.tabs.activeDoc() orelse return;
        const owned = try self.lsp_registry.copyMatchForPath(self.allocator, doc.path);
        const config = owned orelse {
            try self.setStatus("No language server for this file");
            return;
        };
        defer lsp.Registry.freeConfig(self.allocator, config);

        const uri = try self.lspSyncDocument(doc);
        defer self.allocator.free(uri);

        const line: u32 = @intCast(doc.buffer.cursor.row);
        const character: u32 = @intCast(doc.buffer.cursor.col);
        const req = try lsp.references.buildReferencesRequest(self.allocator, 92, uri, line, character);
        defer self.allocator.free(req);

        var response_buf: [65536]u8 = undefined;
        const len = self.lsp_proxy.request(config.language_id, req, &response_buf, response_buf.len) catch {
            try self.setStatus("Find references failed");
            return;
        };

        var list = try lsp.references.parseReferencesResponse(self.allocator, response_buf[0..len]);
        defer list.deinit(self.allocator);

        var items: std.ArrayList(references_store_mod.Item) = .empty;
        errdefer {
            for (items.items) |*item| item.deinit(self.allocator);
            items.deinit(self.allocator);
        }

        for (list.items) |loc| {
            const rel = try lsp.navigation.uriToRelativePath(self.allocator, self.workspace_path, loc.uri);
            const path = rel orelse continue;
            const label = try std.fmt.allocPrint(self.allocator, "{s}:{d}:{d}", .{
                path,
                loc.line + 1,
                loc.character + 1,
            });
            errdefer self.allocator.free(label);
            try items.append(self.allocator, .{
                .path = path,
                .line = loc.line,
                .character = loc.character,
                .label = label,
            });
        }

        self.references.setItems(try items.toOwnedSlice(self.allocator));
        self.rename_preview.clear();
        self.bottom_panel_mode = .output;
        self.task_scroll_y = 0;
        var status_buf: [64]u8 = undefined;
        const msg = try std.fmt.bufPrint(&status_buf, "{d} references", .{self.references.items.len});
        try self.setStatus(msg);
    }

    pub fn renameSymbol(self: *Workbench, new_name: []const u8) !void {
        try self.previewRenameSymbol(new_name);
        if (self.rename_preview.active) try self.acceptRenamePreview();
    }

    pub fn formatDocument(self: *Workbench) !void {
        const doc = self.tabs.activeDoc() orelse {
            try self.setStatus("No file open to format");
            return;
        };
        _ = try self.lsp_sync.ensureSyncedBlocking(doc);

        const uri = try lsp.diagnostics.fileUri(self.allocator, self.workspace_path, doc.path);
        defer self.allocator.free(uri);

        const req = try lsp.format.buildFormatRequest(self.allocator, 94, uri, 4);
        defer self.allocator.free(req);

        const owned = try self.lsp_registry.copyMatchForPath(self.allocator, doc.path);
        const config = owned orelse {
            try self.setStatus("No language server for format");
            return;
        };
        defer lsp.Registry.freeConfig(self.allocator, config);

        var response_buf: [256 * 1024]u8 = undefined;
        const len = self.lsp_proxy.request(config.language_id, req, &response_buf, response_buf.len) catch |err| {
            try self.setStatus(@errorName(err));
            return;
        };

        const edits = try lsp.format.parseFormatResponse(self.allocator, response_buf[0..len]);
        defer {
            for (edits) |*edit| edit.deinit(self.allocator);
            self.allocator.free(edits);
        }
        if (edits.len == 0) {
            try self.setStatus("Nothing to format");
            return;
        }

        var index = edits.len;
        while (index > 0) {
            index -= 1;
            const text_edit = edits[index];
            try doc.buffer.applyLspTextEdit(
                @intCast(text_edit.line),
                @intCast(text_edit.character),
                @intCast(text_edit.end_line),
                @intCast(text_edit.end_character),
                text_edit.new_text,
            );
        }
        try self.setStatus("Document formatted");
    }

    fn applyWorkspaceEdit(self: *Workbench, edit: *const lsp.rename.WorkspaceEdit) !void {
        for (edit.files) |file_edit| {
            const rel = try lsp.navigation.uriToRelativePath(self.allocator, self.workspace_path, file_edit.uri);
            const path = rel orelse continue;
            defer self.allocator.free(path);

            const doc = try self.tabs.openOrActivate(path);
            var index = file_edit.edits.len;
            while (index > 0) {
                index -= 1;
                const text_edit = file_edit.edits[index];
                try doc.buffer.applyLspTextEdit(
                    @intCast(text_edit.line),
                    @intCast(text_edit.character),
                    @intCast(text_edit.end_line),
                    @intCast(text_edit.end_character),
                    text_edit.new_text,
                );
            }
        }
    }

    pub fn findNextMatch(self: *Workbench) !void {
        const buf = self.activeBuffer() orelse return;
        if (self.find_bar.matches.len == 0) try self.find_bar.refreshMatches(buf);
        self.find_bar.nextMatch(buf);
        self.scrollEditorToCursor();
    }

    pub fn findPrevMatch(self: *Workbench) !void {
        const buf = self.activeBuffer() orelse return;
        if (self.find_bar.matches.len == 0) try self.find_bar.refreshMatches(buf);
        self.find_bar.prevMatch(buf);
        self.scrollEditorToCursor();
    }

    pub fn commitGotoLine(self: *Workbench) !void {
        const line = self.goto_bar.parseLine() orelse return;
        if (self.activeBuffer()) |buf| {
            buf.goToLine(line);
            self.scrollEditorToCursor();
        }
        self.closeEditorOverlay();
    }

    pub fn gotoProblem(self: *Workbench, index: usize) !void {
        if (index >= self.diagnostics.list.items.len) return;
        const diag = self.diagnostics.list.items[index];
        if (self.activeBuffer()) |buf| {
            buf.cursor.row = @intCast(@min(diag.line, buf.lineCount() - 1));
            const line_len = buf.lineAt(buf.cursor.row).len;
            buf.cursor.col = @intCast(@min(diag.character, line_len));
            self.scrollEditorToCursor();
            self.focused_panel = .editor;
        }
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
            };
            try stored.append(self.allocator, .{
                .role = role,
                .content = msg.content,
            });
        }
        try chat_persistence_mod.saveMessages(self.allocator, self.io, self.workspace_root, stored.items);
    }

    pub fn restoreChatHistory(self: *Workbench) !void {
        const loaded = try chat_persistence_mod.loadMessages(self.allocator, self.io, self.workspace_root);
        defer chat_persistence_mod.freeLoadedMessages(self.allocator, loaded);
        if (loaded.len == 0) return;

        for (self.chat_history.items) |msg| self.allocator.free(msg.content);
        self.chat_history.clearRetainingCapacity();

        for (loaded) |msg| {
            const role: ChatRole = if (std.mem.eql(u8, msg.role, "user")) .user else .agent;
            const owned = try self.allocator.dupeZ(u8, msg.content);
            try self.chat_history.append(self.allocator, .{ .role = role, .content = owned });
        }
        self.scrollChatToEnd(768);
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
        for (self.tabs.tabs.items) |*doc| {
            _ = self.lsp_sync.ensureSyncedBlocking(doc) catch {};
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

    fn openFile(self: *Workbench, path: []const u8) !void {
        const doc = try self.tabs.openOrActivate(path);
        try workspace_io.loadDocument(self.io, self.workspace_root, doc);
        try self.explorer.select(path);
        self.focused_panel = .editor;
        self.syncTabScroll();
        self.warmLspForPath(path);
        try self.diagnostics.setActivePath(path);
        try self.events.publish(.{ .file_opened = path });
    }

    fn activateTab(self: *Workbench, index: usize) !void {
        if (index >= self.tabs.tabs.items.len) return;
        self.tabs.active = index;
        const doc = &self.tabs.tabs.items[index];
        try self.explorer.select(doc.path);
        self.focused_panel = .editor;
        self.syncTabScroll();
        self.warmLspForPath(doc.path);
        try self.diagnostics.setActivePath(doc.path);
        if (doc.external_conflict) try self.openConflictDialog(doc.path);
    }

    pub fn agentHost(self: *Workbench) agent_workflow.Host {
        return .{
            .allocator = self.allocator,
            .io = self.io,
            .environ_map = self.environ_map,
            .ai_provider = self.ai_provider,
            .ai_model = self.ai_model,
            .workspace_root = self.workspace_root,
            .workspace_path = self.workspace_path,
            .agent = &self.agent,
            .agent_cancel_slot = &self.agent_cancel_source,
            .context = self,
            .append_chat = Workbench.bridgeAppendChat,
            .set_status = Workbench.bridgeSetStatus,
            .enqueue_ui = Workbench.bridgeEnqueueAgentUi,
            .refresh_explorer = Workbench.bridgeRefreshExplorer,
            .open_file = Workbench.bridgeOpenFile,
            .snapshot_conversation = Workbench.bridgeSnapshotConversation,
            .free_conversation_snapshot = Workbench.bridgeFreeConversationSnapshot,
            .snapshot_recent_files = Workbench.bridgeSnapshotRecentFiles,
            .free_recent_files_snapshot = Workbench.bridgeFreeRecentFilesSnapshot,
            .snapshot_context_supplement = Workbench.bridgeSnapshotContextSupplement,
            .free_context_supplement = Workbench.bridgeFreeContextSupplement,
        };
    }

    pub fn snapshotContextSupplement(self: *Workbench, allocator: std.mem.Allocator) !ai.context_supplement.Supplement {
        var diagnostics: std.ArrayList(ai.context_supplement.DiagnosticEntry) = .empty;
        errdefer ai.context_supplement.freeDiagnosticEntries(allocator, diagnostics.items);

        var lsp_hints: std.ArrayList(ai.context_supplement.LspHint) = .empty;
        errdefer ai.context_supplement.freeLspHints(allocator, lsp_hints.items);

        var cursor_owned: ?[]const u8 = null;
        errdefer if (cursor_owned) |path| allocator.free(path);

        var hover_owned: ?[]const u8 = null;
        errdefer if (hover_owned) |text| allocator.free(text);

        var cursor_pos: ?ai.context_supplement.CursorPosition = null;

        const doc = self.tabs.activeDoc();
        if (doc) |active| {
            cursor_owned = try allocator.dupe(u8, active.path);
            const line: u32 = @intCast(active.buffer.cursor.row);
            const character: u32 = @intCast(active.buffer.cursor.col);
            cursor_pos = .{
                .path = cursor_owned.?,
                .line = line,
                .character = character,
            };

            for (self.diagnostics.list.items) |diag| {
                try diagnostics.append(allocator, .{
                    .path = try allocator.dupe(u8, active.path),
                    .line = diag.line,
                    .character = diag.character,
                    .severity = try allocator.dupe(u8, diagnosticSeverityLabel(diag.severity)),
                    .message = try allocator.dupe(u8, diag.message),
                });
            }

            const owned = self.lsp_registry.copyMatchForPath(allocator, active.path) catch null;
            if (owned) |config| {
                defer lsp.Registry.freeConfig(allocator, config);

                if (self.lspSyncDocument(active)) |uri| {
                    defer allocator.free(uri);

                    const hover_req = lsp.hover.buildHoverRequest(allocator, 93, uri, line, character) catch null;
                    if (hover_req) |hover_req_body| {
                        defer allocator.free(hover_req_body);
                        var hover_buf: [65536]u8 = undefined;
                        if (self.lsp_proxy.request(config.language_id, hover_req_body, &hover_buf, hover_buf.len) catch null) |hover_len| {
                            hover_owned = lsp.hover.parseHoverResponse(allocator, hover_buf[0..hover_len]) catch null;
                        }
                    }

                    const def_req = lsp.navigation.buildDefinitionRequest(allocator, 91, uri, line, character) catch null;
                    if (def_req) |req| {
                        defer allocator.free(req);
                        var response_buf: [65536]u8 = undefined;
                        if (self.lsp_proxy.request(config.language_id, req, &response_buf, response_buf.len)) |len| {
                            if (lsp.navigation.parseDefinitionResponse(allocator, response_buf[0..len])) |location| {
                                if (location) |loc_value| {
                                    var loc = loc_value;
                                    defer loc.deinit(allocator);
                                    if (lsp.navigation.uriToRelativePath(allocator, self.workspace_path, loc.uri) catch null) |rel| {
                                        try lsp_hints.append(allocator, .{
                                            .kind = .definition,
                                            .path = rel,
                                            .line = loc.line,
                                            .character = loc.character,
                                        });
                                    }
                                }
                            } else |_| {}
                        } else |_| {}
                    }

                    const refs_req = lsp.references.buildReferencesRequest(allocator, 94, uri, line, character) catch null;
                    if (refs_req) |req| {
                        defer allocator.free(req);
                        var response_buf: [65536]u8 = undefined;
                        if (self.lsp_proxy.request(config.language_id, req, &response_buf, response_buf.len)) |len| {
                            if (lsp.references.parseReferencesResponse(allocator, response_buf[0..len])) |list| {
                                var owned_list = list;
                                defer owned_list.deinit(allocator);
                                var ref_count: usize = 0;
                                for (owned_list.items) |loc_value| {
                                    if (ref_count >= 5) break;
                                    var loc = loc_value;
                                    defer loc.deinit(allocator);
                                    if (lsp.navigation.uriToRelativePath(allocator, self.workspace_path, loc.uri) catch null) |rel| {
                                        try lsp_hints.append(allocator, .{
                                            .kind = .reference,
                                            .path = rel,
                                            .line = loc.line,
                                            .character = loc.character,
                                        });
                                        ref_count += 1;
                                    }
                                }
                            } else |_| {}
                        } else |_| {}
                    }
                } else |_| {}
            }
        }

        return .{
            .cursor = cursor_pos,
            .diagnostics = try diagnostics.toOwnedSlice(allocator),
            .lsp_hints = try lsp_hints.toOwnedSlice(allocator),
            .hover_text = hover_owned,
        };
    }

    fn diagnosticSeverityLabel(severity: lsp.diagnostics.Severity) []const u8 {
        return switch (severity) {
            .err => "error",
            .warning => "warning",
            .info => "info",
            .hint => "hint",
            else => "unknown",
        };
    }

    fn bridgeSnapshotContextSupplement(context: ?*anyopaque, allocator: std.mem.Allocator) ai.context_supplement.Supplement {
        const self: *Workbench = @ptrCast(@alignCast(context.?));
        return self.snapshotContextSupplement(allocator) catch .{};
    }

    fn bridgeFreeContextSupplement(context: ?*anyopaque, allocator: std.mem.Allocator, supplement: ai.context_supplement.Supplement) void {
        _ = context;
        ai.context_supplement.freeSupplement(allocator, supplement);
    }

    pub fn snapshotRecentTabPaths(self: *Workbench, allocator: std.mem.Allocator) ![]const []const u8 {
        var paths: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (paths.items) |path| allocator.free(path);
            paths.deinit(allocator);
        }

        if (self.tabs.tabs.items.len == 0) return try paths.toOwnedSlice(allocator);

        if (self.tabs.active < self.tabs.tabs.items.len) {
            try paths.append(allocator, try allocator.dupe(u8, self.tabs.tabs.items[self.tabs.active].path));
        }

        var index = self.tabs.tabs.items.len;
        while (index > 0) {
            index -= 1;
            if (index == self.tabs.active) continue;
            const path = self.tabs.tabs.items[index].path;
            var duplicate = false;
            for (paths.items) |existing| {
                if (std.mem.eql(u8, existing, path)) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;
            try paths.append(allocator, try allocator.dupe(u8, path));
        }

        return try paths.toOwnedSlice(allocator);
    }

    fn bridgeSnapshotRecentFiles(context: ?*anyopaque, allocator: std.mem.Allocator) []const []const u8 {
        const self: *Workbench = @ptrCast(@alignCast(context.?));
        return self.snapshotRecentTabPaths(allocator) catch return &.{};
    }

    fn bridgeFreeRecentFilesSnapshot(context: ?*anyopaque, allocator: std.mem.Allocator, paths: []const []const u8) void {
        _ = context;
        for (paths) |path| allocator.free(path);
        allocator.free(paths);
    }

    pub fn snapshotAgentConversation(self: *Workbench, allocator: std.mem.Allocator) ![]ai.conversation.Turn {
        var turns: std.ArrayList(ai.conversation.Turn) = .empty;
        errdefer ai.conversation.freeTurns(allocator, turns.items);

        var end = self.chat_history.items.len;
        if (end > 0 and self.chat_history.items[end - 1].role == .user) end -= 1;

        const start = if (end > ai.conversation.max_turns) end - ai.conversation.max_turns else 0;
        for (self.chat_history.items[start..end]) |msg| {
            const slice = ai.conversation.truncateContent(msg.content);
            try turns.append(allocator, .{
                .role = switch (msg.role) {
                    .user => .user,
                    .agent => .agent,
                },
                .content = try allocator.dupe(u8, slice),
            });
        }
        return try turns.toOwnedSlice(allocator);
    }

    fn bridgeSnapshotConversation(context: ?*anyopaque, allocator: std.mem.Allocator) []const ai.conversation.Turn {
        const self: *Workbench = @ptrCast(@alignCast(context.?));
        return self.snapshotAgentConversation(allocator) catch return &.{};
    }

    fn bridgeFreeConversationSnapshot(context: ?*anyopaque, allocator: std.mem.Allocator, turns: []const ai.conversation.Turn) void {
        _ = context;
        ai.conversation.freeTurns(allocator, turns);
    }

    fn loadAiConfig(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot) !struct {
        provider: []const u8,
        model: ?[]const u8,
    } {
        const wp = try workspace.WorkspacePath.parse("forge.toml");
        var snap = try workspace.FileSnapshot.read(allocator, io, root, wp);
        defer snap.deinit();
        const config = try workspace.Config.parse(snap.content);
        const provider = try allocator.dupe(u8, config.ai_provider);
        errdefer allocator.free(provider);
        const model = if (config.ai_model) |value| try allocator.dupe(u8, value) else null;
        errdefer if (model) |owned| allocator.free(owned);
        return .{ .provider = provider, .model = model };
    }

    fn bridgeAppendChat(context: ?*anyopaque, role: agent_workflow.ChatRole, content: []const u8) void {
        const self: *Workbench = @ptrCast(@alignCast(context.?));
        const mapped: ChatRole = if (role == .user) .user else .agent;
        self.appendChat(mapped, content) catch {};
    }

    fn bridgeSetStatus(context: ?*anyopaque, message: []const u8) void {
        const self: *Workbench = @ptrCast(@alignCast(context.?));
        self.setStatus(message) catch {};
    }

    fn bridgeEnqueueAgentUi(context: ?*anyopaque, op: agent_ui_queue_mod.Op) void {
        const self: *Workbench = @ptrCast(@alignCast(context.?));
        self.agent_ui_queue.push(self.allocator, op) catch {
            var owned = op;
            owned.deinit(self.allocator);
        };
    }

    pub fn flushAgentUi(self: *Workbench) !void {
        const ops = try self.agent_ui_queue.takeAll(self.allocator);
        defer self.allocator.free(ops);
        const host = self.agentHost();
        for (ops) |*op| {
            defer op.deinit(self.allocator);
            switch (op.*) {
                .append_chat => |payload| {
                    const mapped: ChatRole = if (payload.role == .user) .user else .agent;
                    try self.appendChat(mapped, payload.text);
                },
                .set_status => |text| try self.setStatus(text),
                .append_thinking => |text| try self.agent.appendThinkingChunk(text),
                .append_stream => |text| try self.agent.appendStreamChunk(text),
                .append_step => |payload| try self.agent.appendAgentStep(payload.index, payload.kind, payload.summary),
                .set_phase => |payload| {
                    if (payload.phase == .sending) {
                        self.agent.clearStreamText();
                    } else if (payload.phase == .streaming) {
                        self.agent.lock();
                        self.agent.stream_live = true;
                        self.agent.unlock();
                    }
                    try self.agent.setPhase(payload.phase, payload.label);
                },
                .run_finished => |payload| {
                    self.agent.lock();
                    if (self.agent.run_id) |old| self.allocator.free(old);
                    if (self.agent.proposal_rel) |old| self.allocator.free(old);
                    self.agent.run_id = try self.allocator.dupe(u8, payload.run_id);
                    self.agent.proposal_rel = try self.allocator.dupe(u8, payload.proposal_rel);
                    self.agent.worker_running = false;
                    self.agent.unlock();

                    try agent_workflow.applyManifestText(&host, payload.manifest_text);
                    try agent_workflow.loadProposalPreview(&host, payload.proposal_rel);
                    try agent_workflow.refreshRunHistory(&host);
                    if (payload.plan_text) |plan| {
                        try self.appendChat(.agent, plan);
                    }
                    try self.appendChat(.agent, payload.chat_text);
                    try self.agent.setPhase(.proposal_ready, "Proposal ready for review");
                    try self.setStatus("Proposal ready for review");
                    self.scrollChatToEnd(768);
                },
                .run_failed => |payload| {
                    self.agent.lock();
                    self.agent.worker_running = false;
                    self.agent.unlock();
                    try self.agent.setPhase(payload.phase, payload.message);
                    try self.appendChat(.agent, payload.message);
                    try self.setStatus(payload.message);
                },
            }
        }
    }

    fn bridgeRefreshExplorer(context: ?*anyopaque) void {
        const self: *Workbench = @ptrCast(@alignCast(context.?));
        self.explorer.rebuild(self.io, self.workspace_root) catch {};
    }

    fn bridgeOpenFile(context: ?*anyopaque, path: []const u8) void {
        const self: *Workbench = @ptrCast(@alignCast(context.?));
        self.dispatch(.{ .open_file = path }) catch {};
    }

    pub fn appendChat(self: *Workbench, role: ChatRole, content: []const u8) !void {
        const owned = try self.allocator.dupeZ(u8, content);
        try self.chat_history.append(self.allocator, .{ .role = role, .content = owned });
        self.persistChatHistory() catch {};
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
        try self.flushAgentUi();

        if (self.agent.worker_running) {
            self.scrollChatToEnd(768);
        }

        self.conflict_check_cooldown -= dt;
        if (self.conflict_check_cooldown <= 0) {
            self.conflict_check_cooldown = 2.0;
            if (self.focused_panel != .palette and self.focused_panel != .recovery and self.focused_panel != .conflict) {
                for (self.tabs.tabs.items) |*doc| {
                    try doc.checkExternalConflict(self.io, self.workspace_root);
                }
                if (self.tabs.activeDoc()) |doc| {
                    if (doc.external_conflict) try self.openConflictDialog(doc.path);
                }
            }
        }

        self.diagnostics.tick(dt, self.tabs.activeDoc(), self.agent.worker_running);
        self.hover.tick(dt);

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
        const layout_mod = @import("ui/layout.zig");
        const panel_scroll = @import("ui/panel_scroll.zig");
        const terminal_panel = @import("ui/terminal_panel.zig");

        var w: f32 = 0;
        var h: f32 = 0;
        renderer_mod.Renderer.getWindowSize(&w, &h);
        const geo = layout_mod.compute(
            self.shell_mode,
            w,
            h,
            self.explorer_panel_width,
            self.agent_panel_width,
            self.bottom_panel_height,
        );
        const viewport = panel_scroll.bottomViewportHeight(geo.task_panel_h) - terminal_panel.session_tab_h;
        const char_w = @max(1.0, renderer_mod.Renderer.measureText("M", terminal_panel.font_size));
        const cols: u16 = @intFromFloat(@floor(@max(10.0, (geo.editor_w - terminal_panel.text_inset_x * 2) / char_w)));
        const rows: u16 = @intFromFloat(@floor(@max(3.0, viewport / panel_scroll.bottom_line_h)));
        self.activeTerminal().resize(cols, rows);
    }

    pub fn showGitDiff(self: *Workbench, path: []const u8, untracked: bool) !void {
        const diff = try git_diff_mod.fileDiff(self.allocator, self.workspace_path, path, untracked);
        defer self.allocator.free(diff);
        self.task_output.clear();
        try self.task_output.appendChunk(diff);
        self.bottom_panel_mode = .output;
        self.task_scroll_y = 0;
        try self.setStatus("Git diff");
    }

    pub fn goToDefinition(self: *Workbench) !void {
        const doc = self.tabs.activeDoc() orelse return;
        const owned = try self.lsp_registry.copyMatchForPath(self.allocator, doc.path);
        const config = owned orelse {
            try self.setStatus("No language server for this file");
            return;
        };
        defer lsp.Registry.freeConfig(self.allocator, config);

        const uri = try self.lspSyncDocument(doc);
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

    fn wordAtCursor(buf: *editor.Buffer) []const u8 {
        const line = buf.lineAt(buf.cursor.row);
        if (line.len == 0) return "";
        var start = buf.cursor.col;
        if (start >= line.len) start = line.len - 1;
        while (start > 0 and isIdentByte(line[start - 1])) start -= 1;
        var end = start;
        while (end < line.len and isIdentByte(line[end])) end += 1;
        return line[start..end];
    }

    fn isIdentByte(ch: u8) bool {
        return std.ascii.isAlphanumeric(ch) or ch == '_';
    }

    fn restoreRecoverySnapshots(self: *Workbench) !void {
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

            try recovery_mod.deleteSnapshot(self.io, self.workspace_root, snap_path);
        }
    }

    fn discardRecoverySnapshots(self: *Workbench) !void {
        const paths = try recovery_mod.listRecoveryFiles(self.allocator, self.io, self.workspace_root);
        defer {
            for (paths) |path| self.allocator.free(path);
            self.allocator.free(paths);
        }
        for (paths) |snap_path| {
            try recovery_mod.deleteSnapshot(self.io, self.workspace_root, snap_path);
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
