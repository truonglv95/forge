const std = @import("std");

pub fn main() !void {
    std.debug.print("Baseline fixture main.\n", .{});
}

test "baseline passes" {
    try std.testing.expect(true);
}
