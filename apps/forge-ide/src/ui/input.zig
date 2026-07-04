const std = @import("std");
const renderer = @import("forge-renderer");
const state = @import("state.zig");
const layout = @import("layout.zig");
const editor_scroll = @import("editor_scroll.zig");
const activity_bar = @import("activity_bar.zig");
const search_panel = @import("search_panel.zig");
const debug_panel = @import("debug_panel.zig");
const git_panel = @import("git_panel.zig");
const extensions_panel = @import("extensions_panel.zig");
const plugin = @import("forge-plugin");
const explorer_scroll = @import("explorer_scroll.zig");
const tabs_ui = @import("tabs.zig");
const keybindings_mod = @import("../keybindings.zig");
const terminal_session_mod = @import("../workbench/terminal_session.zig");
const terminal_panel = @import("terminal_panel.zig");
const bottom_panel = @import("bottom_panel.zig");

const cmd_mask: i32 = 0x08;
const shift_mask: i32 = 0x02;

fn canUninstallExtensionIndex(ext_index: usize) bool {
    const wb = state.wb orelse return false;
    if (ext_index >= wb.extension_host.extensions.items.len) return false;
    return wb.canUninstallExtension(&wb.extension_host.extensions.items[ext_index]);
}

fn dispatchWorkbenchCommand(command: @import("../workbench/commands.zig").Command) anyerror!void {
    const wb = state.wb orelse return;
    try wb.dispatch(command);
}

pub fn onKeyEvent(event: renderer.KeyEvent) void {
    if (!event.is_down) return;
    const wb = state.wb orelse return;

    var win_h: f32 = 768;
    var win_w: f32 = 1024;
    renderer.Renderer.getWindowSize(&win_w, &win_h);

    if (wb.focused_panel == .recovery) {
        handleRecoveryKeys(wb, event);
        return;
    }

    if (wb.focused_panel == .conflict) {
        handleConflictKeys(wb, event);
        return;
    }

    if (wb.focused_panel == .palette) {
        handlePaletteKeys(wb, event);
        return;
    }

    if (wb.focused_panel == .find) {
        handleFindKeys(wb, event);
        return;
    }

    if (wb.focused_panel == .goto_line) {
        handleGotoKeys(wb, event);
        return;
    }

    if (wb.focused_panel == .rename) {
        handleSymbolRenameKeys(wb, event);
        return;
    }

    if (wb.completions.visible and (event.keycode == 48 or event.keycode == 36)) {
        wb.dispatch(.completion_accept) catch {};
        return;
    }

    if (wb.completions.visible and event.keycode == 53) {
        wb.dispatch(.completion_dismiss) catch {};
        return;
    }

    if (wb.completions.visible and event.keycode == 125) {
        wb.completions.moveSelection(1);
        return;
    }
    if (wb.completions.visible and event.keycode == 126) {
        wb.completions.moveSelection(-1);
        return;
    }

    if (wb.agent.scope_picker_open) {
        handleScopePickerKeys(wb, event);
        return;
    }

    if (wb.renaming) {
        handleRenameKeys(wb, event);
        return;
    }

    if (wb.focused_panel == .search) {
        handleSearchKeys(wb, event);
        return;
    }

    if (wb.bottom_panel_mode == .terminal) {
        wb.focused_panel = .terminal;
        handleTerminalKeys(wb, event);
        return;
    }

    if (wb.focused_panel == .terminal) {
        handleTerminalKeys(wb, event);
        return;
    }

    if (wb.focused_panel == .extensions) {
        handleExtensionsFilterKeys(wb, event);
        return;
    }

    if (wb.focused_panel == .agent and wb.agent.show_review) {
        if (event.keycode == 36 and event.modifiers & cmd_mask != 0) {
            wb.dispatch(.agent_apply) catch {};
            return;
        }
        if (event.keycode == 53) {
            wb.dispatch(.agent_reject) catch {};
            return;
        }
        const scroll_step: f32 = 14.0;
        if (event.keycode == 126) {
            wb.agent.review_scroll_y = @max(0, wb.agent.review_scroll_y - scroll_step);
            wb.clampReviewScroll(win_h);
            return;
        }
        if (event.keycode == 125) {
            wb.agent.review_scroll_y += scroll_step;
            wb.clampReviewScroll(win_h);
            return;
        }
    }

    const ctrl_mask: i32 = 0x01;
    if (event.keycode == 49 and event.modifiers & ctrl_mask != 0 and wb.focused_panel == .editor) {
        wb.dispatch(.editor_completion) catch {};
        return;
    }

    if (event.keycode == 35 and (event.modifiers & (cmd_mask | shift_mask)) == (cmd_mask | shift_mask)) {
        wb.dispatch(.palette_open) catch {};
        return;
    }

    if (keybindings_mod.Registry.dispatch(&wb.keybindings, &wb.palette, event, dispatchWorkbenchCommand)) {
        return;
    }

    if (event.keycode == 4 and event.modifiers & cmd_mask != 0) {
        wb.dispatch(.{ .run_extension_command = "hello.say" }) catch {};
        return;
    }

    if (event.keycode == 8 and event.modifiers & cmd_mask != 0 and wb.focused_panel == .agent) {
        wb.dispatch(.agent_cancel) catch {};
        return;
    }

    if (event.keycode == 53 and event.modifiers & cmd_mask == 0) {
        wb.dispatch(.palette_close) catch {};
    }

    if (event.keycode == 120 and wb.focused_panel == .explorer) {
        wb.dispatch(.explorer_begin_rename) catch {};
        return;
    }

    var active_buffer = if (wb.focused_panel == .editor)
        wb.activeBuffer() orelse return
    else
        &wb.prompt_buffer;

    if (event.keycode == 13 and event.modifiers & cmd_mask != 0) {
        wb.dispatch(.close_active_tab) catch {};
        return;
    }

    if (event.keycode == 1 and event.modifiers & cmd_mask != 0) {
        if (wb.focused_panel == .editor) {
            wb.dispatch(.save_active) catch {};
        } else if (wb.focused_panel == .explorer) {
            var name_buf: [32]u8 = undefined;
            const name = wb.nextUntitledName(&name_buf);
            wb.dispatch(.{ .explorer_create_file = name }) catch {};
        }
        return;
    }

    if (wb.focused_panel == .explorer and event.keycode == 51) {
        wb.dispatch(.explorer_delete_selected) catch {};
        return;
    }

    if (wb.focused_panel == .explorer and event.keycode == 36) {
        if (wb.explorer.selected_path) |path| {
            if (wb.explorerKind(path)) |kind| {
                switch (kind) {
                    .directory => wb.dispatch(.{ .explorer_toggle = path }) catch {},
                    .file => {
                        wb.dispatch(.{ .open_file = path }) catch {};
                        wb.focused_panel = .editor;
                    },
                    else => {},
                }
            }
        }
        return;
    }

    if (event.keycode == 6 and event.modifiers & cmd_mask != 0 and wb.focused_panel == .editor) {
        active_buffer.undo() catch {};
        return;
    }

    if (event.keycode == 6 and event.modifiers & (cmd_mask | shift_mask) == (cmd_mask | shift_mask) and wb.focused_panel == .editor) {
        active_buffer.redo() catch {};
        return;
    }

    if (wb.focused_panel == .explorer) return;
    if (wb.focused_panel == .extensions) return;
    if (wb.focused_panel == .search) return;
    if (wb.focused_panel == .git) return;
    if (wb.focused_panel == .run) return;

    if (event.keycode == 51) {
        active_buffer.backspace() catch {};
    } else if (event.keycode == 36) {
        if (wb.focused_panel == .agent) {
            submitAgentPrompt(wb);
        } else {
            active_buffer.insertNewline() catch {};
        }
    } else if (event.keycode == 123) {
        active_buffer.moveLeft();
    } else if (event.keycode == 124) {
        active_buffer.moveRight();
    } else if (event.keycode == 125) {
        active_buffer.moveDown();
    } else if (event.keycode == 126) {
        active_buffer.moveUp();
    } else if (event.chars.len > 0) {
        const char_val = event.chars[0];
        if (wb.focused_panel == .agent and char_val == '@' and !wb.agent.show_review) {
            wb.dispatch(.agent_scope_picker_open) catch {};
            return;
        }
        if (char_val >= 32 or char_val == '\t') {
            active_buffer.insertString(event.chars) catch {};
        }
    }
}

fn handleScopePickerKeys(wb: *@import("../workbench.zig").Workbench, event: renderer.KeyEvent) void {
    if (event.keycode == 53) {
        wb.dispatch(.agent_scope_picker_close) catch {};
        return;
    }
    if (event.keycode == 36) {
        wb.dispatch(.agent_scope_picker_select) catch {};
        return;
    }
    if (event.keycode == 125) {
        wb.agent.lock();
        if (wb.scope_picker_filtered.items.len > 0) {
            wb.agent.scope_picker_selected +%= 1;
            if (wb.agent.scope_picker_selected >= wb.scope_picker_filtered.items.len) {
                wb.agent.scope_picker_selected = wb.scope_picker_filtered.items.len - 1;
            }
        }
        wb.agent.unlock();
        return;
    }
    if (event.keycode == 126) {
        wb.agent.lock();
        if (wb.agent.scope_picker_selected > 0) wb.agent.scope_picker_selected -= 1;
        wb.agent.unlock();
        return;
    }
    if (event.keycode == 51) {
        wb.agent.lock();
        if (wb.agent.scope_query_len > 0) wb.agent.scope_query_len -= 1;
        wb.agent.unlock();
        wb.applyScopePickerFilter() catch {};
        return;
    }
    if (event.chars.len > 0 and event.chars[0] >= 32) {
        wb.agent.lock();
        if (wb.agent.scope_query_len < wb.agent.scope_query.len) {
            wb.agent.scope_query[wb.agent.scope_query_len] = event.chars[0];
            wb.agent.scope_query_len += 1;
        }
        wb.agent.unlock();
        wb.applyScopePickerFilter() catch {};
    }
}

fn handleConflictKeys(wb: *@import("../workbench.zig").Workbench, event: renderer.KeyEvent) void {
    if (event.keycode == 36) {
        wb.dispatch(.reload_active_from_disk) catch {};
        return;
    }
    if (event.keycode == 53) {
        wb.dispatch(.dismiss_external_conflict) catch {};
    }
}

fn handleRecoveryKeys(wb: *@import("../workbench.zig").Workbench, event: renderer.KeyEvent) void {
    if (event.keycode == 36) {
        wb.dispatch(.restore_recovery_snapshots) catch {};
        return;
    }
    if (event.keycode == 53) {
        wb.dispatch(.discard_recovery_snapshots) catch {};
    }
}

fn handlePaletteKeys(wb: *@import("../workbench.zig").Workbench, event: renderer.KeyEvent) void {
    if (event.keycode == 53) {
        wb.dispatch(.palette_close) catch {};
        return;
    }
    if (event.keycode == 36) {
        wb.executePaletteSelection() catch {};
        return;
    }
    if (event.keycode == 125) {
        wb.palette.moveSelection(1);
        return;
    }
    if (event.keycode == 126) {
        wb.palette.moveSelection(-1);
        return;
    }
    if (event.keycode == 51) {
        wb.palette.backspace() catch {};
        return;
    }
    if (event.chars.len > 0 and event.chars[0] >= 32) {
        wb.palette.insertChar(event.chars) catch {};
    }
}

fn handleTerminalKeys(wb: *@import("../workbench.zig").Workbench, event: renderer.KeyEvent) void {
    if (event.keycode == 8 and event.modifiers & cmd_mask != 0) {
        wb.copyTerminalSelection() catch {};
        return;
    }

    if (wb.terminal_selection != null) {
        wb.terminal_selection = null;
    }

    var buf: [64]u8 = undefined;
    const bytes = terminal_session_mod.TerminalSession.encodeKey(event, &buf) orelse return;
    wb.terminal.writeInput(bytes);
    if (bytes.len == 1 and bytes[0] == '\r') {
        wb.dispatch(.terminal_submit) catch {};
    }
}

fn handleSearchKeys(wb: *@import("../workbench.zig").Workbench, event: renderer.KeyEvent) void {
    if (event.keycode == 36) {
        wb.dispatch(.search_run) catch {};
        return;
    }
    if (event.keycode == 51) {
        wb.search_buffer.backspace() catch {};
        return;
    }
    if (event.chars.len > 0 and event.chars[0] >= 32) {
        wb.search_buffer.insertString(event.chars) catch {};
    }
}

fn handleExtensionsFilterKeys(wb: *@import("../workbench.zig").Workbench, event: renderer.KeyEvent) void {
    if (event.keycode == 51) {
        if (wb.extensions_filter_len > 0) wb.extensions_filter_len -= 1;
        return;
    }
    if (event.chars.len > 0 and event.chars[0] >= 32 and wb.extensions_filter_len < wb.extensions_filter.len) {
        wb.extensions_filter[wb.extensions_filter_len] = event.chars[0];
        wb.extensions_filter_len += 1;
    }
}

fn handleFindKeys(wb: *@import("../workbench.zig").Workbench, event: renderer.KeyEvent) void {
    if (event.keycode == 53) {
        wb.closeEditorOverlay();
        return;
    }
    if (event.keycode == 36) {
        if (wb.find_bar.replace_mode) {
            if (wb.activeBuffer()) |buf| {
                wb.find_bar.replaceCurrent(buf) catch {};
                wb.scrollEditorToCursor();
            }
        } else {
            wb.dispatch(.editor_find_next) catch {};
        }
        return;
    }
    if (event.keycode == 14 and event.modifiers & cmd_mask != 0) {
        wb.dispatch(.editor_find_next) catch {};
        return;
    }
    if (event.keycode == 14 and event.modifiers & (cmd_mask | shift_mask) == (cmd_mask | shift_mask)) {
        wb.dispatch(.editor_find_prev) catch {};
        return;
    }
    if (event.keycode == 48 and wb.find_bar.replace_mode) {
        wb.find_bar.focus_replace = !wb.find_bar.focus_replace;
        return;
    }
    const active_buf = if (wb.find_bar.replace_mode and wb.find_bar.focus_replace)
        &wb.find_bar.replace
    else
        &wb.find_bar.query;
    if (event.keycode == 51) {
        active_buf.backspace() catch {};
        if (!wb.find_bar.focus_replace) {
            if (wb.activeBuffer()) |buf| wb.find_bar.refreshMatches(buf) catch {};
        }
        return;
    }
    if (event.chars.len > 0 and event.chars[0] >= 32) {
        active_buf.insertString(event.chars) catch {};
        if (!wb.find_bar.focus_replace) {
            if (wb.activeBuffer()) |buf| wb.find_bar.refreshMatches(buf) catch {};
        }
    }
}

fn handleGotoKeys(wb: *@import("../workbench.zig").Workbench, event: renderer.KeyEvent) void {
    if (event.keycode == 53) {
        wb.closeEditorOverlay();
        return;
    }
    if (event.keycode == 36) {
        wb.commitGotoLine() catch {};
        return;
    }
    const input_buf = &wb.goto_bar.input;
    if (event.keycode == 51) {
        input_buf.backspace() catch {};
        return;
    }
    if (event.chars.len > 0 and event.chars[0] >= 32) {
        input_buf.insertString(event.chars) catch {};
    }
}

fn handleSymbolRenameKeys(wb: *@import("../workbench.zig").Workbench, event: renderer.KeyEvent) void {
    if (event.keycode == 53) {
        wb.closeEditorOverlay();
        return;
    }
    if (event.keycode == 36) {
        wb.commitRenameSymbol() catch {};
        return;
    }
    const input_buf = &wb.rename_bar.input;
    if (event.keycode == 51) {
        input_buf.backspace() catch {};
        return;
    }
    if (event.chars.len > 0 and event.chars[0] >= 32) {
        input_buf.insertString(event.chars) catch {};
    }
}

fn handleRenameKeys(wb: *@import("../workbench.zig").Workbench, event: renderer.KeyEvent) void {
    if (event.keycode == 53) {
        wb.cancelRename();
        return;
    }
    if (event.keycode == 36) {
        wb.commitRename() catch {};
        return;
    }
    if (event.keycode == 51) {
        wb.rename_buffer.backspace() catch {};
        return;
    }
    if (event.chars.len > 0 and event.chars[0] >= 32) {
        wb.rename_buffer.insertString(event.chars) catch {};
    }
}

fn submitAgentPrompt(wb: *@import("../workbench.zig").Workbench) void {
    const prompt_text = wb.prompt_buffer.toDisplayString(false) catch return;
    defer state.gpa.free(prompt_text);
    if (prompt_text.len == 0) return;
    const text_len = if (prompt_text[prompt_text.len - 1] == 0) prompt_text.len - 1 else prompt_text.len;
    if (text_len == 0) return;
    if (wb.agent.worker_running) return;

    wb.dispatch(.agent_submit) catch {};
    state.prompt_buffer = &wb.prompt_buffer;
}

fn editorPosAt(
    wb: *@import("../workbench.zig").Workbench,
    editor_buf: *@import("forge-editor").Buffer,
    geo: layout.Geometry,
    x: f32,
    y: f32,
) ?struct { row: usize, col: usize } {
    const click_y = y - editor_scroll.firstLineY(&wb.theme) + wb.editor_scroll_y;
    const click_x = x - geo.editor_x - editor_scroll.gutterWidth(&wb.theme) + wb.editor_scroll_x;
    if (click_y < 0) return null;
    var row: usize = @intFromFloat(click_y / editor_scroll.lineHeight(&wb.theme));
    if (row >= editor_buf.lineCount()) row = if (editor_buf.lineCount() > 0) editor_buf.lineCount() - 1 else 0;
    const line = editor_buf.lineAt(row);
    const col = editor_scroll.columnAtX(line, click_x, wb.theme.editor_font_size);
    return .{ .row = row, .col = col };
}

fn isEditorContentArea(geo: layout.Geometry, x: f32, y: f32) bool {
    return x >= geo.editor_x and x < geo.agent_splitter_x and y > 65.0 and y < geo.task_panel_y - 35;
}

pub fn onMouseEvent(event: renderer.MouseEvent) void {
    const wb = state.wb orelse return;
    const editor_buf = wb.activeBuffer();

    var w: f32 = 0;
    var h: f32 = 0;
    renderer.Renderer.getWindowSize(&w, &h);
    const geo = layout.compute(wb.shell_mode, w, h, wb.explorer_panel_width, wb.agent_panel_width, wb.bottom_panel_height);

    const is_near_explorer_splitter = geo.shell_mode == .ide and @abs(event.x - geo.explorer_splitter_x) < 5.0;
    const is_near_agent_splitter = geo.shell_mode == .ide and @abs(event.x - geo.agent_splitter_x) < 5.0;
    const is_near_bottom_splitter = geo.shell_mode == .ide and
        event.x >= geo.editor_x and event.x < geo.agent_splitter_x and
        event.y >= geo.task_panel_y and event.y < geo.task_panel_y + 4.0;

    if (event.action == .move or event.action == .down or event.action == .drag) {
        state.last_mouse_x = event.x;
        state.last_mouse_y = event.y;
    }

    if (event.action == .move) {
        if (is_near_agent_splitter or is_near_explorer_splitter) {
            renderer.Renderer.setCursor(2);
        } else if (is_near_bottom_splitter) {
            renderer.Renderer.setCursor(3);
        } else {
            renderer.Renderer.setCursor(0);
        }
        if (geo.shell_mode == .ide and isEditorContentArea(geo, event.x, event.y)) {
            if (editor_buf != null) {
                if (wb.tabs.activeDoc()) |doc| {
                    if (editorPosAt(wb, editor_buf.?, geo, event.x, event.y)) |pos| {
                        wb.requestEditorHover(doc.path, pos.row, pos.col, event.x, event.y);
                    }
                }
            }
        } else {
            wb.hover.clear();
        }
    } else if (event.action == .down) {
        if (wb.palette.open) return;
        if (is_near_agent_splitter) {
            state.is_dragging_agent_splitter = true;
        } else if (is_near_explorer_splitter) {
            state.is_dragging_explorer_splitter = true;
        } else if (is_near_bottom_splitter) {
            state.is_dragging_bottom_panel_splitter = true;
        } else if (event.x < layout.activity_bar_width and event.y >= layout.header_height) {
            if (activity_bar.hitTest(event.x, event.y)) |view| {
                wb.dispatch(.{ .set_sidebar_view = view }) catch {};
            }
        } else if (geo.shell_mode == .ide and wb.sidebar_view == .extensions and event.x >= geo.explorer_x and event.x < geo.explorer_splitter_x and event.y >= extensions_panel.list_top) {
            wb.focused_panel = .extensions;
            const catalog_ptr: ?*const plugin.MarketplaceCatalog = if (wb.marketplace_catalog) |*catalog| catalog else null;
            if (extensions_panel.hitTest(
                &wb.extension_host,
                catalog_ptr,
                wb.extensions_panel_mode,
                geo.explorer_x,
                geo.explorer_w,
                event.x,
                event.y,
                wb.extensions_scroll_y,
                wb.extensionsFilterSlice(),
                wb.extensions_detail_index,
                canUninstallExtensionIndex,
            )) |hit| {
                wb.handleExtensionsClick(hit) catch {};
            }
        } else if (geo.shell_mode == .ide and wb.sidebar_view == .search and event.x >= geo.explorer_x and event.x < geo.explorer_splitter_x and event.y >= search_panel.list_top - 40) {
            wb.focused_panel = .search;
            if (search_panel.hitTest(
                if (wb.search_results) |results| results.matches else &.{},
                geo.explorer_x,
                geo.explorer_w,
                event.x,
                event.y,
                wb.search_scroll_y,
            )) |hit| {
                wb.handleSearchClick(hit) catch {};
            }
        } else if (geo.shell_mode == .ide and wb.sidebar_view == .git and event.x >= geo.explorer_x and event.x < geo.explorer_splitter_x and event.y >= git_panel.list_top - 40) {
            wb.focused_panel = .git;
            if (git_panel.hitTest(
                if (wb.git_status) |status| status.entries else &.{},
                geo.explorer_x,
                geo.explorer_w,
                event.x,
                event.y,
                wb.git_scroll_y,
            )) |hit| {
                wb.handleGitClick(hit) catch {};
            }
        } else if (geo.shell_mode == .ide and wb.sidebar_view == .run and event.x >= geo.explorer_x and event.x < geo.explorer_splitter_x and event.y >= debug_panel.list_top - 40) {
            wb.focused_panel = .run;
            if (debug_panel.hitTest(
                geo.explorer_x,
                geo.explorer_w,
                event.x,
                event.y,
                wb.run_scroll_y,
                wb.breakpoints.items.items.len,
            )) |hit| {
                wb.handleDebugClick(hit) catch {};
            }
        } else if (geo.shell_mode == .ide and wb.sidebar_view == .explorer and event.x >= geo.explorer_x and event.x < geo.explorer_splitter_x and event.y >= explorer_scroll.list_top) {
            wb.focused_panel = .explorer;
            const float_row = (event.y - explorer_scroll.list_top + wb.explorer_scroll_y) / explorer_scroll.row_height;
            if (float_row >= 0) {
                const click_row: usize = @intFromFloat(float_row);
                wb.handleExplorerClick(click_row, event.x, geo.explorer_x) catch {};
            }
        } else if (geo.shell_mode == .ide and event.x >= geo.agent_x) {
            wb.focused_panel = .agent;
            const agent_panel = @import("agent_panel.zig");
            wb.agent.lock();
            const run_count = wb.agent.run_history.items.len;
            wb.agent.unlock();
            if (agent_panel.hitTestRun(geo.agent_x, 20, event.y, run_count)) |index| {
                wb.dispatch(.{ .agent_select_run = index }) catch {};
            }
        } else if (event.x >= geo.agent_x) {
            wb.focused_panel = .agent;
        } else if (geo.shell_mode == .ide and event.x >= geo.editor_x and event.x < geo.agent_splitter_x and event.y >= tabs_ui.tab_bar_top and event.y < tabs_ui.tab_bar_top + tabs_ui.tab_bar_height) {
            wb.focused_panel = .editor;
            var tab_layouts: std.ArrayList(tabs_ui.TabLayout) = .empty;
            defer tab_layouts.deinit(state.gpa);
            tabs_ui.collectLayouts(wb, geo.editor_x, &tab_layouts) catch {};
            switch (tabs_ui.hitTest(tab_layouts.items, event.x, event.y)) {
                .close => |index| wb.dispatch(.{ .close_tab = index }) catch {},
                .activate => |index| wb.dispatch(.{ .activate_tab = index }) catch {},
                .none => {},
            }
        } else if (geo.shell_mode == .ide and isEditorContentArea(geo, event.x, event.y)) {
            wb.focused_panel = .editor;
            if (editor_buf != null) {
                if (editorPosAt(wb, editor_buf.?, geo, event.x, event.y)) |pos| {
                    editor_buf.?.cursor.row = pos.row;
                    editor_buf.?.cursor.col = pos.col;
                    wb.scrollEditorToCursor();
                    if (event.modifiers & cmd_mask != 0) {
                        wb.goToDefinition() catch {};
                        return;
                    }
                }
            }
        } else if (geo.shell_mode == .ide and event.y >= geo.task_panel_y) {
            if (bottom_panel.hitTab(geo.editor_x, geo.task_panel_y, event.x, event.y)) |mode| {
                wb.dispatch(.{ .set_bottom_panel_mode = mode }) catch {};
            } else if (wb.bottom_panel_mode == .terminal and bottom_panel.inContentArea(geo.task_panel_y, event.y)) {
                wb.focused_panel = .terminal;
                wb.terminal.lock();
                defer wb.terminal.unlock();
                if (terminal_panel.hitTest(
                    geo.editor_x,
                    geo.task_panel_y,
                    geo.task_panel_h,
                    event.x,
                    event.y,
                    wb.task_scroll_y,
                    wb.terminal.lines.items,
                )) |pos| {
                    wb.focused_panel = .terminal;
                    wb.terminal_selection = .{ .anchor = pos, .cursor = pos };
                    state.is_dragging_terminal_selection = true;
                } else {
                    wb.focused_panel = .terminal;
                    wb.terminal_selection = null;
                }
            } else if (bottom_panel.inContentArea(geo.task_panel_y, event.y)) {
                if (wb.bottom_panel_mode == .output and wb.references.active) {
                    const references_panel = @import("../workbench/references_store.zig");
                    if (references_panel.Store.hitTest(
                        geo.editor_x,
                        geo.task_panel_y,
                        geo.task_panel_h,
                        event.x,
                        event.y,
                        wb.task_scroll_y,
                        wb.references.items.len,
                    )) |index| {
                        wb.dispatch(.{ .references_goto = index }) catch {};
                    }
                } else if (wb.bottom_panel_mode == .problems) {
                    const problems_panel = @import("problems_panel.zig");
                    if (problems_panel.hitTest(
                        geo.editor_x,
                        geo.task_panel_y,
                        geo.task_panel_h,
                        event.x,
                        event.y,
                        wb.task_scroll_y,
                        wb.diagnostics.list.items.len,
                    )) |index| {
                        wb.handleProblemsClick(index) catch {};
                    }
                }
                wb.focused_panel = .editor;
            } else {
                wb.focused_panel = .editor;
            }
        }
    } else if (event.action == .up) {
        state.is_dragging_agent_splitter = false;
        state.is_dragging_explorer_splitter = false;
        state.is_dragging_bottom_panel_splitter = false;
        if (state.is_dragging_terminal_selection) {
            state.is_dragging_terminal_selection = false;
            if (wb.terminal_selection) |sel| {
                if (sel.isEmpty()) wb.terminal_selection = null;
            }
        }
    } else if (event.action == .drag) {
        if (state.is_dragging_agent_splitter) {
            wb.agent_panel_width = w - event.x;
            wb.agent_panel_width = @max(200.0, @min(800.0, wb.agent_panel_width));
        } else if (state.is_dragging_explorer_splitter) {
            wb.explorer_panel_width = event.x - layout.activity_bar_width;
            wb.explorer_panel_width = @max(100.0, @min(500.0, wb.explorer_panel_width));
        } else if (state.is_dragging_bottom_panel_splitter) {
            const new_editor_h = event.y - layout.header_height;
            wb.bottom_panel_height = std.math.clamp(
                geo.content_h - new_editor_h,
                80.0,
                @max(80.0, geo.content_h - 80.0),
            );
            wb.clampBottomPanelScroll(wb.bottom_panel_height);
            wb.syncTerminalSize();
        } else if (state.is_dragging_terminal_selection and wb.bottom_panel_mode == .terminal) {
            wb.terminal.lock();
            defer wb.terminal.unlock();
            if (terminal_panel.hitTest(
                geo.editor_x,
                geo.task_panel_y,
                geo.task_panel_h,
                event.x,
                event.y,
                wb.task_scroll_y,
                wb.terminal.lines.items,
            )) |pos| {
                if (wb.terminal_selection) |*sel| sel.cursor = pos;
            }
        }
    } else if (event.action == .scroll) {
        const mx = state.last_mouse_x;
        const my = state.last_mouse_y;
        const scroll_delta_y = -event.y;
        const scroll_delta_x = -event.x;

        if (geo.shell_mode == .ide and mx >= geo.explorer_x and mx < geo.explorer_splitter_x and my >= layout.header_height) {
            switch (wb.sidebar_view) {
                .extensions => {
                    wb.extensions_scroll_y += scroll_delta_y;
                    wb.clampExtensionsScroll(h);
                },
                .search => {
                    wb.search_scroll_y += scroll_delta_y;
                    wb.clampSearchScroll(h);
                },
                .git => {
                    wb.git_scroll_y += scroll_delta_y;
                    wb.clampGitScroll(h);
                },
                .run => {
                    wb.run_scroll_y += scroll_delta_y;
                    wb.clampRunScroll(h);
                },
                .explorer => {
                    wb.explorer_scroll_y += scroll_delta_y;
                    wb.clampExplorerScroll(h);
                },
            }
        } else if (mx >= geo.agent_x) {
            if (wb.agent.show_review) {
                wb.agent.review_scroll_y += scroll_delta_y;
                wb.clampReviewScroll(h);
            } else {
                wb.chat_scroll_y += scroll_delta_y;
                wb.clampChatScroll(h);
            }
        } else if (geo.shell_mode == .ide and my >= tabs_ui.tab_bar_top and my < tabs_ui.tab_bar_top + tabs_ui.tab_bar_height and mx >= geo.editor_x and mx < geo.agent_splitter_x) {
            const tab_delta = if (scroll_delta_x != 0) scroll_delta_x else scroll_delta_y;
            wb.tab_scroll_x += tab_delta;
            wb.clampTabScroll(geo.editor_w);
        } else if (geo.shell_mode == .ide and my >= geo.task_panel_y and mx >= geo.editor_x and mx < geo.agent_splitter_x) {
            wb.task_scroll_y += scroll_delta_y;
            wb.clampBottomPanelScroll(geo.task_panel_h);
        } else if (geo.shell_mode == .ide and mx >= geo.editor_x and mx < geo.agent_splitter_x) {
            if (scroll_delta_y != 0) wb.editor_scroll_y += scroll_delta_y;
            if (scroll_delta_x != 0) wb.editor_scroll_x += scroll_delta_x;
            wb.clampEditorScroll(geo.editor_w, geo.editor_h);
        }
    }
}
