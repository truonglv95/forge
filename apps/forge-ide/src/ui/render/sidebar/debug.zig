const std = @import("std");
const renderer = @import("forge-renderer");
const state = @import("../../core/state.zig");
const layout = @import("../../core/layout.zig");
const Workbench = @import("../../../workbench.zig").Workbench;
const shared = @import("shared.zig");

const debug_panel = @import("../../sidebar/debug_panel.zig");
const scrollbar = @import("../../core/scrollbar.zig");
pub fn drawDebugPanel(wb: *Workbench, panel_x: f32, panel_w: f32, h: f32) void {
    const theme = &wb.theme;
    const debug_active = wb.debug.lldb.isActive();
    const panel_y = layout.header_height + layout.activity_bar_height;
    renderer.Renderer.setClipRect(panel_x, panel_y, panel_w, h - panel_y - layout.status_height);
    renderer.Renderer.drawSvg(renderer.icons.chevron_down, panel_x + 8, panel_y + 14, 16, 16, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
    renderer.Renderer.drawText("RUN AND DEBUG", panel_x + 22, panel_y + 15, 11.0, .{ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 });

    var y = debug_panel.list_top - wb.run_scroll_y;
    if (y + 22 >= 65 and y < h - layout.status_height) {
        renderer.Renderer.drawRoundedRect(panel_x + 12, y, panel_w - 24, 18, 4, shared.color(theme.colors.accent_soft));
        renderer.Renderer.drawText("Toggle breakpoint at cursor", panel_x + 20, y + 3, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
    }
    y += 22;
    if (y + 18 >= 65 and y < h - layout.status_height) {
        renderer.Renderer.drawRoundedRect(panel_x + 12, y, panel_w - 24, 18, 4, .{ .r = 0.22, .g = 0.25, .b = 0.3, .a = 1.0 });
        renderer.Renderer.drawText("Clear all breakpoints", panel_x + 20, y + 3, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
    }
    y += 34;

    if (debug_active) {
        if (y + 14 >= 65 and y < h - layout.status_height) {
            renderer.Renderer.drawText("DEBUG CONTROLS", panel_x + 16, y, 10.0, .{ .r = 0.55, .g = 0.55, .b = 0.55, .a = 1.0 });
        }
        y += 14;
        if (y + debug_panel.control_row_h >= 65 and y < h - layout.status_height) {
            const btn_w = (panel_w - 24) / @as(f32, @floatFromInt(debug_panel.controls.len));
            for (debug_panel.controls, 0..) |control, index| {
                const bx = panel_x + 12 + @as(f32, @floatFromInt(index)) * btn_w;
                renderer.Renderer.drawRoundedRect(bx, y, btn_w - 4, debug_panel.control_row_h - 4, 4, shared.color(theme.colors.selection));
                renderer.Renderer.drawText(control.label, bx + 6, y + 4, 10.0, .{ .r = 0.92, .g = 0.92, .b = 0.92, .a = 1.0 });
            }
        }
        y += debug_panel.controls_block_h;
    }

    if (y + 14 >= 65 and y < h - layout.status_height) {
        renderer.Renderer.drawText("LAUNCH CONFIGURATIONS", panel_x + 16, y, 10.0, .{ .r = 0.55, .g = 0.55, .b = 0.55, .a = 1.0 });
    }
    y += 18;
    for (debug_panel.default_launches) |launch| {
        if (y + debug_panel.launch_row_h >= 65 and y < h - layout.status_height) {
            renderer.Renderer.drawRoundedRect(panel_x + 8, y, panel_w - 16, debug_panel.launch_row_h - 6, 4, shared.color(theme.colors.selection));
            renderer.Renderer.drawText("▶", panel_x + 16, y + 6, 12.0, shared.color(theme.colors.accent));
            renderer.Renderer.drawText(launch.label, panel_x + 32, y + 6, 11.0, .{ .r = 0.92, .g = 0.92, .b = 0.92, .a = 1.0 });
        }
        y += debug_panel.launch_row_h;
    }
    y += 16;
    if (y + 14 >= 65 and y < h - layout.status_height) {
        var bp_hdr: [32:0]u8 = undefined;
        const hdr = std.fmt.bufPrint(&bp_hdr, "BREAKPOINTS ({d})", .{wb.debug.breakpoints.items.items.len}) catch "BREAKPOINTS";
        bp_hdr[hdr.len] = 0;
        renderer.Renderer.drawText(@ptrCast(&bp_hdr), panel_x + 16, y, 10.0, .{ .r = 0.55, .g = 0.55, .b = 0.55, .a = 1.0 });
    }
    y += 18;
    for (wb.debug.breakpoints.items.items) |bp| {
        if (y + debug_panel.row_h >= 65 and y < h - layout.status_height) {
            renderer.Renderer.drawRoundedRect(panel_x + 14, y + 4, 8, 8, 4, shared.color(theme.colors.warning));
            var line_buf: [192:0]u8 = undefined;
            const line = std.fmt.bufPrint(&line_buf, "{s}:{d}", .{ bp.path, bp.line + 1 }) catch bp.path;
            line_buf[line.len] = 0;
            renderer.Renderer.drawText(@ptrCast(&line_buf), panel_x + 28, y + 2, 11.0, .{ .r = 0.88, .g = 0.88, .b = 0.88, .a = 1.0 });
        }
        y += debug_panel.row_h;
    }
    renderer.Renderer.clearClipRect();
    const bp_count = wb.debug.breakpoints.items.items.len;
    const debug_viewport = debug_panel.viewportHeight(h);
    const debug_content = debug_panel.contentHeight(bp_count, debug_active);
    const debug_max = debug_panel.maxScrollY(bp_count, h, debug_active);
    const show_debug_scroll = scrollbar.hovered(state.last_mouse_x, state.last_mouse_y, panel_x, debug_panel.list_top, panel_w, debug_viewport);
    scrollbar.drawVertical(
        panel_x + panel_w - scrollbar.track_w - 2,
        debug_panel.list_top,
        debug_viewport,
        wb.run_scroll_y,
        debug_max,
        debug_content,
        debug_viewport,
        show_debug_scroll,
    );
}
