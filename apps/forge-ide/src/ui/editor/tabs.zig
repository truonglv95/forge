const std = @import("std");
const Workbench = @import("../../workbench.zig").Workbench;

pub const tab_gap: f32 = 0;
pub const tab_padding_start: f32 = 10;
pub const tab_bar_top: f32 = 30;
pub const tab_bar_height: f32 = 35;
pub const tab_y: f32 = 30;
pub const tab_height: f32 = 35;
pub const close_button_width: f32 = 20;
pub const label_char_width: f32 = 8;
pub const label_pad: f32 = 24;
pub const max_tab_width: f32 = 200;

pub const TabLayout = struct {
    index: usize,
    x: f32,
    width: f32,
};

pub fn tabWidth(label_len: usize) f32 {
    const raw = @as(f32, @floatFromInt(label_len)) * label_char_width + label_pad + close_button_width;
    return @min(raw, max_tab_width);
}

pub fn collectLayouts(wb: *const Workbench, editor_x: f32, editor_w: f32, out: *std.ArrayList(TabLayout)) !void {
    const visible_tab_w = @max(10.0, editor_w - 60.0);
    const num_tabs = wb.tabs.tabs.items.len;
    if (num_tabs == 0) return;

    var total_raw: f32 = tab_padding_start;
    for (0..num_tabs) |tab_index| {
        var label_buf: [128]u8 = undefined;
        const label = wb.tabLabel(tab_index, &label_buf);
        total_raw += tabWidth(label.len) + tab_gap;
    }
    if (num_tabs > 0) total_raw -= tab_gap;

    const scale = if (total_raw > visible_tab_w) visible_tab_w / total_raw else 1.0;
    var x = editor_x + tab_padding_start * scale;

    for (0..num_tabs) |tab_index| {
        var label_buf: [128]u8 = undefined;
        const label = wb.tabLabel(tab_index, &label_buf);
        const w = tabWidth(label.len) * scale;
        try out.append(wb.allocator, .{ .index = tab_index, .x = x, .width = w });
        x += w + tab_gap * scale;
    }
}

pub fn totalContentWidth(wb: *const Workbench) f32 {
    _ = wb;
    return 0; // Handled by shrinking now
}

pub fn maxScroll(wb: *const Workbench, editor_w: f32) f32 {
    _ = wb;
    _ = editor_w;
    return 0;
}

pub fn clampScroll(scroll_x: f32, wb: *const Workbench, editor_w: f32) f32 {
    return std.math.clamp(scroll_x, 0, maxScroll(wb, editor_w));
}

pub fn scrollToTab(wb: *Workbench, tab_index: usize, editor_x: f32, editor_w: f32) void {
    var label_buf: [128]u8 = undefined;
    const label = wb.tabLabel(tab_index, &label_buf);
    const width = tabWidth(label.len);

    var x: f32 = tab_padding_start;
    for (0..tab_index) |idx| {
        var prior_buf: [128]u8 = undefined;
        const prior = wb.tabLabel(idx, &prior_buf);
        x += tabWidth(prior.len) + tab_gap;
    }

    const tab_left = x;
    const tab_right = x + width;
    const visible_left = wb.tab_scroll_x;
    const visible_right = wb.tab_scroll_x + editor_w;

    if (tab_left < visible_left) {
        wb.tab_scroll_x = tab_left;
    } else if (tab_right > visible_right) {
        wb.tab_scroll_x = tab_right - editor_w;
    }
    _ = editor_x;
    wb.tab_scroll_x = clampScroll(wb.tab_scroll_x, wb, editor_w);
}

pub const Hit = union(enum) {
    none,
    activate: usize,
    close: usize,
};

pub fn hitTest(layouts: []const TabLayout, x: f32, y: f32) Hit {
    if (y < tab_bar_top or y >= tab_bar_top + tab_bar_height) return .none;
    for (layouts) |layout| {
        if (x < layout.x or x >= layout.x + layout.width) continue;
        const close_x = layout.x + layout.width - close_button_width;
        if (x >= close_x) return .{ .close = layout.index };
        return .{ .activate = layout.index };
    }
    return .none;
}

test "tab width includes close button" {
    try std.testing.expect(tabWidth(10) >= close_button_width + 24);
}

test "max scroll grows with many tabs" {
    const allocator = std.testing.allocator;
    var wb: Workbench = undefined;
    try Workbench.init(&wb, allocator, std.testing.io, ".", "forge-ide", null);
    defer wb.deinit();
    try wb.tabs.openOrActivate("a.zig");
    try wb.tabs.openOrActivate("b.zig");
    try wb.tabs.openOrActivate("very-long-filename-example.zig");
    const max = maxScroll(&wb, 200);
    try std.testing.expect(max > 0);
}
