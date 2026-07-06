const std = @import("std");
const commands_mod = @import("commands.zig");

pub const Entry = struct {
    id: []const u8,
    title: []const u8,
    category: []const u8,
    command: commands_mod.Command,
};

pub const Palette = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,
    filtered: []usize,
    query: []u8,
    query_len: usize,
    open: bool = false,
    selected: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !Palette {
        var palette = Palette{
            .allocator = allocator,
            .entries = &.{},
            .filtered = &.{},
            .query = try allocator.alloc(u8, 256),
            .query_len = 0,
        };
        try palette.rebuildCatalog();
        try palette.applyFilter();
        return palette;
    }

    pub fn deinit(self: *Palette) void {
        self.freeCatalog();
        self.allocator.free(self.query);
        self.allocator.free(self.filtered);
    }

    pub fn openPalette(self: *Palette) !void {
        self.open = true;
        self.query_len = 0;
        self.selected = 0;
        try self.applyFilter();
    }

    pub fn close(self: *Palette) void {
        self.open = false;
        self.query_len = 0;
    }

    pub fn rebuildCatalog(self: *Palette) !void {
        self.freeCatalog();

        var list: std.ArrayList(Entry) = .empty;
        errdefer {
            for (list.items) |entry| self.freeEntry(entry);
            list.deinit(self.allocator);
        }

        const builtins = [_]Entry{
            .{ .id = "palette.open", .title = "Show Command Palette", .category = "View", .command = .palette_open },
            .{ .id = "settings.open", .title = "Preferences: Open User Settings", .category = "View", .command = .{ .open_file = ".forge/settings.toml" } },
            .{ .id = "settings.reload", .title = "Preferences: Reload Settings", .category = "View", .command = .settings_reload },
            .{ .id = "settings.word_wrap", .title = "Preferences: Toggle Word Wrap", .category = "View", .command = .settings_toggle_word_wrap },
            .{ .id = "theme.reload", .title = "Theme: Reload from forge.toml", .category = "View", .command = .reload_theme },
            .{ .id = "view.ide", .title = "View: IDE Mode", .category = "View", .command = .{ .set_shell_mode = .ide } },
            .{ .id = "view.agent", .title = "View: Agent Window", .category = "View", .command = .{ .set_shell_mode = .agent_window } },
            .{ .id = "view.toggle", .title = "View: Toggle IDE / Agent Window", .category = "View", .command = .toggle_shell_mode },
            .{ .id = "agent.context", .title = "Agent: Toggle Context Inspector", .category = "Agent", .command = .agent_toggle_context_inspector },
            .{ .id = "agent.scope", .title = "Agent: Add File to Scope (@)", .category = "Agent", .command = .agent_scope_picker_open },
            .{ .id = "agent.scope.clear", .title = "Agent: Clear Scope", .category = "Agent", .command = .agent_clear_scope },
            .{ .id = "agent.ask", .title = "Agent: Ask Mode", .category = "Agent", .command = .{ .agent_set_mode = .ask } },
            .{ .id = "agent.plan", .title = "Agent: Plan Mode", .category = "Agent", .command = .{ .agent_set_mode = .plan } },
            .{ .id = "agent.agent", .title = "Agent: Agent Mode", .category = "Agent", .command = .{ .agent_set_mode = .agent } },
            .{ .id = "agent.edit_selection", .title = "Agent: Edit Selection (Cmd+K)", .category = "Agent", .command = .agent_edit_selection },
            .{ .id = "agent.apply", .title = "Agent: Apply Proposal", .category = "Agent", .command = .agent_apply },
            .{ .id = "agent.rollback", .title = "Agent: Rollback Checkpoint", .category = "Agent", .command = .agent_rollback },
            .{ .id = "agent.reject", .title = "Agent: Reject Proposal", .category = "Agent", .command = .agent_reject },
            .{ .id = "agent.review", .title = "Agent: Review Last Proposal", .category = "Agent", .command = .agent_show_review },
            .{ .id = "agent.runs", .title = "Agent: Refresh Run History", .category = "Agent", .command = .agent_refresh_runs },
            .{ .id = "file.close", .title = "Close Active Tab", .category = "File", .command = .close_active_tab },
            .{ .id = "file.close.all", .title = "Close All Tabs", .category = "File", .command = .close_all_tabs },
            .{ .id = "file.save", .title = "Save Active File", .category = "File", .command = .save_active },
            .{ .id = "editor.find", .title = "Find in File", .category = "Edit", .command = .editor_find },
            .{ .id = "editor.replace", .title = "Replace in File", .category = "Edit", .command = .editor_replace },
            .{ .id = "editor.goto", .title = "Go to Line", .category = "Edit", .command = .editor_goto_line },
            .{ .id = "editor.definition", .title = "Go to Definition", .category = "Edit", .command = .editor_go_to_definition },
            .{ .id = "editor.references", .title = "Find All References", .category = "Edit", .command = .editor_find_references },
            .{ .id = "editor.rename", .title = "Rename Symbol", .category = "Edit", .command = .editor_rename_symbol },
            .{ .id = "editor.format", .title = "Format Document", .category = "Edit", .command = .editor_format_document },
            .{ .id = "editor.accept_inline_edit", .title = "Accept Inline Edit", .category = "Edit", .command = .editor_accept_inline_edit },
            .{ .id = "editor.reject_inline_edit", .title = "Reject Inline Edit", .category = "Edit", .command = .editor_reject_inline_edit },
            .{ .id = "problem.quick_fix", .title = "Problem: Quick Fix at Cursor", .category = "Edit", .command = .problem_quick_fix },
            .{ .id = "editor.split", .title = "Split Editor Right", .category = "Edit", .command = .editor_split_right },
            .{ .id = "editor.close_split", .title = "Close Editor Split", .category = "Edit", .command = .editor_close_split },
            .{ .id = "rename.accept", .title = "Rename: Accept Preview", .category = "Edit", .command = .rename_accept },
            .{ .id = "rename.reject", .title = "Rename: Reject Preview", .category = "Edit", .command = .rename_reject },
            .{ .id = "editor.redo", .title = "Redo", .category = "Edit", .command = .editor_redo },
            .{ .id = "editor.undo", .title = "Undo", .category = "Edit", .command = .editor_undo },
            .{ .id = "session.save", .title = "Session: Save Open Tabs", .category = "View", .command = .save_session_state },
            .{ .id = "session.restore", .title = "Session: Restore Open Tabs", .category = "View", .command = .restore_session_state },
            .{ .id = "file.reload", .title = "Reload Active File from Disk", .category = "File", .command = .reload_active_from_disk },
            .{ .id = "file.check", .title = "Check External File Changes", .category = "File", .command = .check_external_conflicts },
            .{ .id = "file.refresh", .title = "Refresh Explorer", .category = "File", .command = .refresh_explorer },
            .{ .id = "ext.reload", .title = "Reload Extensions", .category = "Extensions", .command = .reload_extensions },
            .{ .id = "view.explorer", .title = "View: Show Explorer", .category = "View", .command = .{ .set_sidebar_view = .explorer } },
            .{ .id = "view.search", .title = "View: Show Search", .category = "View", .command = .{ .set_sidebar_view = .search } },
            .{ .id = "view.git", .title = "View: Show Source Control", .category = "View", .command = .{ .set_sidebar_view = .git } },
            .{ .id = "view.run", .title = "View: Show Run and Debug", .category = "View", .command = .{ .set_sidebar_view = .run } },
            .{ .id = "view.extensions", .title = "View: Show Extensions", .category = "View", .command = .{ .set_sidebar_view = .extensions } },
            .{ .id = "view.ai", .title = "View: AI Settings", .category = "View", .command = .open_ai_settings },
            .{ .id = "view.toggle_sidebar", .title = "View: Toggle Primary Sidebar", .category = "View", .command = .toggle_sidebar },
            .{ .id = "view.toggle_panel", .title = "View: Toggle Bottom Panel", .category = "View", .command = .toggle_bottom_panel },
            .{ .id = "view.toggle_agent", .title = "View: Toggle Agent Panel", .category = "View", .command = .toggle_agent_panel },
            .{ .id = "view.focus_agent", .title = "View: Focus Agent Panel", .category = "View", .command = .focus_agent },
            .{ .id = "nav.back", .title = "Navigate: Back", .category = "Navigate", .command = .nav_back },
            .{ .id = "nav.forward", .title = "Navigate: Forward", .category = "Navigate", .command = .nav_forward },
            .{ .id = "ai.open_forge_toml", .title = "AI: Open forge.toml", .category = "AI", .command = .ai_open_forge_toml },
            .{ .id = "ai.open_mcp", .title = "AI: Open MCP Config (.mcp.json)", .category = "AI", .command = .ai_open_mcp_config },
            .{ .id = "ai.toggle_mcp", .title = "AI: Toggle MCP Tools", .category = "AI", .command = .ai_toggle_mcp },
            .{ .id = "ai.refresh_mcp", .title = "AI: Refresh MCP Status", .category = "AI", .command = .ai_refresh_mcp },
            .{ .id = "search.run", .title = "Search: Find in Workspace", .category = "Search", .command = .search_run },
            .{ .id = "git.refresh", .title = "Git: Refresh Status", .category = "Git", .command = .git_refresh },
            .{ .id = "view.output", .title = "View: Show Output Panel", .category = "View", .command = .{ .set_bottom_panel_mode = .output } },
            .{ .id = "view.problems", .title = "View: Show Problems Panel", .category = "View", .command = .{ .set_bottom_panel_mode = .problems } },
            .{ .id = "view.terminal", .title = "View: Show Terminal", .category = "View", .command = .{ .set_bottom_panel_mode = .terminal } },
            .{ .id = "terminal.new", .title = "Terminal: New", .category = "Terminal", .command = .terminal_new },
            .{ .id = "terminal.close", .title = "Terminal: Close Active", .category = "Terminal", .command = .terminal_close },
            .{ .id = "terminal.next", .title = "Terminal: Next", .category = "Terminal", .command = .terminal_next },
            .{ .id = "view.debug_console", .title = "View: Show Debug Console", .category = "View", .command = .{ .set_bottom_panel_mode = .debug_console } },
            .{ .id = "view.debug_variables", .title = "View: Show Debug Variables", .category = "View", .command = .{ .set_bottom_panel_mode = .debug_variables } },
            .{ .id = "view.debug_callstack", .title = "View: Show Call Stack", .category = "View", .command = .{ .set_bottom_panel_mode = .debug_callstack } },
            .{ .id = "debug.toggle_breakpoint", .title = "Debug: Toggle Breakpoint", .category = "Debug", .command = .debug_toggle_breakpoint },
            .{ .id = "debug.clear_breakpoints", .title = "Debug: Clear Breakpoints", .category = "Debug", .command = .debug_clear_breakpoints },
            .{ .id = "debug.continue", .title = "Debug: Continue", .category = "Debug", .command = .debug_continue },
            .{ .id = "debug.step_over", .title = "Debug: Step Over", .category = "Debug", .command = .debug_step_over },
            .{ .id = "debug.step_into", .title = "Debug: Step Into", .category = "Debug", .command = .debug_step_into },
            .{ .id = "debug.step_out", .title = "Debug: Step Out", .category = "Debug", .command = .debug_step_out },
            .{ .id = "debug.stop", .title = "Debug: Stop Session", .category = "Debug", .command = .debug_stop },
            .{ .id = "debug.clear_console", .title = "Debug: Clear Console", .category = "Debug", .command = .debug_clear_console },
            .{ .id = "ext.open.workspace", .title = "Extensions: Open Workspace Folder", .category = "Extensions", .command = .{ .open_extensions_dir = "extensions/README.md" } },
            .{ .id = "ext.open.user", .title = "Extensions: Open User Folder", .category = "Extensions", .command = .{ .open_extensions_dir = ".forge/extensions/README.md" } },
            .{ .id = "ext.marketplace", .title = "Extensions: Show Marketplace", .category = "Extensions", .command = .{ .set_extensions_panel_mode = .marketplace } },
            .{ .id = "ext.installed", .title = "Extensions: Show Installed", .category = "Extensions", .command = .{ .set_extensions_panel_mode = .installed } },
            .{ .id = "task.test", .title = "Run: zig build test", .category = "Tasks", .command = .{ .run_task = "test" } },
            .{ .id = "task.check", .title = "Run: ./scripts/check.sh", .category = "Tasks", .command = .{ .run_task = "check" } },
        };

        for (builtins) |entry| {
            try list.append(self.allocator, .{
                .id = try self.allocator.dupe(u8, entry.id),
                .title = try self.allocator.dupe(u8, entry.title),
                .category = try self.allocator.dupe(u8, entry.category),
                .command = try dupCommand(self.allocator, entry.command),
            });
        }

        self.entries = try list.toOwnedSlice(self.allocator);
    }

    pub fn addRecentWorkspaces(self: *Palette, paths: []const []const u8) !void {
        var list: std.ArrayList(Entry) = .empty;
        errdefer {
            for (list.items) |entry| self.freeEntry(entry);
            list.deinit(self.allocator);
        }

        for (self.entries) |entry| {
            if (std.mem.startsWith(u8, entry.id, "recent.")) continue;
            try list.append(self.allocator, .{
                .id = try self.allocator.dupe(u8, entry.id),
                .title = try self.allocator.dupe(u8, entry.title),
                .category = try self.allocator.dupe(u8, entry.category),
                .command = try dupCommand(self.allocator, entry.command),
            });
        }

        for (paths, 0..) |path, index| {
            const base = std.fs.path.basename(path);
            const title = try std.fmt.allocPrint(self.allocator, "Open Recent: {s}", .{base});
            errdefer self.allocator.free(title);
            const id = try std.fmt.allocPrint(self.allocator, "recent.{d}", .{index});
            errdefer self.allocator.free(id);
            try list.append(self.allocator, .{
                .id = id,
                .title = title,
                .category = try self.allocator.dupe(u8, "File"),
                .command = .{ .open_recent_workspace = index },
            });
        }

        self.freeCatalog();
        self.entries = try list.toOwnedSlice(self.allocator);
        try self.applyFilter();
    }

    pub fn addExtensionCommands(self: *Palette, host: *const @import("forge-plugin").Host) !void {
        var list: std.ArrayList(Entry) = .empty;
        errdefer {
            for (list.items) |entry| self.freeEntry(entry);
            list.deinit(self.allocator);
        }

        for (self.entries) |entry| {
            try list.append(self.allocator, .{
                .id = try self.allocator.dupe(u8, entry.id),
                .title = try self.allocator.dupe(u8, entry.title),
                .category = try self.allocator.dupe(u8, entry.category),
                .command = try dupCommand(self.allocator, entry.command),
            });
        }

        for (host.extensions.items) |ext| {
            if (!ext.active) continue;
            for (ext.commands.items) |cmd| {
                const title = try std.fmt.allocPrint(self.allocator, "{s}", .{cmd.title});
                errdefer self.allocator.free(title);
                const id = try std.fmt.allocPrint(self.allocator, "ext.{s}", .{cmd.id});
                errdefer self.allocator.free(id);
                try list.append(self.allocator, .{
                    .id = id,
                    .title = title,
                    .category = try self.allocator.dupe(u8, "Extensions"),
                    .command = .{ .run_extension_command = try self.allocator.dupe(u8, cmd.id) },
                });
            }
        }

        self.freeCatalog();
        self.entries = try list.toOwnedSlice(self.allocator);
    }

    pub fn addContributionCommands(self: *Palette, host: *const @import("forge-plugin").Host) !void {
        var list: std.ArrayList(Entry) = .empty;
        errdefer {
            for (list.items) |entry| self.freeEntry(entry);
            list.deinit(self.allocator);
        }

        for (self.entries) |entry| {
            try list.append(self.allocator, .{
                .id = try self.allocator.dupe(u8, entry.id),
                .title = try self.allocator.dupe(u8, entry.title),
                .category = try self.allocator.dupe(u8, entry.category),
                .command = try dupCommand(self.allocator, entry.command),
            });
        }

        for (host.contributions.themes.items) |theme| {
            const qualified = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ theme.extension_id, theme.id });
            errdefer self.allocator.free(qualified);
            const title = try std.fmt.allocPrint(self.allocator, "Theme: {s}", .{theme.label});
            errdefer self.allocator.free(title);
            const id = try std.fmt.allocPrint(self.allocator, "theme.{s}.{s}", .{ theme.extension_id, theme.id });
            errdefer self.allocator.free(id);
            try list.append(self.allocator, .{
                .id = id,
                .title = title,
                .category = try self.allocator.dupe(u8, "Themes"),
                .command = .{ .apply_extension_theme = qualified },
            });
        }

        self.freeCatalog();
        self.entries = try list.toOwnedSlice(self.allocator);
    }

    fn dupCommand(allocator: std.mem.Allocator, command: commands_mod.Command) !commands_mod.Command {
        return switch (command) {
            .run_extension_command => |owned| .{ .run_extension_command = try allocator.dupe(u8, owned) },
            .run_task => |owned| .{ .run_task = try allocator.dupe(u8, owned) },
            .open_extensions_dir => |owned| .{ .open_extensions_dir = try allocator.dupe(u8, owned) },
            .install_marketplace_extension => |owned| .{ .install_marketplace_extension = try allocator.dupe(u8, owned) },
            .apply_extension_theme => |owned| .{ .apply_extension_theme = try allocator.dupe(u8, owned) },
            .explorer_create_file => |name| .{ .explorer_create_file = try allocator.dupe(u8, name) },
            .explorer_create_folder => |name| .{ .explorer_create_folder = try allocator.dupe(u8, name) },
            .explorer_rename => |payload| .{
                .explorer_rename = .{
                    .path = payload.path,
                    .new_name = try allocator.dupe(u8, payload.new_name),
                },
            },
            else => command,
        };
    }

    fn freeEntry(self: *Palette, entry: Entry) void {
        self.allocator.free(entry.id);
        self.allocator.free(entry.title);
        self.allocator.free(entry.category);
        switch (entry.command) {
            .run_extension_command, .run_task, .open_extensions_dir, .install_marketplace_extension, .apply_extension_theme => |owned| self.allocator.free(owned),
            .explorer_create_file, .explorer_create_folder => |name| self.allocator.free(name),
            .explorer_rename => |payload| self.allocator.free(payload.new_name),
            else => {},
        }
    }

    fn freeCatalog(self: *Palette) void {
        for (self.entries) |entry| self.freeEntry(entry);
        self.allocator.free(self.entries);
        self.entries = &.{};
    }

    pub fn applyFilter(self: *Palette) !void {
        self.allocator.free(self.filtered);
        var indices: std.ArrayList(usize) = .empty;
        errdefer indices.deinit(self.allocator);

        const q = self.query[0..self.query_len];
        for (self.entries, 0..) |entry, index| {
            if (q.len == 0 or matchesQuery(q, entry.title) or matchesQuery(q, entry.category) or matchesQuery(q, entry.id)) {
                try indices.append(self.allocator, index);
            }
        }

        self.filtered = try indices.toOwnedSlice(self.allocator);
        if (self.selected >= self.filtered.len) self.selected = if (self.filtered.len > 0) self.filtered.len - 1 else 0;
    }

    pub fn insertChar(self: *Palette, text: []const u8) !void {
        for (text) |c| {
            if (self.query_len >= self.query.len) return;
            if (c < 32 and c != ' ') continue;
            self.query[self.query_len] = c;
            self.query_len += 1;
        }
        self.selected = 0;
        try self.applyFilter();
    }

    pub fn backspace(self: *Palette) !void {
        if (self.query_len == 0) return;
        self.query_len -= 1;
        self.selected = 0;
        try self.applyFilter();
    }

    pub fn moveSelection(self: *Palette, delta: i32) void {
        if (self.filtered.len == 0) return;
        const next = @as(i64, @intCast(self.selected)) + delta;
        if (next < 0) {
            self.selected = 0;
        } else if (next >= self.filtered.len) {
            self.selected = self.filtered.len - 1;
        } else {
            self.selected = @intCast(next);
        }
    }

    pub fn selectedEntry(self: *const Palette) ?Entry {
        if (self.filtered.len == 0) return null;
        return self.entries[self.filtered[self.selected]];
    }

    pub fn querySlice(self: *const Palette) []const u8 {
        return self.query[0..self.query_len];
    }
};

fn matchesQuery(query: []const u8, haystack: []const u8) bool {
    if (query.len == 0) return true;
    var h_index: usize = 0;
    for (query) |q| {
        const lower_q = std.ascii.toLower(q);
        while (h_index < haystack.len) : (h_index += 1) {
            if (std.ascii.toLower(haystack[h_index]) == lower_q) {
                h_index += 1;
                break;
            }
        } else return false;
    }
    return true;
}

test "palette fuzzy filter matches title" {
    const allocator = std.testing.allocator;
    var palette = try Palette.init(allocator);
    defer palette.deinit();

    palette.query_len = 3;
    @memcpy(palette.query[0..3], "sav");
    try palette.applyFilter();
    try std.testing.expect(palette.filtered.len >= 1);
}
