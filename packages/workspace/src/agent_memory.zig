const std = @import("std");
const path_mod = @import("path.zig");
const atomic = @import("atomic.zig");
const global_store = @import("global_store.zig");

/// Relative sub-path within the session directory.
pub const memory_subdir = "memory/v1";
pub const memories_filename = "memory/v1/memories.jsonl";

pub const Kind = enum {
    preference,
    decision,
    fact,
    note,

    pub fn parse(text: []const u8) ?Kind {
        return std.meta.stringToEnum(Kind, text);
    }

    pub fn label(self: Kind) []const u8 {
        return @tagName(self);
    }
};

pub const Entry = struct {
    id: []const u8,
    kind: Kind,
    content: []const u8,
    tags: []const []const u8,
    created_ms: i64,
    updated_ms: i64,
    source: []const u8,
};

pub const EntryList = struct {
    allocator: std.mem.Allocator,
    items: []Entry,

    pub fn deinit(self: *EntryList) void {
        for (self.items) |entry| {
            self.allocator.free(entry.id);
            self.allocator.free(entry.content);
            for (entry.tags) |tag| self.allocator.free(tag);
            self.allocator.free(entry.tags);
            self.allocator.free(entry.source);
        }
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub const AppendInput = struct {
    kind: Kind = .note,
    content: []const u8,
    tags: []const []const u8 = &.{},
    source: []const u8 = "agent",
    timestamp_ms: i64,
};

fn memoriesAbsPath(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot) ![]u8 {
    const session_dir = try global_store.getSessionDir(allocator, io, root);
    defer allocator.free(session_dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ session_dir, memories_filename });
}

pub fn ensureLayout(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot) !void {
    const session_dir = try global_store.getSessionDir(allocator, io, root);
    defer allocator.free(session_dir);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const mem_dir = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ session_dir, memory_subdir });
    global_store.mkdirAllAbsolute(mem_dir) catch {};
}

pub fn makeMemoryId(allocator: std.mem.Allocator, timestamp_ms: i64) ![]u8 {
    return try std.fmt.allocPrint(allocator, "mem_{d}", .{timestamp_ms});
}

pub fn listEntries(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot) !EntryList {
    var items: std.ArrayList(Entry) = .empty;
    errdefer {
        for (items.items) |entry| {
            allocator.free(entry.id);
            allocator.free(entry.content);
            for (entry.tags) |tag| allocator.free(tag);
            allocator.free(entry.tags);
            allocator.free(entry.source);
        }
        items.deinit(allocator);
    }

    const abs_path = try memoriesAbsPath(allocator, io, root);
    defer allocator.free(abs_path);
    const content = global_store.readAbsoluteFile(allocator, io, abs_path) catch |err| switch (err) {
        error.FileNotFound => return EntryList{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) },
        else => return err,
    };
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const Row = struct {
            id: []const u8,
            kind: []const u8,
            content: []const u8,
            tags: ?[]const []const u8 = null,
            created_ms: i64,
            updated_ms: i64,
            source: []const u8,
        };
        var parsed = try std.json.parseFromSlice(Row, allocator, line, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        const kind = Kind.parse(parsed.value.kind) orelse .note;
        const tag_count = parsed.value.tags orelse &[_][]const u8{};
        const owned_tags = try allocator.alloc([]const u8, tag_count.len);
        errdefer {
            for (owned_tags) |tag| allocator.free(tag);
            allocator.free(owned_tags);
        }
        for (tag_count, 0..) |tag, index| {
            owned_tags[index] = try allocator.dupe(u8, tag);
        }

        try items.append(allocator, .{
            .id = try allocator.dupe(u8, parsed.value.id),
            .kind = kind,
            .content = try allocator.dupe(u8, parsed.value.content),
            .tags = owned_tags,
            .created_ms = parsed.value.created_ms,
            .updated_ms = parsed.value.updated_ms,
            .source = try allocator.dupe(u8, parsed.value.source),
        });
    }

    return EntryList{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) };
}

pub fn appendEntry(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
    input: AppendInput,
) ![]const u8 {
    try ensureLayout(allocator, io, root);

    const id = try makeMemoryId(allocator, input.timestamp_ms);
    errdefer allocator.free(id);

    var tag_values: std.ArrayList([]const u8) = .empty;
    defer tag_values.deinit(allocator);
    for (input.tags) |tag| try tag_values.append(allocator, tag);

    const line = try std.json.Stringify.valueAlloc(allocator, .{
        .id = id,
        .kind = input.kind.label(),
        .content = input.content,
        .tags = tag_values.items,
        .created_ms = input.timestamp_ms,
        .updated_ms = input.timestamp_ms,
        .source = input.source,
    }, .{});
    defer allocator.free(line);

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    const abs_path = try memoriesAbsPath(allocator, io, root);
    defer allocator.free(abs_path);

    const existing = global_store.readAbsoluteFile(allocator, io, abs_path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |bytes| {
        defer allocator.free(bytes);
        try buffer.appendSlice(allocator, bytes);
        if (bytes.len > 0 and bytes[bytes.len - 1] != '\n') try buffer.append(allocator, '\n');
    }

    try buffer.appendSlice(allocator, line);
    try buffer.append(allocator, '\n');
    try global_store.replaceAbsoluteFile(io, abs_path, buffer.items);

    return id;
}

test "agent memory append and list roundtrip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = path_mod.WorkspaceRoot.init(tmp.dir, ".");

    const id = try appendEntry(allocator, io, root, .{
        .kind = .preference,
        .content = "Prefer Zig error unions over panics in agent code",
        .tags = &[_][]const u8{ "zig", "style" },
        .source = "agent",
        .timestamp_ms = 42,
    });
    defer allocator.free(id);

    var list = try listEntries(allocator, io, root);
    defer list.deinit();

    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings(id, list.items[0].id);
    try std.testing.expect(list.items[0].kind == .preference);
    try std.testing.expectEqualStrings("Prefer Zig error unions over panics in agent code", list.items[0].content);
}
