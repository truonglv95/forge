const std = @import("std");
const workspace = @import("forge-workspace");

const max_entries: usize = 8;

pub fn record(allocator: std.mem.Allocator, io: std.Io, workspace_path: []const u8) !void {
    const paths = try loadAll(allocator, io);
    defer freePaths(allocator, paths);

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |path| allocator.free(path);
        list.deinit(allocator);
    }

    try list.append(allocator, try allocator.dupe(u8, workspace_path));
    for (paths) |path| {
        if (list.items.len >= max_entries) break;
        if (std.mem.eql(u8, path, workspace_path)) continue;
        try list.append(allocator, try allocator.dupe(u8, path));
    }

    try save(allocator, io, list.items);
}

pub fn loadAll(allocator: std.mem.Allocator, io: std.Io) ![]const []const u8 {
    const file_path = homeRecentPath(allocator) catch return &.{};
    defer allocator.free(file_path);

    var file = std.Io.Dir.openFileAbsolute(io, file_path, .{}) catch return &.{};
    defer file.close(io);

    const stat = file.stat(io) catch return &.{};
    const size: usize = @intCast(@min(stat.size, 64 * 1024));
    const content = try allocator.alloc(u8, size);
    errdefer allocator.free(content);
    const read_len = try file.readPositionalAll(io, content, 0);
    const slice = content[0..read_len];

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |path| allocator.free(path);
        list.deinit(allocator);
        allocator.free(content);
    }

    var lines = std.mem.splitScalar(u8, slice, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (!std.mem.startsWith(u8, line, "path = ")) continue;
        const value = std.mem.trim(u8, line["path = ".len..], " \t");
        const unquoted = parseQuoted(value) orelse value;
        if (unquoted.len == 0) continue;
        try list.append(allocator, try allocator.dupe(u8, unquoted));
    }

    allocator.free(content);
    return try list.toOwnedSlice(allocator);
}

pub fn freePaths(allocator: std.mem.Allocator, paths: []const []const u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

fn homeRecentPath(allocator: std.mem.Allocator) ![]u8 {
    return workspace.global_store.joinHome(allocator, workspace.global_store.recent_workspaces_file);
}

fn ensureHomeForgeDir(io: std.Io) !void {
    try workspace.global_store.ensureLayout(io);
}

fn save(allocator: std.mem.Allocator, io: std.Io, paths: []const []const u8) !void {
    try ensureHomeForgeDir(io);

    const file_path = try homeRecentPath(allocator);
    defer allocator.free(file_path);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "# Recent Forge workspaces\n");
    for (paths) |path| {
        const escaped = try escapeQuoted(allocator, path);
        defer allocator.free(escaped);
        try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "path = \"{s}\"\n", .{escaped}));
    }

    var file = try std.Io.Dir.createFileAbsolute(io, file_path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, out.items);
}

fn parseQuoted(value: []const u8) ?[]const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        return value[1 .. value.len - 1];
    }
    return null;
}

fn escapeQuoted(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (text) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            else => try out.append(allocator, ch),
        }
    }
    return try out.toOwnedSlice(allocator);
}

pub fn spawnIde(allocator: std.mem.Allocator, launcher: []const u8, workspace_path: []const u8) !void {
    var child = try @import("forge-util").process_spawn.spawn(allocator, &.{ launcher, workspace_path }, .{
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    child.stdin_fd = -1;
    child.stdout_fd = -1;
    child.stderr_fd = -1;
    child.pid = -1;
    child.deinit();
}
