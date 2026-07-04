const std = @import("std");
const path_mod = @import("path.zig");
const ignore = @import("ignore.zig");

pub const MtimeEntry = struct {
    path: []const u8,
    mtime: i128,
};

pub const CollectOptions = struct {
    limit: usize = 5,
    max_scan: u32 = 3000,
    exclude: []const []const u8 = &.{},
};

/// Returns recently modified workspace file paths sorted by mtime (newest first).
pub fn topByMtime(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
    options: CollectOptions,
) ![]const []const u8 {
    var entries: std.ArrayList(MtimeEntry) = .empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry.path);
        entries.deinit(allocator);
    }

    var walker = try root.dir.walk(allocator);
    defer walker.deinit();

    var scanned: u32 = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.startsWith(u8, entry.path, ".forge/")) continue;
        if (std.mem.endsWith(u8, entry.path, ".proposal.json")) continue;

        var skip = false;
        var it = std.mem.splitScalar(u8, entry.path, std.fs.path.sep);
        while (it.next()) |component| {
            if (ignore.IgnoreRules.isIgnored(component)) {
                skip = true;
                break;
            }
        }
        if (skip) continue;
        if (isExcluded(options.exclude, entry.path)) continue;

        scanned += 1;
        if (scanned > options.max_scan) break;

        var file = root.dir.openFile(io, entry.path, .{}) catch continue;
        defer file.close(io);
        const stat = file.stat(io) catch continue;
        const mtime: i128 = stat.mtime.nanoseconds;

        try entries.append(allocator, .{
            .path = try allocator.dupe(u8, entry.path),
            .mtime = mtime,
        });
    }

    std.sort.pdq(MtimeEntry, entries.items, {}, struct {
        fn less(_: void, a: MtimeEntry, b: MtimeEntry) bool {
            return a.mtime > b.mtime;
        }
    }.less);

    const take = @min(options.limit, entries.items.len);
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |path| allocator.free(path);
        out.deinit(allocator);
    }

    for (entries.items[0..take]) |entry| {
        try out.append(allocator, try allocator.dupe(u8, entry.path));
    }

    for (entries.items) |entry| allocator.free(entry.path);
    entries.deinit(allocator);

    return try out.toOwnedSlice(allocator);
}

/// Merges caller-provided paths with mtime scan, deduped, capped at `limit`.
pub fn mergeRecentPaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
    preferred: []const []const u8,
    options: CollectOptions,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |path| allocator.free(path);
        out.deinit(allocator);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var seen = std.StringHashMap(void).init(arena.allocator());

    for (preferred) |path| {
        if (path.len == 0) continue;
        if (isExcluded(options.exclude, path)) continue;
        if (seen.contains(path)) continue;
        try seen.put(path, {});
        try out.append(allocator, try allocator.dupe(u8, path));
        if (out.items.len >= options.limit) return try out.toOwnedSlice(allocator);
    }

    const scanned = try topByMtime(allocator, io, root, .{
        .limit = options.limit,
        .max_scan = options.max_scan,
        .exclude = options.exclude,
    });
    defer {
        for (scanned) |path| allocator.free(path);
        allocator.free(scanned);
    }

    for (scanned) |path| {
        if (seen.contains(path)) continue;
        try seen.put(path, {});
        try out.append(allocator, try allocator.dupe(u8, path));
        if (out.items.len >= options.limit) break;
    }

    return try out.toOwnedSlice(allocator);
}

pub fn freePaths(allocator: std.mem.Allocator, paths: []const []const u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

fn isExcluded(exclude: []const []const u8, path: []const u8) bool {
    for (exclude) |item| {
        if (std.mem.eql(u8, item, path)) return true;
    }
    return false;
}

test "topByMtime returns workspace files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = path_mod.WorkspaceRoot.init(tmp.dir);

    const atomic = @import("atomic.zig");
    try atomic.replaceFile(io, root, try path_mod.WorkspacePath.parse("sample.txt"), "sample");

    const paths = try topByMtime(allocator, io, root, .{ .limit = 2 });
    defer freePaths(allocator, paths);

    try std.testing.expect(paths.len >= 1);
    try std.testing.expectEqualStrings("sample.txt", paths[0]);
}
