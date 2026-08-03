const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;

pub const Match = struct {
    row: usize,
    col: usize,
    len: usize,
};

pub fn findAll(allocator: std.mem.Allocator, buf: *const Buffer, needle: []const u8) ![]Match {
    if (needle.len == 0) return &.{};

    var out: std.ArrayList(Match) = .empty;
    errdefer out.deinit(allocator);

    var row: usize = 0;
    while (row < buf.lineCount()) : (row += 1) {
        const line = buf.lineAt(row);
        var start: usize = 0;
        while (std.mem.indexOfPos(u8, line, start, needle)) |idx| {
            try out.append(allocator, .{ .row = row, .col = idx, .len = needle.len });
            start = idx + 1;
        }
    }
    return try out.toOwnedSlice(allocator);
}

pub fn findNext(matches: []const Match, cursor_row: usize, cursor_col: usize) ?usize {
    if (matches.len == 0) return null;
    for (matches, 0..) |match, index| {
        if (match.row > cursor_row or (match.row == cursor_row and match.col >= cursor_col)) {
            return index;
        }
    }
    return 0;
}

pub fn findPrev(matches: []const Match, cursor_row: usize, cursor_col: usize) ?usize {
    if (matches.len == 0) return null;
    var index = matches.len;
    while (index > 0) {
        index -= 1;
        const match = matches[index];
        if (match.row < cursor_row or (match.row == cursor_row and match.col < cursor_col)) {
            return index;
        }
    }
    return matches.len - 1;
}

test "findAll locates needle" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator);
    defer buf.deinit();
    try buf.loadFromSlice("hello forge\nforge again");

    const matches = try findAll(allocator, &buf, "forge");
    defer allocator.free(matches);
    try std.testing.expectEqual(@as(usize, 2), matches.len);
}
