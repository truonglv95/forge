//! Domain-independent utilities shared by Forge packages.

const std = @import("std");

pub fn eqlIgnoreAsciiCase(lhs: []const u8, rhs: []const u8) bool {
    return std.ascii.eqlIgnoreCase(lhs, rhs);
}

pub fn trimAscii(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r\n");
}

test "ASCII helpers are allocation free" {
    try std.testing.expect(eqlIgnoreAsciiCase("Forge", "forge"));
    try std.testing.expectEqualStrings("kernel", trimAscii("  kernel\n"));
}
