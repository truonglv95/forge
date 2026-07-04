const std = @import("std");
const layout = @import("layout.zig");

pub const list_top: f32 = 80;
pub const row_height: f32 = 20;

pub fn viewportHeight(window_h: f32) f32 {
    return @max(0, window_h - layout.status_height - list_top);
}

pub fn contentHeight(row_count: usize) f32 {
    return @as(f32, @floatFromInt(row_count)) * row_height;
}

pub fn maxScrollY(row_count: usize, window_h: f32) f32 {
    return @max(0, contentHeight(row_count) - viewportHeight(window_h));
}

pub fn clampScrollY(scroll_y: f32, row_count: usize, window_h: f32) f32 {
    return std.math.clamp(scroll_y, 0, maxScrollY(row_count, window_h));
}

pub fn rowAtPoint(scroll_y: f32, y: f32) ?usize {
    if (y < list_top) return null;
    const float_row = (y - list_top + scroll_y) / row_height;
    if (float_row < 0) return null;
    return @intFromFloat(float_row);
}

test "explorer scroll reaches last row" {
    const max = maxScrollY(100, 800);
    try std.testing.expect(max > 0);
    try std.testing.expectEqual(@as(f32, 0), maxScrollY(10, 800));
}
