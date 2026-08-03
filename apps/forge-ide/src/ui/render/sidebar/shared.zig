const std = @import("std");
const renderer = @import("forge-renderer");
const state = @import("../../core/state.zig");
const layout = @import("../../core/layout.zig");
const scroll_region = @import("../../core/scroll_region.zig");
const scrollbar = @import("../../core/scrollbar.zig");
const render_theme = @import("../theme.zig");

pub fn color(rgba: @import("forge-workspace").Rgba) renderer.Color {
    return render_theme.color(rgba);
}

pub fn drawSidebarScrollbar(
    panel_x: f32,
    panel_w: f32,
    list_top: f32,
    window_h: f32,
    scroll_y: f32,
    row_count: usize,
    row_h: f32,
) void {
    const metrics = scrollbar.sidebarMetrics(row_count, row_h, list_top, window_h, layout.status_height);
    const show = scrollbar.hovered(state.last_mouse_x, state.last_mouse_y, panel_x, list_top, panel_w, metrics.viewport_h);
    scrollbar.drawVertical(
        panel_x + panel_w - scrollbar.track_w - 2,
        list_top,
        metrics.viewport_h,
        scroll_y,
        metrics.max_scroll,
        metrics.content_h,
        metrics.viewport_h,
        show,
    );
}

pub const VisibleRowRange = struct {
    first: usize,
    last: usize,
};

pub fn visibleRowRange(scroll_y: f32, viewport_h: f32, row_h: f32, row_count: usize) VisibleRowRange {
    const range = scroll_region.region(@as(f32, @floatFromInt(row_count)) * row_h, viewport_h).visibleRange(scroll_y, row_h, row_count);
    return .{ .first = range.first, .last = range.last };
}

pub fn visibleRowY(list_top: f32, scroll_y: f32, row_h: f32, first: usize) f32 {
    return list_top - scroll_y + @as(f32, @floatFromInt(first)) * row_h;
}

pub fn countLines(text: ?[]const u8) usize {
    const value = text orelse return 1;
    if (value.len == 0) return 1;
    var count: usize = 1;
    for (value) |ch| {
        if (ch == '\n') count += 1;
    }
    return count;
}

test "sidebar visible row helper keeps fractional scroll offset" {
    const range = visibleRowRange(15, 100, 20, 20);
    try std.testing.expectEqual(@as(usize, 0), range.first);
    try std.testing.expectEqual(@as(usize, 7), range.last);
    try std.testing.expectEqual(@as(f32, 85), visibleRowY(100, 15, 20, range.first));
}

test "sidebar visible row helper clamps at list end" {
    const range = visibleRowRange(900, 80, 20, 10);
    try std.testing.expectEqual(@as(usize, 6), range.first);
    try std.testing.expectEqual(@as(usize, 10), range.last);
}
