const std = @import("std");

pub const bottom_line_h: f32 = 14.0;
pub const bottom_content_top: f32 = 34.0;

pub fn clampScrollY(scroll_y: f32, line_count: usize, viewport_h: f32, line_h: f32) f32 {
    if (line_count == 0 or viewport_h <= 0) return 0;
    const content_h = @as(f32, @floatFromInt(line_count)) * line_h;
    const max_scroll = @max(0, content_h - viewport_h);
    return std.math.clamp(scroll_y, 0, max_scroll);
}

pub fn bottomViewportHeight(panel_h: f32) f32 {
    return @max(0, panel_h - bottom_content_top);
}
