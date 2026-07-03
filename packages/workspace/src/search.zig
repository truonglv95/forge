const std = @import("std");
const edit = @import("edit.zig");
const path_mod = @import("path.zig");
const snapshot = @import("snapshot.zig");
const tree = @import("tree.zig");
const ignore = @import("ignore.zig");

pub const Match = struct {
    path: []const u8,
    line: u32,
    column: u32,
    line_text: []const u8,
};

pub const SearchResult = struct {
    allocator: std.mem.Allocator,
    query: []const u8,
    matches: []Match,

    pub fn deinit(self: *SearchResult) void {
        for (self.matches) |match| {
            self.allocator.free(match.path);
            self.allocator.free(match.line_text);
        }
        self.allocator.free(self.matches);
        self.allocator.free(self.query);
        self.* = undefined;
    }
};

pub fn searchContent(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
    root_path: []const u8,
    query: []const u8,
) !SearchResult {
    var summary = try tree.scan(allocator, io, root, root_path);
    defer summary.deinit();

    var matches: std.ArrayList(Match) = .empty;
    errdefer {
        for (matches.items) |match| {
            allocator.free(match.path);
            allocator.free(match.line_text);
        }
        matches.deinit(allocator);
    }

    for (summary.entries) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.path, ".proposal.json") or std.mem.startsWith(u8, entry.path, ".forge/")) continue;

        const wp = try path_mod.WorkspacePath.parse(entry.path);
        var snap = snapshot.FileSnapshot.read(allocator, io, root, wp) catch continue;
        defer snap.deinit();

        if (snap.content.len > ignore.Limits.max_file_size) continue;
        if (!std.unicode.utf8ValidateSlice(snap.content)) continue;

        var line_number: u32 = 1;
        var line_start: usize = 0;
        for (snap.content, 0..) |byte, index| {
            if (byte == '\n') {
                try scanLine(allocator, &matches, entry.path, query, snap.content[line_start..index], line_number);
                line_start = index + 1;
                line_number += 1;
            }
        }
        if (line_start <= snap.content.len) {
            const tail = snap.content[line_start..];
            if (tail.len > 0 or line_number == 1) {
                try scanLine(allocator, &matches, entry.path, query, tail, line_number);
            }
        }
    }

    return SearchResult{
        .allocator = allocator,
        .query = try allocator.dupe(u8, query),
        .matches = try matches.toOwnedSlice(allocator),
    };
}

fn scanLine(
    allocator: std.mem.Allocator,
    matches: *std.ArrayList(Match),
    path: []const u8,
    query: []const u8,
    line: []const u8,
    line_number: u32,
) !void {
    if (query.len == 0) return;
    var offset: usize = 0;
    while (offset <= line.len) {
        const found = std.mem.indexOfPos(u8, line, offset, query) orelse break;
        try matches.append(allocator, .{
            .path = try allocator.dupe(u8, path),
            .line = line_number,
            .column = @intCast(found + 1),
            .line_text = try allocator.dupe(u8, line),
        });
        offset = found + query.len;
    }
}

test "search finds literal matches" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();

    {
        var file = try tmp.dir.createFile(io, "sample.txt", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "hello forge\nsecond line\n");
    }

    const root = path_mod.WorkspaceRoot.init(tmp.dir);
    var result = try searchContent(allocator, io, root, ".", "forge");
    defer result.deinit();

    try std.testing.expect(result.matches.len >= 1);
    try std.testing.expect(std.mem.indexOf(u8, result.matches[0].line_text, "forge") != null);
}
