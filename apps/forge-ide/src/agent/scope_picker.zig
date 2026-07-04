const std = @import("std");
const explorer_tree = @import("../explorer/tree.zig");

pub fn collectFilePaths(
    allocator: std.mem.Allocator,
    explorer: *const explorer_tree.Tree,
    out: *std.ArrayList([]const u8),
) !void {
    for (explorer.entries) |entry| {
        if (entry.kind != .file) continue;
        try out.append(allocator, try allocator.dupe(u8, entry.path));
    }
}

pub fn applyFilter(allocator: std.mem.Allocator, query: []const u8, paths: []const []const u8, out: *std.ArrayList(usize)) !void {
    out.clearRetainingCapacity();
    for (paths, 0..) |path, index| {
        if (query.len == 0 or matchesQuery(query, path) or matchesQuery(query, std.fs.path.basename(path))) {
            try out.append(allocator, index);
        }
    }
}

pub fn matchesQuery(query: []const u8, haystack: []const u8) bool {
    if (query.len == 0) return true;
    var h_index: usize = 0;
    for (query) |q| {
        const lower_q = std.ascii.toLower(q);
        while (h_index < haystack.len) : (h_index += 1) {
            if (std.ascii.toLower(haystack[h_index]) == lower_q) {
                h_index += 1;
                break;
            }
        } else return false;
    }
    return true;
}

test "scope picker fuzzy matches path" {
    const paths = [_][]const u8{ "apps/forge-ide/src/main.zig", "README.md" };
    var indices: std.ArrayList(usize) = .empty;
    defer indices.deinit(std.testing.allocator);
    try applyFilter(std.testing.allocator, "main", &paths, &indices);
    try std.testing.expectEqual(@as(usize, 1), indices.items.len);
    try std.testing.expectEqual(@as(usize, 0), indices.items[0]);
}
