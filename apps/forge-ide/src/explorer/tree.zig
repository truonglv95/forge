const std = @import("std");
const workspace = @import("forge-workspace");

pub const VisibleEntry = struct {
    path: []const u8,
    name: []const u8,
    kind: std.Io.File.Kind,
    depth: u32,
    expanded: bool,
    selected: bool,
    active: bool,
};

pub const Tree = struct {
    allocator: std.mem.Allocator,
    all_paths: []CachedPath,
    entries: []Entry,
    expanded_paths: std.StringHashMap(void),
    selected_path: ?[]const u8 = null,

    const CachedPath = struct {
        path: []const u8,
        kind: std.Io.File.Kind,
        depth: u32,
    };

    const Entry = struct {
        path: []const u8,
        name: []const u8,
        kind: std.Io.File.Kind,
        depth: u32,
    };

    pub fn init(allocator: std.mem.Allocator) Tree {
        return .{
            .allocator = allocator,
            .all_paths = &.{},
            .entries = &.{},
            .expanded_paths = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *Tree) void {
        self.freeAllPaths();
        self.freeEntries();
        if (self.selected_path) |path| self.allocator.free(path);
        self.expanded_paths.deinit();
    }

    fn freeAllPaths(self: *Tree) void {
        for (self.all_paths) |entry| self.allocator.free(entry.path);
        self.allocator.free(self.all_paths);
        self.all_paths = &.{};
    }

    fn freeEntries(self: *Tree) void {
        for (self.entries) |entry| self.allocator.free(entry.path);
        self.allocator.free(self.entries);
        self.entries = &.{};
    }

    pub fn rebuild(self: *Tree, io: std.Io, root: workspace.WorkspaceRoot) !void {
        try self.rescan(io, root);
    }

    pub fn rescan(self: *Tree, io: std.Io, root: workspace.WorkspaceRoot) !void {
        var summary = try workspace.tree.scan(self.allocator, io, root, ".");
        defer summary.deinit();

        var paths = std.StringHashMap(std.Io.File.Kind).init(self.allocator);
        defer {
            var it = paths.keyIterator();
            while (it.next()) |key| self.allocator.free(key.*);
            paths.deinit();
        }

        for (summary.entries) |entry| {
            const owned = try self.allocator.dupe(u8, entry.path);
            try paths.put(owned, entry.kind);
            try self.ensureParentDirs(&paths, entry.path);
        }

        var sorted: std.ArrayList([]const u8) = .empty;
        defer sorted.deinit(self.allocator);
        var it = paths.keyIterator();
        while (it.next()) |key| try sorted.append(self.allocator, key.*);

        std.sort.block([]const u8, sorted.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);

        self.freeAllPaths();

        var cached: std.ArrayList(CachedPath) = .empty;
        errdefer {
            for (cached.items) |entry| self.allocator.free(entry.path);
            cached.deinit(self.allocator);
        }

        for (sorted.items) |path| {
            const kind = paths.get(path).?;
            const owned_path = try self.allocator.dupe(u8, path);
            try cached.append(self.allocator, .{
                .path = owned_path,
                .kind = kind,
                .depth = pathDepth(path),
            });
        }

        self.all_paths = try cached.toOwnedSlice(self.allocator);
        try self.refreshVisible();
    }

    pub fn refreshVisible(self: *Tree) !void {
        self.freeEntries();

        var built: std.ArrayList(Entry) = .empty;
        errdefer {
            for (built.items) |entry| self.allocator.free(entry.path);
            built.deinit(self.allocator);
        }

        for (self.all_paths) |cached| {
            if (!self.isPathVisible(cached.path)) continue;
            const owned_path = try self.allocator.dupe(u8, cached.path);
            try built.append(self.allocator, .{
                .path = owned_path,
                .name = basename(owned_path),
                .kind = cached.kind,
                .depth = cached.depth,
            });
        }

        self.entries = try built.toOwnedSlice(self.allocator);
    }

    fn ensureParentDirs(self: *Tree, paths: *std.StringHashMap(std.Io.File.Kind), path: []const u8) !void {
        var parts = std.mem.splitScalar(u8, path, '/');
        var built: std.ArrayList(u8) = .empty;
        defer built.deinit(self.allocator);

        while (parts.next()) |part| {
            if (built.items.len > 0) try built.append(self.allocator, '/');
            try built.appendSlice(self.allocator, part);
            const parent_path = try self.allocator.dupe(u8, built.items);
            const gop = try paths.getOrPut(parent_path);
            if (!gop.found_existing) {
                gop.value_ptr.* = .directory;
            } else {
                self.allocator.free(parent_path);
            }
        }
    }

    fn isPathVisible(self: *const Tree, path: []const u8) bool {
        var parent = std.fs.path.dirname(path);
        while (parent) |segment| {
            if (segment.len == 0) break;
            if (self.expanded_paths.get(segment) == null) return false;
            parent = std.fs.path.dirname(segment);
        }
        return true;
    }

    pub fn toggleExpand(self: *Tree, path: []const u8) !void {
        if (self.expanded_paths.fetchRemove(path)) |entry| {
            self.allocator.free(entry.key);
        } else {
            try self.expanded_paths.put(try self.allocator.dupe(u8, path), {});
        }
        try self.refreshVisible();
    }

    pub fn select(self: *Tree, path: []const u8) !void {
        if (self.selected_path) |prev| self.allocator.free(prev);
        self.selected_path = try self.allocator.dupe(u8, path);
    }

    pub fn selectedOrRoot(self: *const Tree) []const u8 {
        return self.selected_path orelse "";
    }

    pub fn visibleRows(self: *const Tree, active_path: ?[]const u8, out: *std.ArrayList(VisibleEntry)) !void {
        for (self.entries) |entry| {
            const selected = if (self.selected_path) |sel| std.mem.eql(u8, sel, entry.path) else false;
            const active = if (active_path) |active| std.mem.eql(u8, active, entry.path) else false;
            const expanded = entry.kind == .directory and self.expanded_paths.contains(entry.path);
            try out.append(self.allocator, .{
                .path = entry.path,
                .name = entry.name,
                .kind = entry.kind,
                .depth = entry.depth,
                .expanded = expanded,
                .selected = selected,
                .active = active,
            });
        }
    }

    pub fn hitTestRow(self: *const Tree, row_index: usize) ?[]const u8 {
        if (row_index >= self.entries.len) return null;
        return self.entries[row_index].path;
    }
};

fn pathDepth(path: []const u8) u32 {
    if (path.len == 0) return 0;
    return @intCast(std.mem.count(u8, path, "/"));
}

fn basename(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

test "tree hides nested entries when parent collapsed" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src");
    var file = try tmp.dir.createFile(io, "src/main.zig", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "pub fn main() void {}");

    const root = workspace.WorkspaceRoot.init(tmp.dir);
    var tree = Tree.init(allocator);
    defer tree.deinit();

    try tree.rebuild(io, root);

    var rows: std.ArrayList(VisibleEntry) = .empty;
    defer rows.deinit(allocator);
    try tree.visibleRows(null, &rows);

    try std.testing.expect(rows.items.len >= 1);
    const has_nested = for (rows.items) |row| {
        if (std.mem.eql(u8, row.path, "src/main.zig")) break true;
    } else false;
    try std.testing.expect(!has_nested);

    try tree.toggleExpand("src");
    rows.clearRetainingCapacity();
    try tree.visibleRows(null, &rows);

    const has_file = for (rows.items) |row| {
        if (std.mem.eql(u8, row.path, "src/main.zig")) break true;
    } else false;
    try std.testing.expect(has_file);

    for (rows.items) |row| {
        try std.testing.expect(row.name.ptr >= row.path.ptr);
        try std.testing.expect(row.name.ptr + row.name.len <= row.path.ptr + row.path.len);
    }
}
