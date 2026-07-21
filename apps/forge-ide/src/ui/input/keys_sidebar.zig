const renderer = @import("forge-renderer");
const terminal_session_mod = @import("../../workbench/terminal_session.zig");
const shared = @import("shared.zig");
const Workbench = @import("../../workbench.zig").Workbench;

pub fn handleTerminalKeys(wb: *Workbench, event: renderer.KeyEvent) void {
    if (event.keycode == 8 and event.modifiers & shared.cmd_mask != 0) {
        wb.copyTerminalSelection() catch |err| shared.reportInputError(wb, "Copy terminal selection", err);
        return;
    }

    if (wb.terminal_selection != null) {
        wb.terminal_selection = null;
    }

    var buf: [64]u8 = undefined;
    const bytes = terminal_session_mod.TerminalSession.encodeKey(event, &buf) orelse return;
    wb.activeTerminal().writeInput(bytes);
    if (bytes.len == 1 and bytes[0] == '\r') {
        wb.dispatch(.terminal_submit) catch |err| shared.reportInputError(wb, "Submit terminal command", err);
    }
}

pub fn handleSearchKeys(wb: *Workbench, event: renderer.KeyEvent) void {
    if (event.keycode == 36) {
        wb.dispatch(.search_run) catch |err| shared.reportInputError(wb, "Run search", err);
        return;
    }
    if (event.keycode == 51) {
        wb.search_buffer.backspace() catch |err| shared.reportInputError(wb, "Edit search query", err);
        return;
    }
    if (event.chars.len > 0 and event.chars[0] >= 32) {
        wb.search_buffer.insertString(event.chars) catch |err| shared.reportInputError(wb, "Edit search query", err);
    }
}

pub fn handleExtensionsFilterKeys(wb: *Workbench, event: renderer.KeyEvent) void {
    if (event.keycode == 51) {
        if (wb.extensions_filter_len > 0) wb.extensions_filter_len -= 1;
        return;
    }
    if (event.chars.len > 0 and event.chars[0] >= 32 and wb.extensions_filter_len < wb.extensions_filter.len) {
        wb.extensions_filter[wb.extensions_filter_len] = event.chars[0];
        wb.extensions_filter_len += 1;
    }
}
