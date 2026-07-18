const std = @import("std");
const renderer = @import("forge-renderer");
const state = @import("../core/state.zig");
const layout = @import("../core/layout.zig");
const keybindings_mod = @import("../../keybindings.zig");
const Workbench = @import("../../workbench.zig").Workbench;

const shared = @import("shared.zig");
const keys_dialogs = @import("keys_dialogs.zig");
const keys_overlays = @import("keys_overlays.zig");
const keys_agent = @import("keys_agent.zig");
const keys_sidebar = @import("keys_sidebar.zig");

fn isPlainPrintableText(event: renderer.KeyEvent) bool {
    if (event.chars.len == 0) return false;
    const command_modifiers = shared.cmd_mask | shared.ctrl_mask | shared.alt_mask;
    if (event.modifiers & command_modifiers != 0) return false;
    return event.chars[0] >= 32;
}

pub fn onKeyEvent(event: renderer.KeyEvent) void {
    if (!event.is_down) return;
    const wb = state.wb orelse return;
    state.markAllDirty();

    var win_h: f32 = 768;
    var win_w: f32 = 1024;
    renderer.Renderer.getWindowSize(&win_w, &win_h);

    if (wb.focused_panel == .recovery) {
        keys_dialogs.handleRecoveryKeys(wb, event);
        return;
    }

    if (wb.focused_panel == .conflict) {
        keys_dialogs.handleConflictKeys(wb, event);
        return;
    }

    if (wb.focused_panel == .palette) {
        keys_dialogs.handlePaletteKeys(wb, event);
        return;
    }

    if (event.keycode == 9 and event.modifiers & shared.cmd_mask != 0) {
        if (wb.focused_panel == .find or wb.focused_panel == .goto_line or wb.focused_panel == .rename or wb.focused_panel == .agent or wb.focused_panel == .editor) {
            shared.pasteIntoActiveBuffer(wb);
            return;
        }
    }

    if (wb.focused_panel == .find) {
        keys_overlays.handleFindKeys(wb, event);
        return;
    }

    if (wb.focused_panel == .goto_line) {
        keys_overlays.handleGotoKeys(wb, event);
        return;
    }

    if (wb.focused_panel == .rename) {
        keys_overlays.handleSymbolRenameKeys(wb, event);
        return;
    }

    if (wb.rename_preview.active and wb.bottom_panel_mode == .output) {
        if (event.keycode == 53) {
            wb.dispatch(.rename_reject) catch {};
            return;
        }
        if (event.keycode == 36) {
            wb.dispatch(.rename_accept) catch {};
            return;
        }
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
        keys_agent.handleScopePickerKeys(wb, event);
        return;
    }

    if (wb.focused_panel == .agent and event.keycode == 53) {
        wb.agent.lock();
        const menus_open = wb.agent.mode_menu_open or wb.agent.model_menu_open;
        wb.agent.unlock();
        if (menus_open) {
            wb.dispatch(.agent_close_menus) catch {};
            return;
        }
    }

    if (wb.renaming) {
        keys_overlays.handleRenameKeys(wb, event);
        return;
    }

    if (wb.focused_panel == .search) {
        keys_sidebar.handleSearchKeys(wb, event);
        return;
    }

    if (wb.bottom_panel_mode == .terminal and wb.focused_panel == .terminal) {
        keys_sidebar.handleTerminalKeys(wb, event);
        return;
    }

    if (wb.focused_panel == .terminal) {
        keys_sidebar.handleTerminalKeys(wb, event);
        return;
    }

    if (wb.focused_panel == .extensions) {
        keys_sidebar.handleExtensionsFilterKeys(wb, event);
        return;
    }

    if (wb.focused_panel == .agent and wb.agent.show_review) {
        if (event.keycode == 36 and event.modifiers & shared.cmd_mask != 0) {
            wb.dispatch(.agent_apply) catch {};
            return;
        }
        if (event.keycode == 53) {
            wb.dispatch(.agent_reject) catch {};
            return;
        }
        if (event.keycode == 126 or event.keycode == 125) {
            const scroll_step: f32 = 14.0;
            if (event.keycode == 126) {
                wb.agent.review_scroll_y = @max(0, wb.agent.review_scroll_y - scroll_step);
            } else {
                wb.agent.review_scroll_y += scroll_step;
            }
            wb.clampReviewScroll(win_h);
            return;
        }
        // Allow typing a new prompt while review is open; Enter submits below.
    }

    const ctrl_mask: i32 = 0x01;
    if (event.keycode == 49 and event.modifiers & ctrl_mask != 0 and wb.focused_panel == .editor) {
        wb.dispatch(.editor_completion) catch {};
        return;
    }

    if (wb.workspace_symbol_picker.open) {
        // We'll create handleWorkspaceSymbolPickerKeys next
        keys_dialogs.handleWorkspaceSymbolPickerKeys(wb, event);
        return;
    }

    if (event.keycode == 17 and event.modifiers & shared.cmd_mask != 0) { // 17 is T
        wb.dispatch(.workspace_symbol_picker_open) catch {};
        return;
    }

    if (event.keycode == 35 and (event.modifiers & (shared.cmd_mask | shared.shift_mask)) == (shared.cmd_mask | shared.shift_mask)) {
        wb.dispatch(.palette_open) catch {};
        return;
    }

    const text_focus = wb.focused_panel == .editor or wb.focused_panel == .agent or wb.focused_panel == .git;
    if (!(text_focus and isPlainPrintableText(event)) and keybindings_mod.Registry.dispatch(&wb.keybindings, &wb.palette, event, shared.dispatchWorkbenchCommand)) {
        return;
    }

    if (event.keycode == 4 and event.modifiers & shared.cmd_mask != 0) {
        wb.dispatch(.{ .run_extension_command = "hello.say" }) catch {};
        return;
    }

    if (event.keycode == 8 and event.modifiers & shared.cmd_mask != 0 and wb.focused_panel == .agent and wb.agent.worker_running) {
        wb.dispatch(.agent_cancel) catch {};
        return;
    }

    if (event.keycode == 53 and event.modifiers & shared.cmd_mask == 0) {
        wb.dispatch(.palette_close) catch {};
    }

    if (event.keycode == 120 and wb.focused_panel == .explorer) {
        wb.dispatch(.explorer_begin_rename) catch {};
        return;
    }

    var active_buffer = if (wb.focused_panel == .editor)
        wb.activeBuffer() orelse return
    else if (wb.focused_panel == .agent)
        &wb.prompt_buffer
    else if (wb.focused_panel == .git)
        &wb.git_commit_msg
    else
        return;

    if (event.keycode == 0 and event.modifiers & shared.cmd_mask != 0) { // Command+A
        active_buffer.selectAll();
        return;
    }

    if (event.keycode == 8 and event.modifiers & shared.cmd_mask != 0) { // Command+C
        if (state.chat_selection) |sel| {
            if (sel.msg_hash < wb.chat_history.items.len) {
                const msg = wb.chat_history.items[sel.msg_hash];
                const start = @min(sel.start, sel.end);
                const end = @max(sel.start, sel.end);
                if (start < end and end <= msg.content.len) {
                    const text = msg.content[start..end];
                    renderer.Renderer.setClipboardText(text);
                    return;
                }
            }
        }
        if (active_buffer.selectedText(wb.allocator)) |text| {
            if (text.len > 0) {
                renderer.Renderer.setClipboardText(text);
                wb.allocator.free(text);
                return;
            } else {
                wb.allocator.free(text);
            }
        } else |_| {}
    }

    if (event.keycode == 13 and event.modifiers & shared.cmd_mask != 0) {
        wb.dispatch(.close_active_tab) catch {};
        return;
    }

    if (event.keycode == 1 and event.modifiers & shared.cmd_mask != 0) {
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

    if (event.keycode == 6 and event.modifiers & shared.cmd_mask != 0 and wb.focused_panel == .editor) {
        active_buffer.undo() catch {};
        return;
    }

    if (event.keycode == 6 and event.modifiers & (shared.cmd_mask | shared.shift_mask) == (shared.cmd_mask | shared.shift_mask) and wb.focused_panel == .editor) {
        active_buffer.redo() catch {};
        return;
    }

    if (wb.focused_panel == .explorer) return;
    if (wb.focused_panel == .extensions) return;
    if (wb.focused_panel == .search) return;
    if (wb.focused_panel == .run) return;

    if (event.keycode == 51) {
        active_buffer.backspace() catch {};
    } else if (event.keycode == 36 or event.keycode == 76) {
        if (wb.focused_panel == .agent) {
            keys_agent.submitAgentPrompt(wb);
        } else {
            active_buffer.insertNewline() catch {};
        }
    } else if (event.keycode == 123) {
        active_buffer.clearSelection();
        active_buffer.moveLeft();
    } else if (event.keycode == 124) {
        active_buffer.clearSelection();
        active_buffer.moveRight();
    } else if (event.keycode == 125) {
        active_buffer.clearSelection();
        active_buffer.moveDown();
    } else if (event.keycode == 126) {
        active_buffer.clearSelection();
        active_buffer.moveUp();
    } else if (event.chars.len > 0) {
        const char_val = event.chars[0];
        if (wb.focused_panel == .agent and char_val == '@' and !wb.agent.show_review and !wb.agent.worker_running) {
            // P0-3: Open mention picker when user types @ in agent panel.
            wb.mention_picker.open();
            return;
        }
        if (char_val >= 32 or char_val == '\t') {
            active_buffer.insertString(event.chars) catch {};
            // P0-4: Mark fold ranges dirty so they recompute on next tick.
            wb.fold_dirty = true;
            // P0-2: If inline edit prompt is active, append to it instead
            // of the editor buffer.
            if (wb.inline_edit.active) {
                wb.inline_edit.appendSlice(event.chars) catch {};
            }
        }
    }

    if (wb.focused_panel == .agent) {
        wb.ensurePromptCursorVisible();
    }
}

pub fn onImeCompositionEvent(event: renderer.ImeCompositionEvent) void {
    const wb = state.wb orelse return;
    state.markAllDirty();

    var active_buffer = if (wb.focused_panel == .editor)
        wb.activeBuffer() orelse return
    else if (wb.focused_panel == .agent)
        &wb.prompt_buffer
    else if (wb.focused_panel == .git)
        &wb.git_commit_msg
    else
        return;

    if (event.cursor_pos == -1) {
        // Committed text
        if (wb.ime_text) |t| {
            wb.allocator.free(t);
            wb.ime_text = null;
        }
        wb.ime_cursor = -1;
        if (event.text.len > 0) {
            active_buffer.insertString(event.text) catch {};
            wb.fold_dirty = true;
            if (wb.inline_edit.active and wb.focused_panel == .editor) {
                wb.inline_edit.appendSlice(event.text) catch {};
            }
        }
    } else {
        // Composing text
        if (wb.ime_text) |t| {
            wb.allocator.free(t);
        }
        if (event.text.len > 0) {
            wb.ime_text = wb.allocator.dupe(u8, event.text) catch null;
        } else {
            wb.ime_text = null;
        }
        wb.ime_cursor = event.cursor_pos;
    }

    if (wb.focused_panel == .agent) {
        wb.ensurePromptCursorVisible();
    }
}
