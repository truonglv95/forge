const std = @import("std");
const renderer = @import("forge-renderer");
const layout = @import("../layout.zig");
const Workbench = @import("../../workbench.zig").Workbench;

pub fn drawStatusBar(wb: *Workbench, w: f32, h: f32, shell_mode: layout.ShellMode) void {
    var status_buf: [320:0]u8 = undefined;
    var font_name: [48:0]u8 = undefined;
    renderer.Renderer.getResolvedFontName(&font_name);
    const ext_count = wb.extension_host.activeExtensionCount();
    const lsp_label: []const u8 = blk: {
        if (wb.activeFilePath()) |path| {
            wb.lsp_registry.mutex.lock();
            defer wb.lsp_registry.mutex.unlock();
            if (wb.lsp_registry.findForPathUnlocked(path)) |server| {
                break :blk server.language_id;
            }
        }
        break :blk "-";
    };
    const mode_label = switch (shell_mode) {
        .ide => "IDE",
        .agent_window => "Agent",
    };
    const status_label = std.fmt.bufPrint(&status_buf, "{s}  |  {s}{s}  |  {d:.0}pt {s}  |  ext: {d}  |  lsp: {s}  |  problems: {d}  |  Cmd+Shift+P", .{
        mode_label,
        wb.activePathBasename(),
        if (wb.tabs.tabs.items.len > 0 and wb.tabs.active < wb.tabs.tabs.items.len)
            if (wb.tabs.tabs.items[wb.tabs.active].isDirty()) " • modified" else ""
        else
            "",
        wb.theme.editor_font_size,
        font_name,
        ext_count,
        lsp_label,
        wb.diagnostics.list.items.len,
    }) catch wb.activePathBasename();
    status_buf[status_label.len] = 0;
    if (wb.status_message.len > 0) {
        renderer.Renderer.drawText(wb.status_message, w - 320, h - 18, 12.0, .{ .r = 0.9, .g = 0.9, .b = 0.6, .a = 1.0 });
    }
    renderer.Renderer.drawText(@ptrCast(&status_buf), 20, h - 18, 12.0, .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 });
}
