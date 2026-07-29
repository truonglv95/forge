const std = @import("std");

test "intentional failure" {
    // This is intentionally designed to fail when `forge check` or `zig build test` hits it.
    try std.testing.expect(false);
}
