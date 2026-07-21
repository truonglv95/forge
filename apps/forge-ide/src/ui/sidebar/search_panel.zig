const std = @import("std");
const layout = @import("../core/layout.zig");
const workspace = @import("forge-workspace");

pub const panel_top: f32 = layout.header_height + layout.activity_bar_height;
pub const header_h: f32 = 38;
pub const query_top: f32 = panel_top + header_h + 4;
pub const query_box_h: f32 = 34;
pub const search_button_top: f32 = query_top + query_box_h + 10;
pub const search_button_h: f32 = 28;
pub const list_top: f32 = search_button_top + search_button_h + 18;
pub const row_h: f32 = 34;

pub fn contentHeight(result_count: usize) f32 {
    return @as(f32, @floatFromInt(result_count)) * row_h + 8;
}

pub fn viewportHeight(window_h: f32) f32 {
    return @max(0, window_h - layout.status_height - list_top);
}

pub fn maxScrollY(result_count: usize, window_h: f32) f32 {
    return @max(0, contentHeight(result_count) - viewportHeight(window_h));
}

pub fn clampScrollY(scroll_y: f32, result_count: usize, window_h: f32) f32 {
    return std.math.clamp(scroll_y, 0, maxScrollY(result_count, window_h));
}

pub const Hit = union(enum) {
    run_search,
    open_result: usize,
};

pub fn hitTest(
    results: []const workspace.search.Match,
    panel_x: f32,
    panel_w: f32,
    click_x: f32,
    click_y: f32,
    scroll_y: f32,
) ?Hit {
    if (click_x < panel_x or click_x >= panel_x + panel_w) return null;

    if (click_y >= search_button_top and click_y < search_button_top + search_button_h and
        click_x >= panel_x + 12 and click_x < panel_x + panel_w - 12)
    {
        return .run_search;
    }

    const local_y = click_y - list_top + scroll_y;
    var y: f32 = 0;
    for (results, 0..) |_, index| {
        if (local_y >= y and local_y < y + row_h) return .{ .open_result = index };
        y += row_h;
    }
    return null;
}
