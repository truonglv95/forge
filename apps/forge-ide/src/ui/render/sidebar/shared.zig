const renderer = @import("forge-renderer");
const state = @import("../../core/state.zig");
const layout = @import("../../core/layout.zig");
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

pub fn countLines(text: ?[]const u8) usize {
    const value = text orelse return 1;
    if (value.len == 0) return 1;
    var count: usize = 1;
    for (value) |ch| {
        if (ch == '\n') count += 1;
    }
    return count;
}
