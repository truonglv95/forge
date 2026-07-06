const std = @import("std");
const renderer = @import("forge-renderer");
const state = @import("../../core/state.zig");
const layout = @import("../../core/layout.zig");
const Workbench = @import("../../../workbench.zig").Workbench;
const shared = @import("shared.zig");

const search_panel = @import("../../sidebar/search_panel.zig");
pub fn drawSearchPanel(wb: *Workbench, panel_x: f32, panel_w: f32, h: f32) void {
    const theme = &wb.theme;
    const panel_y = layout.header_height + layout.activity_bar_height;
    renderer.Renderer.setClipRect(panel_x, panel_y, panel_w, h - panel_y - layout.status_height);
    renderer.Renderer.drawSvg(renderer.icons.chevron_down, panel_x + 8, panel_y + 14, 16, 16, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
    renderer.Renderer.drawText("SEARCH", panel_x + 22, panel_y + 15, 11.0, .{ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 });

    const query_y = search_panel.list_top - 32;
    renderer.Renderer.drawRoundedRect(panel_x + 12, query_y, panel_w - 24, search_panel.query_box_h, 4, .{ .r = 0.18, .g = 0.2, .b = 0.24, .a = 1.0 });
    const show_cursor = @mod(state.time, 1.0) < 0.5;
    const query_str = wb.search_buffer.toDisplayString(show_cursor and wb.focused_panel == .search) catch return;
    defer state.gpa.free(query_str);
    renderer.Renderer.drawText(query_str, panel_x + 20, query_y + 6, 12.0, .{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 });

    renderer.Renderer.drawRoundedRect(panel_x + 12, query_y + 34, panel_w - 24, 18, 4, shared.color(theme.colors.accent_soft));
    renderer.Renderer.drawText("Search workspace", panel_x + 20, query_y + 37, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });

    var y = search_panel.list_top - wb.search_scroll_y + 28;
    if (wb.search_results) |results| {
        for (results.matches, 0..) |match, index| {
            if (y + search_panel.row_h >= 65 and y < h - layout.status_height) {
                renderer.Renderer.drawRect(panel_x, y, panel_w, search_panel.row_h - 4, shared.color(theme.colors.selection));
                var path_buf: [160:0]u8 = undefined;
                @memcpy(path_buf[0..@min(match.path.len, path_buf.len - 1)], match.path[0..@min(match.path.len, path_buf.len - 1)]);
                path_buf[@min(match.path.len, path_buf.len - 1)] = 0;
                renderer.Renderer.drawText(@ptrCast(&path_buf), panel_x + 16, y + 2, 11.0, .{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 });
                var preview_buf: [128:0]u8 = undefined;
                @memcpy(preview_buf[0..@min(match.preview.len, preview_buf.len - 1)], match.preview[0..@min(match.preview.len, preview_buf.len - 1)]);
                preview_buf[@min(match.preview.len, preview_buf.len - 1)] = 0;
                renderer.Renderer.drawText(@ptrCast(&preview_buf), panel_x + 16, y + 16, 10.0, .{ .r = 0.65, .g = 0.75, .b = 0.85, .a = 1.0 });
                _ = index;
            }
            y += search_panel.row_h;
        }
        if (results.matches.len == 0) {
            renderer.Renderer.drawText("No results.", panel_x + 16, search_panel.list_top + 8, 11.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
        }
    } else {
        renderer.Renderer.drawText("Enter query and click Search.", panel_x + 16, search_panel.list_top + 8, 11.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
    }
    renderer.Renderer.clearClipRect();
    const result_count = if (wb.search_results) |results| results.matches.len else 0;
    shared.drawSidebarScrollbar(panel_x, panel_w, search_panel.list_top, h, wb.search_scroll_y, result_count, search_panel.row_h);
}
