const std = @import("std");
const context = @import("context.zig");

pub const Tier = enum(u8) {
    critical = 0,
    high = 1,
    medium = 2,
    low = 3,
};

pub fn blockTier(btype: context.BlockType) Tier {
    return switch (btype) {
        .rules, .intent, .memory => .critical,
        .file, .attachment, .diagnostic, .lsp, .git_diff => .high,
        .semantic, .retrieval, .fused, .web => .medium,
        .recent, .imports, .docs => .low,
    };
}

/// Returns false when optional blocks should be skipped to preserve budget for higher tiers.
pub fn hasBudgetFor(tier: Tier, used_bytes: usize, max_bytes: usize) bool {
    if (max_bytes == 0) return false;
    const remaining = max_bytes -| used_bytes;
    return switch (tier) {
        .critical => true,
        .high => remaining > max_bytes / 10 or used_bytes * 10 < max_bytes * 9,
        .medium => remaining > max_bytes / 4,
        .low => remaining > max_bytes / 2,
    };
}

pub fn tierLabel(tier: Tier) []const u8 {
    return switch (tier) {
        .critical => "critical",
        .high => "high",
        .medium => "medium",
        .low => "low",
    };
}

pub fn formatSkipReason(allocator: std.mem.Allocator, btype: context.BlockType) ![]const u8 {
    const tier = blockTier(btype);
    return std.fmt.allocPrint(allocator, "Skipped ({s} priority) — context budget reserved", .{tierLabel(tier)});
}

test "low tier blocks defer when budget tight" {
    try std.testing.expect(!hasBudgetFor(.low, 900_000, 1_000_000));
    try std.testing.expect(hasBudgetFor(.low, 400_000, 1_000_000));
    try std.testing.expect(hasBudgetFor(.critical, 990_000, 1_000_000));
}
