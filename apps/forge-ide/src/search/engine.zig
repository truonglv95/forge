const std = @import("std");
const workspace = @import("forge-workspace");
const explorer_tree = @import("../explorer/tree.zig");

pub const Match = struct {
    path: []const u8,
    line: ?usize = null,
    preview: []const u8,

    pub fn deinit(self: *Match, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.preview);
        self.* = undefined;
    }
};

pub const ResultSet = struct {
    matches: []Match,

    pub fn deinit(self: *ResultSet, allocator: std.mem.Allocator) void {
        for (self.matches) |*match| match.deinit(allocator);
        allocator.free(self.matches);
        self.* = undefined;
    }
};

const max_results: usize = 120;
const max_file_bytes: usize = 256 * 1024;

pub fn searchWorkspace(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    explorer: *const explorer_tree.Tree,
    query: []const u8,
) !ResultSet {
    var list: std.ArrayList(Match) = .empty;
    errdefer {
        for (list.items) |*match| match.deinit(allocator);
        list.deinit(allocator);
    }

    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len == 0) return .{ .matches = &.{} };

    const lower_query = try toLower(allocator, trimmed);
    defer allocator.free(lower_query);

    for (explorer.entries) |entry| {
        if (list.items.len >= max_results) break;
        if (entry.kind != .file) continue;
        if (shouldSkipPath(entry.path)) continue;

        const base = std.fs.path.basename(entry.path);
        if (containsIgnoreCase(base, lower_query)) {
            try list.append(allocator, .{
                .path = try allocator.dupe(u8, entry.path),
                .line = null,
                .preview = try std.fmt.allocPrint(allocator, "{s}", .{base}),
            });
            continue;
        }

        if (!containsIgnoreCase(entry.path, lower_query)) continue;
        try searchFileContent(allocator, io, root, entry.path, lower_query, &list);
    }

    return .{ .matches = try list.toOwnedSlice(allocator) };
}

fn searchFileContent(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    path: []const u8,
    lower_query: []const u8,
    out: *std.ArrayList(Match),
) !void {
    const wp = workspace.WorkspacePath.parse(path) catch return;
    var snap = workspace.FileSnapshot.read(allocator, io, root, wp) catch return;
    defer snap.deinit();
    if (snap.content.len > max_file_bytes) return;

    var line_start: usize = 0;
    var line_index: usize = 0;
    while (line_start <= snap.content.len) {
        if (out.items.len >= max_results) break;
        const line_end = std.mem.indexOfScalar(u8, snap.content[line_start..], '\n') orelse snap.content.len - line_start;
        const line = snap.content[line_start .. line_start + line_end];
        if (containsIgnoreCase(line, lower_query)) {
            const preview = try clipLine(allocator, line, 96);
            try out.append(allocator, .{
                .path = try allocator.dupe(u8, path),
                .line = line_index,
                .preview = preview,
            });
        }
        if (line_start + line_end >= snap.content.len) break;
        line_start += line_end + 1;
        line_index += 1;
    }
}

fn shouldSkipPath(path: []const u8) bool {
    const skip_prefixes = [_][]const u8{ ".zig-cache/", "zig-out/", ".git/", "node_modules/" };
    for (skip_prefixes) |prefix| {
        if (std.mem.startsWith(u8, path, prefix)) return true;
    }
    return false;
}

fn toLower(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, text.len);
    for (text, 0..) |ch, i| out[i] = std.ascii.toLower(ch);
    return out;
}

fn containsIgnoreCase(haystack: []const u8, lower_query: []const u8) bool {
    var h_index: usize = 0;
    for (lower_query) |q| {
        while (h_index < haystack.len) : (h_index += 1) {
            if (std.ascii.toLower(haystack[h_index]) == q) {
                h_index += 1;
                break;
            }
        } else return false;
    }
    return true;
}

fn clipLine(allocator: std.mem.Allocator, line: []const u8, max_len: usize) ![]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len <= max_len) return try allocator.dupe(u8, trimmed);
    return try std.fmt.allocPrint(allocator, "{s}...", .{trimmed[0..max_len]});
}

test "search finds filename match" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var root = try workspace.WorkspaceRoot.open(io, ".");
    defer root.close(io);
    var explorer = explorer_tree.Tree.init(allocator);
    defer explorer.deinit();
    try explorer.rebuild(io, root);

    var results = try searchWorkspace(allocator, io, root, &explorer, "main.zig");
    defer results.deinit(allocator);
    try std.testing.expect(results.matches.len > 0);
}
