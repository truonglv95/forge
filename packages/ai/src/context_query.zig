const std = @import("std");

const Expansion = struct {
    needle: []const u8,
    terms: []const []const u8,
};

const expansions = [_]Expansion{
    .{ .needle = "đánh giá", .terms = &.{ "review", "evaluate", "assessment" } },
    .{ .needle = "danh gia", .terms = &.{ "review", "evaluate", "assessment" } },
    .{ .needle = "tổng quan", .terms = &.{ "overview", "architecture", "summary" } },
    .{ .needle = "tong quan", .terms = &.{ "overview", "architecture", "summary" } },
    .{ .needle = "ngữ cảnh", .terms = &.{ "context", "prompt", "retrieval" } },
    .{ .needle = "ngu canh", .terms = &.{ "context", "prompt", "retrieval" } },
    .{ .needle = "tìm kiếm", .terms = &.{ "search", "retrieval", "query" } },
    .{ .needle = "tim kiem", .terms = &.{ "search", "retrieval", "query" } },
    .{ .needle = "lỗi", .terms = &.{ "error", "failure", "diagnostic" } },
    .{ .needle = "loi", .terms = &.{ "error", "failure", "diagnostic" } },
    .{ .needle = "sửa", .terms = &.{ "fix", "edit", "patch" } },
    .{ .needle = "sua", .terms = &.{ "fix", "edit", "patch" } },
    .{ .needle = "giao diện", .terms = &.{ "ui", "render", "layout" } },
    .{ .needle = "giao dien", .terms = &.{ "ui", "render", "layout" } },
    .{ .needle = "bộ nhớ", .terms = &.{ "memory", "state", "session" } },
    .{ .needle = "bo nho", .terms = &.{ "memory", "state", "session" } },
    .{ .needle = "lịch sử", .terms = &.{ "history", "conversation", "session" } },
    .{ .needle = "lich su", .terms = &.{ "history", "conversation", "session" } },
};

pub fn expandForCodeSearch(allocator: std.mem.Allocator, query: []const u8) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try out.writer.writeAll(query);

    var added = std.StringHashMap(void).init(allocator);
    defer added.deinit();

    for (expansions) |entry| {
        if (std.ascii.indexOfIgnoreCase(query, entry.needle) == null) continue;
        for (entry.terms) |term| {
            if (std.ascii.indexOfIgnoreCase(query, term) != null) continue;
            if (added.contains(term)) continue;
            try added.put(term, {});
            try out.writer.print(" {s}", .{term});
        }
    }

    return try out.toOwnedSlice();
}

test "expandForCodeSearch adds English retrieval terms for Vietnamese prompts" {
    const allocator = std.testing.allocator;
    const expanded = try expandForCodeSearch(allocator, "đánh giá tổng quan ngữ cảnh");
    defer allocator.free(expanded);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "review") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "architecture") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "context") != null);
}
