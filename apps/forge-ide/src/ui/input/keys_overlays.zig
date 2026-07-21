const renderer = @import("forge-renderer");
const shared = @import("shared.zig");
const Workbench = @import("../../workbench.zig").Workbench;

pub fn handleFindKeys(wb: *Workbench, event: renderer.KeyEvent) void {
    if (event.keycode == 53) {
        @import("../../workbench/editor_ops.zig").closeEditorOverlay(wb);
        return;
    }
    if (event.keycode == 36) {
        if (wb.find_bar.replace_mode) {
            if (wb.activeBuffer()) |buf| {
                wb.find_bar.replaceCurrent(buf) catch |err| shared.reportInputError(wb, "Replace match", err);
                @import("../../workbench/editor_ops.zig").scrollEditorToCursor(wb);
            }
        } else {
            wb.dispatch(.editor_find_next) catch |err| shared.reportInputError(wb, "Find next", err);
        }
        return;
    }
    if (event.keycode == 14 and event.modifiers & shared.cmd_mask != 0) {
        wb.dispatch(.editor_find_next) catch |err| shared.reportInputError(wb, "Find next", err);
        return;
    }
    if (event.keycode == 14 and event.modifiers & (shared.cmd_mask | shared.shift_mask) == (shared.cmd_mask | shared.shift_mask)) {
        wb.dispatch(.editor_find_prev) catch |err| shared.reportInputError(wb, "Find previous", err);
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
        active_buf.backspace() catch |err| shared.reportInputError(wb, "Edit find field", err);
        if (!wb.find_bar.focus_replace) {
            if (wb.activeBuffer()) |buf| wb.find_bar.refreshMatches(buf) catch |err| shared.reportInputError(wb, "Refresh find matches", err);
        }
        return;
    }
    if (event.chars.len > 0 and event.chars[0] >= 32) {
        active_buf.insertString(event.chars) catch |err| shared.reportInputError(wb, "Edit find field", err);
        if (!wb.find_bar.focus_replace) {
            if (wb.activeBuffer()) |buf| wb.find_bar.refreshMatches(buf) catch |err| shared.reportInputError(wb, "Refresh find matches", err);
        }
    }
}

pub fn handleGotoKeys(wb: *Workbench, event: renderer.KeyEvent) void {
    if (event.keycode == 53) {
        @import("../../workbench/editor_ops.zig").closeEditorOverlay(wb);
        return;
    }
    if (event.keycode == 36) {
        @import("../../workbench/editor_ops.zig").commitGotoLine(wb) catch |err| shared.reportInputError(wb, "Go to line", err);
        return;
    }
    const input_buf = &wb.goto_bar.input;
    if (event.keycode == 51) {
        input_buf.backspace() catch |err| shared.reportInputError(wb, "Edit go-to-line field", err);
        return;
    }
    if (event.chars.len > 0 and event.chars[0] >= 32) {
        input_buf.insertString(event.chars) catch |err| shared.reportInputError(wb, "Edit go-to-line field", err);
    }
}

pub fn handleSymbolRenameKeys(wb: *Workbench, event: renderer.KeyEvent) void {
    if (event.keycode == 53) {
        @import("../../workbench/editor_ops.zig").closeEditorOverlay(wb);
        return;
    }
    if (event.keycode == 36) {
        @import("../../workbench/editor_ops.zig").commitRenameSymbol(wb) catch |err| shared.reportInputError(wb, "Rename symbol", err);
        return;
    }
    const input_buf = &wb.rename_bar.input;
    if (event.keycode == 51) {
        input_buf.backspace() catch |err| shared.reportInputError(wb, "Edit rename field", err);
        return;
    }
    if (event.chars.len > 0 and event.chars[0] >= 32) {
        input_buf.insertString(event.chars) catch |err| shared.reportInputError(wb, "Edit rename field", err);
    }
}

pub fn handleRenameKeys(wb: *Workbench, event: renderer.KeyEvent) void {
    if (event.keycode == 53) {
        wb.cancelRename();
        return;
    }
    if (event.keycode == 36) {
        wb.commitRename() catch |err| shared.reportInputError(wb, "Commit file rename", err);
        return;
    }
    if (event.keycode == 51) {
        wb.rename_buffer.backspace() catch |err| shared.reportInputError(wb, "Edit file rename", err);
        return;
    }
    if (event.chars.len > 0 and event.chars[0] >= 32) {
        wb.rename_buffer.insertString(event.chars) catch |err| shared.reportInputError(wb, "Edit file rename", err);
    }
}
