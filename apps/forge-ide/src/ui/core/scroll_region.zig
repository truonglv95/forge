const std = @import("std");

pub const Region = struct {
    content_h: f32,
    viewport_h: f32,

    pub fn maxScrollY(self: Region) f32 {
        return @max(0, self.content_h - @max(0, self.viewport_h));
    }

    pub fn clamp(self: Region, scroll_y: f32) f32 {
        return std.math.clamp(scroll_y, 0, self.maxScrollY());
    }

    pub fn visibleRange(self: Region, scroll_y: f32, row_h: f32, row_count: usize) struct { first: usize, last: usize } {
        if (row_h <= 0 or row_count == 0 or self.viewport_h <= 0) return .{ .first = 0, .last = 0 };
        const clamped = self.clamp(scroll_y);
        const first_float = @max(0, @floor(clamped / row_h));
        const last_float = @ceil((clamped + self.viewport_h) / row_h);
        const first: usize = @min(row_count, @as(usize, @intFromFloat(first_float)));
        const last: usize = @min(row_count, @as(usize, @intFromFloat(last_float)) + 1);
        return .{ .first = first, .last = last };
    }
};

pub fn region(content_h: f32, viewport_h: f32) Region {
    return .{ .content_h = @max(0, content_h), .viewport_h = @max(0, viewport_h) };
}

test "scroll region clamps and virtualizes rows" {
    const r = region(1000, 200);
    try std.testing.expectEqual(@as(f32, 800), r.maxScrollY());
    try std.testing.expectEqual(@as(f32, 0), r.clamp(-10));
    try std.testing.expectEqual(@as(f32, 800), r.clamp(900));
    const visible = r.visibleRange(120, 20, 100);
    try std.testing.expectEqual(@as(usize, 6), visible.first);
    try std.testing.expectEqual(@as(usize, 17), visible.last);
}
