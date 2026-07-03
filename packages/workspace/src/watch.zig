const std = @import("std");
const path_mod = @import("path.zig");
const snapshot = @import("snapshot.zig");
const tree = @import("tree.zig");

pub const EventKind = enum {
    created,
    modified,
    deleted,
};

pub const Event = struct {
    path: []const u8,
    kind: EventKind,
};

pub const EventList = struct {
    allocator: std.mem.Allocator,
    items: []Event,

    pub fn deinit(self: *EventList) void {
        for (self.items) |event| self.allocator.free(event.path);
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    hashes: std.StringHashMap(u64),

    pub fn deinit(self: *Snapshot) void {
        var it = self.hashes.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.hashes.deinit();
        self.* = undefined;
    }

    pub fn capture(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot, root_path: []const u8) !Snapshot {
        var summary = try tree.scan(allocator, io, root, root_path);
        defer summary.deinit();

        var hashes = std.StringHashMap(u64).init(allocator);
        errdefer {
            var it = hashes.iterator();
            while (it.next()) |entry| allocator.free(entry.key_ptr.*);
            hashes.deinit();
        }

        for (summary.entries) |entry| {
            if (entry.kind != .file) continue;
            if (shouldSuppressWatchPath(entry.path)) continue;

            const wp = try path_mod.WorkspacePath.parse(entry.path);
            var snap = snapshot.FileSnapshot.read(allocator, io, root, wp) catch continue;
            defer snap.deinit();

            const owned_path = try allocator.dupe(u8, entry.path);
            errdefer allocator.free(owned_path);
            try hashes.put(owned_path, snap.hash);
        }

        return .{ .allocator = allocator, .hashes = hashes };
    }
};

pub fn shouldSuppressWatchPath(path: []const u8) bool {
    if (std.mem.startsWith(u8, path, ".forge/") or std.mem.eql(u8, path, ".forge")) return true;
    if (std.mem.startsWith(u8, path, ".zig-cache/") or std.mem.eql(u8, path, ".zig-cache")) return true;
    if (std.mem.startsWith(u8, path, "zig-out/") or std.mem.eql(u8, path, "zig-out")) return true;
    return false;
}

pub fn diff(allocator: std.mem.Allocator, before: ?*const Snapshot, after: *const Snapshot) !EventList {
    var items: std.ArrayList(Event) = .empty;
    errdefer {
        for (items.items) |event| allocator.free(event.path);
        items.deinit(allocator);
    }

    if (before) |prev| {
        var prev_it = prev.hashes.iterator();
        while (prev_it.next()) |entry| {
            const after_hash = after.hashes.get(entry.key_ptr.*);
            if (after_hash) |hash| {
                if (hash != entry.value_ptr.*) {
                    try items.append(allocator, .{
                        .path = try allocator.dupe(u8, entry.key_ptr.*),
                        .kind = .modified,
                    });
                }
            } else {
                try items.append(allocator, .{
                    .path = try allocator.dupe(u8, entry.key_ptr.*),
                    .kind = .deleted,
                });
            }
        }

        var after_it = after.hashes.iterator();
        while (after_it.next()) |entry| {
            if (!prev.hashes.contains(entry.key_ptr.*)) {
                try items.append(allocator, .{
                    .path = try allocator.dupe(u8, entry.key_ptr.*),
                    .kind = .created,
                });
            }
        }
    }

    return EventList{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) };
}

pub fn poll(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
    root_path: []const u8,
    previous: *?Snapshot,
) !EventList {
    var current = try Snapshot.capture(allocator, io, root, root_path);
    errdefer current.deinit();

    const prev_ptr: ?*const Snapshot = if (previous.*) |*snap| snap else null;
    const events = try diff(allocator, prev_ptr, &current);

    if (previous.*) |*snap| snap.deinit();
    previous.* = current;

    return events;
}

test "watch diff detects created file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = path_mod.WorkspaceRoot.init(tmp.dir);

    {
        var file = try tmp.dir.createFile(io, "a.txt", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "one");
    }

    var prev: ?Snapshot = try Snapshot.capture(allocator, io, root, ".");
    defer if (prev) |*snap| snap.deinit();

    {
        var file = try tmp.dir.createFile(io, "b.txt", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "two");
    }

    var current = try Snapshot.capture(allocator, io, root, ".");
    defer current.deinit();

    const prev_ptr: ?*const Snapshot = if (prev) |*snap| snap else null;
    var events = try diff(allocator, prev_ptr, &current);
    defer events.deinit();

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqual(EventKind.created, events.items[0].kind);
    try std.testing.expectEqualStrings("b.txt", events.items[0].path);
}
