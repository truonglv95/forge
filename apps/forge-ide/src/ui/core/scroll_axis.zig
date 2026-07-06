const std = @import("std");

/// Keep scroll on the stronger axis only (VS Code `scrollPredominantAxis`).
/// Prevents horizontal drift when scrolling vertically on a trackpad.
pub fn predominantDeltas(delta_x: f32, delta_y: f32) struct { x: f32, y: f32 } {
    if (delta_x == 0 and delta_y == 0) return .{ .x = 0, .y = 0 };
    if (@abs(delta_y) >= @abs(delta_x)) return .{ .x = 0, .y = delta_y };
    return .{ .x = delta_x, .y = 0 };
}

test "predominantDeltas prefers vertical" {
    const d = predominantDeltas(2, 10);
    try std.testing.expectEqual(@as(f32, 0), d.x);
    try std.testing.expectEqual(@as(f32, 10), d.y);
}

test "predominantDeltas prefers horizontal" {
    const d = predominantDeltas(12, 3);
    try std.testing.expectEqual(@as(f32, 12), d.x);
    try std.testing.expectEqual(@as(f32, 0), d.y);
}

test "predominantDeltas ties go vertical" {
    const d = predominantDeltas(5, 5);
    try std.testing.expectEqual(@as(f32, 0), d.x);
    try std.testing.expectEqual(@as(f32, 5), d.y);
}
