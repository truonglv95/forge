const std = @import("std");
const panel_scroll = @import("../ui/core/panel_scroll.zig");

pub const Item = struct {
    path: []const u8,
    line: u32,
    character: u32,
    label: []const u8,

    pub fn deinit(self: *Item, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.label);
        self.* = undefined;
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    items: []Item = &.{},
    active: bool = false,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        self.clear();
    }

    pub fn clear(self: *Store) void {
        for (self.items) |*item| item.deinit(self.allocator);
        self.allocator.free(self.items);
        self.items = &.{};
        self.active = false;
    }

    pub fn setItems(self: *Store, items: []Item) void {
        self.clear();
        self.items = items;
        self.active = items.len > 0;
    }

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
};
