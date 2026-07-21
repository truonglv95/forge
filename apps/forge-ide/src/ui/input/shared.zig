const std = @import("std");
const renderer = @import("forge-renderer");
const state = @import("../core/state.zig");
const Workbench = @import("../../workbench.zig").Workbench;

pub const cmd_mask: i32 = 0x08;
pub const shift_mask: i32 = 0x02;
pub const alt_mask: i32 = 0x20;
pub const ctrl_mask: i32 = 0x01;

pub fn canUninstallExtensionIndex(ext_index: usize) bool {
    const wb = state.wb orelse return false;
    if (ext_index >= wb.extension_host.extensions.items.len) return false;
    return @import("../../workbench/extensions_ops.zig").canUninstallExtension(wb, &wb.extension_host.extensions.items[ext_index]);
}

pub fn dispatchWorkbenchCommand(command: @import("../../workbench/commands.zig").Command) anyerror!void {
    const wb = state.wb orelse return;
    try wb.dispatch(command);
}
pub fn pasteIntoActiveBuffer(wb: *Workbench) void {
    if (wb.focused_panel == .agent) {
        @import("../../workbench/agent_ops.zig").pasteIntoAgent(wb) catch {};
        return;
    }

    const text = renderer.Renderer.clipboardText(state.gpa) catch return;
    defer state.gpa.free(text);
    if (text.len == 0) return;

    const buffer = if (wb.focused_panel == .editor)
        wb.activeBuffer() orelse return
    else if (wb.focused_panel == .agent)
        &wb.agent_ui.prompt_buffer
    else if (wb.focused_panel == .find)
        if (wb.find_bar.replace_mode and wb.find_bar.focus_replace)
            &wb.find_bar.replace
        else
            &wb.find_bar.query
    else if (wb.focused_panel == .goto_line)
        &wb.goto_bar.input
    else if (wb.focused_panel == .rename)
        &wb.rename_bar.input
    else if (wb.focused_panel == .git)
        &wb.git.commit_msg
    else if (wb.focused_panel == .search)
        &wb.search_buffer
    else
        return;

    buffer.insertString(text) catch {};
}
