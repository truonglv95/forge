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

pub const GrepOptions = struct {
    pattern: []const u8,
    path: []const u8 = ".",
    glob: ?[]const u8 = null,
    case_sensitive: bool = false,
    head_limit: usize = 50,
};

pub fn grepContent(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
    options: GrepOptions,
) !SearchResult {
    const head_limit = @min(@max(options.head_limit, 1), 200);
    var summary = try tree.scan(allocator, io, root, options.path);
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
        if (!pathInScope(entry.path, options.path)) continue;
        if (options.glob) |glob| {
            if (!globMatches(entry.path, glob)) continue;
        }

        const wp = try path_mod.WorkspacePath.parse(entry.path);
        var snap = snapshot.FileSnapshot.read(allocator, io, root, wp) catch continue;
        defer snap.deinit();

        if (snap.content.len > ignore.Limits.max_file_size) continue;
        if (!std.unicode.utf8ValidateSlice(snap.content)) continue;

        var line_number: u32 = 1;
        var line_start: usize = 0;
        for (snap.content, 0..) |byte, index| {
            if (byte == '\n') {
                try scanLine(allocator, &matches, entry.path, options, snap.content[line_start..index], line_number, head_limit);
                if (matches.items.len >= head_limit) break;
                line_start = index + 1;
                line_number += 1;
            }
        }
        if (matches.items.len >= head_limit) break;
        if (line_start <= snap.content.len) {
            const tail = snap.content[line_start..];
            if (tail.len > 0 or line_number == 1) {
                try scanLine(allocator, &matches, entry.path, options, tail, line_number, head_limit);
            }
        }
        if (matches.items.len >= head_limit) break;
    }

    return SearchResult{
        .allocator = allocator,
        .query = try allocator.dupe(u8, options.pattern),
        .matches = try matches.toOwnedSlice(allocator),
    };
}

pub fn searchContent(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
    root_path: []const u8,
    query: []const u8,
) !SearchResult {
    return grepContent(allocator, io, root, .{
        .pattern = query,
        .path = root_path,
        .case_sensitive = true,
    });
}

fn pathInScope(entry_path: []const u8, scope: []const u8) bool {
    if (scope.len == 0 or std.mem.eql(u8, scope, ".")) return true;
    const normalized = std.mem.trim(u8, scope, "/");
    if (normalized.len == 0) return true;
    if (std.mem.eql(u8, entry_path, normalized)) return true;
    if (entry_path.len <= normalized.len) return false;
    if (!std.mem.startsWith(u8, entry_path, normalized)) return false;
    return entry_path[normalized.len] == '/';
}

fn globMatches(path: []const u8, glob: []const u8) bool {
    const target = if (std.mem.indexOfScalar(u8, glob, '/')) |_| path else std.fs.path.basename(path);
    return simpleGlob(target, glob);
}

fn simpleGlob(text: []const u8, pattern: []const u8) bool {
    return globRec(text, pattern, 0, 0);
}

fn globRec(text: []const u8, pattern: []const u8, ti: usize, pi: usize) bool {
    if (pi == pattern.len) return ti == text.len;
    if (pattern[pi] == '*') {
        var skip: usize = pi + 1;
        while (skip < pattern.len and pattern[skip] == '*') skip += 1;
        if (skip == pattern.len) return true;
        var start: usize = ti;
        while (start <= text.len) : (start += 1) {
            if (globRec(text, pattern, start, skip)) return true;
        }
        return false;
    }
    if (ti == text.len) return false;
    const pc = pattern[pi];
    const tc = text[ti];
    if (pc == '?' or pc == tc) return globRec(text, pattern, ti + 1, pi + 1);
    return false;
}

fn scanLine(
    allocator: std.mem.Allocator,
    matches: *std.ArrayList(Match),
    path: []const u8,
    options: GrepOptions,
    line: []const u8,
    line_number: u32,
    head_limit: usize,
) !void {
    if (options.pattern.len == 0) return;
    if (matches.items.len >= head_limit) return;

    var parts = std.mem.splitScalar(u8, options.pattern, '|');
    while (parts.next()) |part| {
        const needle = std.mem.trim(u8, part, " \t");
        if (needle.len == 0) continue;
        var offset: usize = 0;
        while (offset <= line.len and matches.items.len < head_limit) {
            const found = findNeedle(line, needle, offset, options.case_sensitive) orelse break;
            try matches.append(allocator, .{
                .path = try allocator.dupe(u8, path),
                .line = line_number,
                .column = @intCast(found + 1),
                .line_text = try allocator.dupe(u8, line),
            });
            offset = found + @max(needle.len, 1);
        }
    }
}

fn findNeedle(haystack: []const u8, needle: []const u8, offset: usize, case_sensitive: bool) ?usize {
    if (case_sensitive) return std.mem.indexOfPos(u8, haystack, offset, needle);
    if (needle.len == 0) return offset;
    var i = offset;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return i;
    }
    return null;
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

    const root = path_mod.WorkspaceRoot.init(tmp.dir, ".");
    var result = try searchContent(allocator, io, root, ".", "forge");
    defer result.deinit();

    try std.testing.expect(result.matches.len >= 1);
    try std.testing.expect(std.mem.indexOf(u8, result.matches[0].line_text, "forge") != null);
}

test "grep is case-insensitive by default" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(io, "Tensor.py", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "class Tensor\n");
    }

    const root = path_mod.WorkspaceRoot.init(tmp.dir, ".");
    var result = try grepContent(allocator, io, root, .{ .pattern = "tensor" });
    defer result.deinit();
    try std.testing.expect(result.matches.len >= 1);
}

test "grep supports alternation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    {
        var a = try tmp.dir.createFile(io, "a.py", .{});
        defer a.close(io);
        try a.writeStreamingAll(io, "engine start\n");
        var b = try tmp.dir.createFile(io, "b.py", .{});
        defer b.close(io);
        try b.writeStreamingAll(io, "tensor init\n");
    }

    const root = path_mod.WorkspaceRoot.init(tmp.dir, ".");
    var result = try grepContent(allocator, io, root, .{ .pattern = "engine|tensor" });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.matches.len);
}

test "grep filters by glob" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    {
        var py = try tmp.dir.createFile(io, "a.py", .{});
        defer py.close(io);
        try py.writeStreamingAll(io, "needle\n");
        var txt = try tmp.dir.createFile(io, "a.txt", .{});
        defer txt.close(io);
        try txt.writeStreamingAll(io, "needle\n");
    }

    const root = path_mod.WorkspaceRoot.init(tmp.dir, ".");
    var result = try grepContent(allocator, io, root, .{ .pattern = "needle", .glob = "*.py" });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expectEqualStrings("a.py", result.matches[0].path);
}

test "grep respects head_limit" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(io, "many.txt", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "hit hit hit hit hit\n");
    }

    const root = path_mod.WorkspaceRoot.init(tmp.dir, ".");
    var result = try grepContent(allocator, io, root, .{ .pattern = "hit", .head_limit = 2 });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.matches.len);
}
