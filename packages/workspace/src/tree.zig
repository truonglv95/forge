const std = @import("std");
const path_mod = @import("path.zig");
const ignore = @import("ignore.zig");

pub const TreeEntry = struct {
    path: []const u8,
    kind: std.Io.File.Kind,
};

pub const ScanSummary = struct {
    allocator: std.mem.Allocator,
    root_path: []const u8,
    file_count: u32,
    dir_count: u32,
    entries: []TreeEntry,

    pub fn deinit(self: *ScanSummary) void {
        for (self.entries) |entry| self.allocator.free(entry.path);
        self.allocator.free(self.entries);
        self.allocator.free(self.root_path);
        self.* = undefined;
    }
};

pub fn scan(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
    root_path: []const u8,
) !ScanSummary {
    var entries: std.ArrayList(TreeEntry) = .empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry.path);
        entries.deinit(allocator);
    }

    var file_count: u32 = 0;
    var dir_count: u32 = 0;

    var walker = try root.dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.depth() == 1) {
            if (ignore.IgnoreRules.isIgnored(entry.basename)) continue;
        } else {
            var skip = false;
            var it = std.mem.splitScalar(u8, entry.path, std.fs.path.sep);
            while (it.next()) |component| {
                if (ignore.IgnoreRules.isIgnored(component)) {
                    skip = true;
                    break;
                }
            }
            if (skip) continue;
        }

        const owned_path = try allocator.dupe(u8, entry.path);
        try entries.append(allocator, .{ .path = owned_path, .kind = entry.kind });

        switch (entry.kind) {
            .file => file_count += 1,
            .directory => dir_count += 1,
            else => {},
        }

        if (file_count + dir_count >= ignore.Limits.max_entries) break;
    }

    std.sort.block(TreeEntry, entries.items, {}, struct {
        fn less(_: void, a: TreeEntry, b: TreeEntry) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.less);

    return ScanSummary{
        .allocator = allocator,
        .root_path = try allocator.dupe(u8, root_path),
        .file_count = file_count,
        .dir_count = dir_count,
        .entries = try entries.toOwnedSlice(allocator),
    };
}
