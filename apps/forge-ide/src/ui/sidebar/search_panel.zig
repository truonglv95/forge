const std = @import("std");
const layout = @import("../core/layout.zig");
const workspace = @import("forge-workspace");

pub const panel_top: f32 = layout.header_height + layout.activity_bar_height;
pub const header_h: f32 = 38;
pub const query_top: f32 = panel_top + header_h + 4;
pub const query_box_h: f32 = 28;
pub const replace_box_h: f32 = 28;
pub const replace_top: f32 = query_top + query_box_h + 4;
pub const search_button_top: f32 = replace_top + replace_box_h + 8;
pub const search_button_h: f32 = 26;
pub const list_top: f32 = search_button_top + search_button_h + 14;
pub const row_h: f32 = 34;

pub fn contentHeight(result_count: usize) f32 {
    return @as(f32, @floatFromInt(result_count)) * row_h + 8;
}

pub fn viewportHeight(window_h: f32, show_replace: bool) f32 {
    const extra: f32 = if (show_replace) replace_box_h + 4 else 0;
    return @max(0, window_h - layout.status_height - list_top - extra);
}

pub fn maxScrollY(result_count: usize, window_h: f32, show_replace: bool) f32 {
    return @max(0, contentHeight(result_count) - viewportHeight(window_h, show_replace));
}

pub fn clampScrollY(scroll_y: f32, result_count: usize, window_h: f32, show_replace: bool) f32 {
    return std.math.clamp(scroll_y, 0, maxScrollY(result_count, window_h, show_replace));
}

pub const Hit = union(enum) {
    run_search,
    open_result: usize,
    toggle_replace,
    replace_all,
};

pub fn hitTest(
    results: []const workspace.search.Match,
    panel_x: f32,
    panel_w: f32,
    click_x: f32,
    click_y: f32,
    scroll_y: f32,
    show_replace: bool,
) ?Hit {
    if (click_x < panel_x or click_x >= panel_x + panel_w) return null;

    // Toggle replace button (chevron next to SEARCH header)
    if (click_y >= panel_top + 8 and click_y < panel_top + 28 and
        click_x >= panel_x + 8 and click_x < panel_x + 28)
    {
        return .toggle_replace;
    }

    // Search button
    if (click_y >= search_button_top and click_y < search_button_top + search_button_h and
        click_x >= panel_x + 12 and click_x < panel_x + panel_w - 12)
    {
        return .run_search;
    }

    // Replace All button (only when replace is visible)
    if (show_replace and click_y >= search_button_top and click_y < search_button_top + search_button_h and
        click_x >= panel_x + panel_w - 80 and click_x < panel_x + panel_w - 12)
    {
        return .replace_all;
    }

    // Results list
    const _vp_h = viewportHeight(@as(f32, 0) + 9999, show_replace);
    _ = _vp_h;
    const local_y = click_y - list_top + scroll_y;
    var y: f32 = 0;
    for (results, 0..) |_, index| {
        if (local_y >= y and local_y < y + row_h) return .{ .open_result = index };
        y += row_h;
    }
    return null;
}
