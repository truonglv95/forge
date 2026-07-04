const std = @import("std");
const panel_scroll = @import("panel_scroll.zig");

pub fn hitTest(
    editor_x: f32,
    panel_y: f32,
    panel_h: f32,
    x: f32,
    y: f32,
    scroll_y: f32,
    item_count: usize,
) ?usize {
    const top = panel_y + panel_scroll.bottom_content_top;
    const viewport = panel_scroll.bottomViewportHeight(panel_h);
    if (x < editor_x or y < top or y >= top + viewport) return null;

    const float_line = (y - top + scroll_y) / panel_scroll.bottom_line_h;
    if (float_line < 0) return null;
    const line: usize = @intFromFloat(float_line);
    if (line >= item_count) return null;
    return line;
}
