const std = @import("std");

pub const Limits = struct {
    pub const max_file_size: u64 = 50 * 1024 * 1024; // 50MB
    pub const max_traversal_depth: u16 = 64;
    pub const max_entries: u32 = 100_000;
};

pub const IgnoreRules = struct {
    /// Checks if a single path component is ignored by built-in rules.
    /// This is an M1 MVP evaluator. A robust implementation would parse .gitignore files
    /// and match full paths with glob patterns.
    pub fn isIgnored(component: []const u8) bool {
        const builtins = [_][]const u8{
            ".git",
            ".zig-cache",
            "zig-out",
            "zig-pkg",
            "node_modules",
            ".DS_Store",
            ".forge",
            ".cursor",
            "target",
            "dist",
            "coverage",
            "out",
        };
        for (builtins) |b| {
            if (std.mem.eql(u8, component, b)) return true;
        }
        return false;
    }
};

test "IgnoreRules recognizes built-ins" {
    try std.testing.expect(IgnoreRules.isIgnored(".git"));
    try std.testing.expect(IgnoreRules.isIgnored("zig-out"));
    try std.testing.expect(IgnoreRules.isIgnored(".DS_Store"));

    try std.testing.expect(!IgnoreRules.isIgnored("src"));
    try std.testing.expect(!IgnoreRules.isIgnored("main.zig"));
    try std.testing.expect(!IgnoreRules.isIgnored("README.md"));

    try std.testing.expect(IgnoreRules.isIgnored(".forge"));
}
