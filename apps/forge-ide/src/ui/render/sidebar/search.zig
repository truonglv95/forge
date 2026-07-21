const std = @import("std");
const renderer = @import("forge-renderer");
const state = @import("../../core/state.zig");
const layout = @import("../../core/layout.zig");
const Workbench = @import("../../../workbench.zig").Workbench;
const shared = @import("shared.zig");

const search_panel = @import("../../sidebar/search_panel.zig");
const ui_text_style = renderer.TextStyle.prose;
const ui_strong_style = renderer.TextStyle.prose_semibold;

fn drawUiText(text: []const u8, x: f32, y: f32, size: f32, c: renderer.Color) void {
    renderer.Renderer.drawTextWithStyle(text, x, @round(y), size, c, ui_text_style);
}

fn drawStrongText(text: []const u8, x: f32, y: f32, size: f32, c: renderer.Color) void {
    renderer.Renderer.drawTextWithStyle(text, x, @round(y), size, c, ui_strong_style);
}

pub fn drawSearchPanel(wb: *Workbench, panel_x: f32, panel_w: f32, h: f32) void {
    const theme = &wb.theme;
    const panel_y = search_panel.panel_top;
    renderer.Renderer.setClipRect(panel_x, panel_y, panel_w, h - panel_y - layout.status_height);
    const icon_c = renderer.Color{ .r = 0.62, .g = 0.63, .b = 0.67, .a = 1.0 };
    const label_c = renderer.Color{ .r = 0.8, .g = 0.81, .b = 0.84, .a = 1.0 };
    const muted_c = renderer.Color{ .r = 0.58, .g = 0.59, .b = 0.64, .a = 1.0 };
    const input_bg = renderer.Color{ .r = 0.18, .g = 0.19, .b = 0.21, .a = 1.0 };
    const input_border = if (wb.focused_panel == .search) shared.color(theme.colors.accent) else renderer.Color{ .r = 0.25, .g = 0.26, .b = 0.29, .a = 1.0 };

    renderer.Renderer.drawSvg(renderer.icons.chevron_down, panel_x + 8, panel_y + 12, 16, 16, icon_c);
    drawStrongText("SEARCH", panel_x + 28, panel_y + 13, 11.0, label_c);

    const query_y = search_panel.query_top;
    renderer.Renderer.drawRoundedRect(panel_x + 12, query_y, panel_w - 24, search_panel.query_box_h, 5, input_border);
    renderer.Renderer.drawRoundedRect(panel_x + 13, query_y + 1, panel_w - 26, search_panel.query_box_h - 2, 5, input_bg);
    const show_cursor = @mod(state.time, 1.0) < 0.5;
    const query_str = wb.search_buffer.toDisplayString(show_cursor and wb.focused_panel == .search) catch return;
    defer state.gpa.free(query_str);
    renderer.Renderer.pushClipRect(panel_x + 20, query_y + 4, @max(0, panel_w - 126), search_panel.query_box_h - 8);
    drawUiText(query_str, panel_x + 20, query_y + 8, 12.5, .{ .r = 0.92, .g = 0.93, .b = 0.95, .a = 1.0 });
    renderer.Renderer.popClipRect();

    const option_y = query_y + 8;
    drawUiText("Aa", panel_x + panel_w - 82, option_y, 11.0, muted_c);
    drawUiText("ab", panel_x + panel_w - 56, option_y, 11.0, muted_c);
    drawStrongText("*", panel_x + panel_w - 28, option_y, 13.0, muted_c);

    renderer.Renderer.drawRoundedRect(panel_x + 12, search_panel.search_button_top, panel_w - 24, search_panel.search_button_h, 5, shared.color(theme.colors.accent_soft));
    drawStrongText("Search workspace", panel_x + 20, search_panel.search_button_top + 8, 11.5, .{ .r = 0.86, .g = 0.88, .b = 0.92, .a = 1.0 });

    if (wb.search.results) |results| {
        const row_h = search_panel.row_h;
        const start_idx: usize = @as(usize, @intFromFloat(wb.search.scroll_y / row_h));
        const visual_count: usize = @as(usize, @intFromFloat(search_panel.viewportHeight(h) / row_h)) + 2;
        const end_idx = @min(results.matches.len, start_idx + visual_count);

        var y = search_panel.list_top - wb.search.scroll_y + @as(f32, @floatFromInt(start_idx)) * row_h;
        for (results.matches[start_idx..end_idx], start_idx..) |match, index| {
            if (y + row_h >= search_panel.list_top and y < h - layout.status_height) {
                renderer.Renderer.drawRoundedRect(panel_x + 8, y, panel_w - 16, row_h - 4, 4, shared.color(theme.colors.selection));
                var path_buf: [256:0]u8 = undefined;
                const path_str: [:0]const u8 = std.fmt.bufPrintZ(&path_buf, "{s}:{d}", .{ match.path, match.line }) catch "<path too long>";
                drawStrongText(path_str, panel_x + 16, y + 3, 11.0, .{ .r = 0.92, .g = 0.93, .b = 0.95, .a = 1.0 });

                var preview_buf: [128:0]u8 = undefined;
                @memcpy(preview_buf[0..@min(match.line_text.len, preview_buf.len - 1)], match.line_text[0..@min(match.line_text.len, preview_buf.len - 1)]);
                preview_buf[@min(match.line_text.len, preview_buf.len - 1)] = 0;
                drawUiText(@ptrCast(&preview_buf), panel_x + 16, y + 18, 10.5, .{ .r = 0.64, .g = 0.72, .b = 0.82, .a = 1.0 });
                _ = index;
            }
            y += row_h;
        }
        if (results.matches.len == 0) {
            drawUiText("No results.", panel_x + 16, search_panel.list_top + 8, 11.5, muted_c);
        }
    } else {
        drawUiText("Enter query and click Search.", panel_x + 16, search_panel.list_top + 8, 11.5, muted_c);
    }
    renderer.Renderer.clearClipRect();
    const result_count = if (wb.search.results) |results| results.matches.len else 0;
    shared.drawSidebarScrollbar(panel_x, panel_w, search_panel.list_top, h, wb.search.scroll_y, result_count, search_panel.row_h);
}
