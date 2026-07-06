const renderer = @import("forge-renderer");
const shared = @import("shared.zig");
const Workbench = @import("../../workbench.zig").Workbench;

pub fn handleFindKeys(wb: *Workbench, event: renderer.KeyEvent) void {
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
    if (event.keycode == 14 and event.modifiers & shared.cmd_mask != 0) {
        wb.dispatch(.editor_find_next) catch {};
        return;
    }
    if (event.keycode == 14 and event.modifiers & (shared.cmd_mask | shared.shift_mask) == (shared.cmd_mask | shared.shift_mask)) {
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

pub fn handleGotoKeys(wb: *Workbench, event: renderer.KeyEvent) void {
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

pub fn handleSymbolRenameKeys(wb: *Workbench, event: renderer.KeyEvent) void {
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

pub fn handleRenameKeys(wb: *Workbench, event: renderer.KeyEvent) void {
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
