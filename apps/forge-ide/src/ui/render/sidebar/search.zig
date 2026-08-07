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

    // Toggle replace chevron — rotates based on show_replace state
    const toggle_icon = if (wb.search_show_replace) renderer.forge_icons.chevron_down else renderer.forge_icons.chevron_right;
    renderer.Renderer.drawSvg(toggle_icon, panel_x + 8, panel_y + 12, 16, 16, icon_c);
    drawStrongText("SEARCH", panel_x + 28, panel_y + 13, 11.0, label_c);

    // Search query input
    const query_y = search_panel.query_top;
    renderer.Renderer.drawRoundedRect(panel_x + 12, query_y, panel_w - 24, search_panel.query_box_h, 5, input_border);
    renderer.Renderer.drawRoundedRect(panel_x + 13, query_y + 1, panel_w - 26, search_panel.query_box_h - 2, 5, input_bg);
    const show_cursor = @import("../../core/state.zig").caret_blink_visible;
    const query_str = wb.search_buffer.toDisplayString(show_cursor and wb.focused_panel == .search) catch return;
    defer state.gpa.free(query_str);
    renderer.Renderer.pushClipRect(panel_x + 20, query_y + 4, @max(0, panel_w - 126), search_panel.query_box_h - 8);
    drawUiText(query_str, panel_x + 20, query_y + 6, 12.5, .{ .r = 0.92, .g = 0.93, .b = 0.95, .a = 1.0 });
    renderer.Renderer.popClipRect();

    // Search options (case sensitive, whole word, regex)
    const option_y = query_y + 6;
    drawUiText("Aa", panel_x + panel_w - 82, option_y, 11.0, muted_c);
    drawUiText("ab", panel_x + panel_w - 56, option_y, 11.0, muted_c);
    drawStrongText("*", panel_x + panel_w - 28, option_y, 13.0, muted_c);

    // Replace input (only when show_replace is true)
    if (wb.search_show_replace) {
        const replace_y = search_panel.replace_top;
        renderer.Renderer.drawRoundedRect(panel_x + 12, replace_y, panel_w - 24, search_panel.replace_box_h, 5, input_border);
        renderer.Renderer.drawRoundedRect(panel_x + 13, replace_y + 1, panel_w - 26, search_panel.replace_box_h - 2, 5, input_bg);
        const replace_str = wb.search_replace_buffer.toDisplayString(show_cursor and wb.focused_panel == .search) catch return;
        defer state.gpa.free(replace_str);
        renderer.Renderer.pushClipRect(panel_x + 20, replace_y + 4, @max(0, panel_w - 126), search_panel.replace_box_h - 8);
        drawUiText(replace_str, panel_x + 20, replace_y + 6, 12.5, .{ .r = 0.88, .g = 0.85, .b = 0.7, .a = 1.0 });
        renderer.Renderer.popClipRect();
    }

    // Search button + Replace All button
    renderer.Renderer.drawRoundedRect(panel_x + 12, search_panel.search_button_top, panel_w - 24, search_panel.search_button_h, 5, shared.color(theme.colors.accent_soft));
    if (wb.search_show_replace) {
        drawStrongText("Search", panel_x + 20, search_panel.search_button_top + 7, 11.5, .{ .r = 0.86, .g = 0.88, .b = 0.92, .a = 1.0 });
        // Replace All button — right side
        renderer.Renderer.drawRoundedRect(panel_x + panel_w - 80, search_panel.search_button_top, 68, search_panel.search_button_h, 5, .{ .r = 0.2, .g = 0.35, .b = 0.55, .a = 0.8 });
        drawStrongText("Replace All", panel_x + panel_w - 72, search_panel.search_button_top + 7, 10.5, .{ .r = 0.85, .g = 0.92, .b = 1.0, .a = 1.0 });
    } else {
        drawStrongText("Search workspace", panel_x + 20, search_panel.search_button_top + 7, 11.5, .{ .r = 0.86, .g = 0.88, .b = 0.92, .a = 1.0 });
    }

    // Results list
    if (wb.search.results) |results| {
        const row_h = search_panel.row_h;
        const vp_h = search_panel.viewportHeight(h, wb.search_show_replace);
        const range = shared.visibleRowRange(wb.search.scroll_y, vp_h, row_h, results.matches.len);

        var y = shared.visibleRowY(search_panel.list_top, wb.search.scroll_y, row_h, range.first);
        for (results.matches[range.first..range.last], range.first..) |match, index| {
            if (y + row_h >= search_panel.list_top and y < h - layout.status_height) {
                // Hover highlight
                const is_hover = state.last_mouse_x >= panel_x + 8 and state.last_mouse_x < panel_x + panel_w - 8 and
                    state.last_mouse_y >= y and state.last_mouse_y < y + row_h - 4;
                if (is_hover) {
                    renderer.Renderer.drawRoundedRect(panel_x + 8, y, panel_w - 16, row_h - 4, 4, .{ .r = 1, .g = 1, .b = 1, .a = 0.04 });
                } else {
                    renderer.Renderer.drawRoundedRect(panel_x + 8, y, panel_w - 16, row_h - 4, 4, shared.color(theme.colors.selection));
                }
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

    // Result count summary
    if (wb.search.results) |results| {
        if (results.matches.len > 0) {
            var count_buf: [64:0]u8 = undefined;
            _ = std.fmt.bufPrintZ(&count_buf, "{d} results", .{results.matches.len}) catch "";
            drawUiText(@ptrCast(&count_buf), panel_x + 12, panel_y + 50, 10.0, muted_c);
        }
    }

    const result_count = if (wb.search.results) |results| results.matches.len else 0;
    shared.drawSidebarScrollbar(panel_x, panel_w, search_panel.list_top, h, wb.search.scroll_y, result_count, search_panel.row_h);
}
