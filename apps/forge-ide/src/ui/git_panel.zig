const std = @import("std");
const layout = @import("layout.zig");
const git_status = @import("../git/status.zig");

pub const list_top: f32 = 96;
pub const row_h: f32 = 28;

pub fn contentHeight(entry_count: usize) f32 {
    return @as(f32, @floatFromInt(entry_count)) * row_h + 8;
}

pub fn viewportHeight(window_h: f32) f32 {
    return @max(0, window_h - layout.status_height - list_top);
}

pub fn maxScrollY(entry_count: usize, window_h: f32) f32 {
    return @max(0, contentHeight(entry_count) - viewportHeight(window_h));
}

pub fn clampScrollY(scroll_y: f32, entry_count: usize, window_h: f32) f32 {
    return std.math.clamp(scroll_y, 0, maxScrollY(entry_count, window_h));
}

pub const Hit = union(enum) {
    refresh,
    open_file: usize,
};

pub fn hitTest(
    entries: []const git_status.Entry,
    panel_x: f32,
    panel_w: f32,
    click_x: f32,
    click_y: f32,
    scroll_y: f32,
) ?Hit {
    if (click_x < panel_x or click_x >= panel_x + panel_w) return null;
    const local_y = click_y - list_top + scroll_y;

    if (local_y >= 0 and local_y < 22 and click_x >= panel_x + 12 and click_x < panel_x + panel_w - 12) {
        return .refresh;
    }

    var y: f32 = 28;
    for (entries, 0..) |_, index| {
        if (local_y >= y and local_y < y + row_h) return .{ .open_file = index };
        y += row_h;
    }
    return null;
}
