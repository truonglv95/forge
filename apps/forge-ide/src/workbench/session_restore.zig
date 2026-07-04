const std = @import("std");
const workspace = @import("forge-workspace");

const state_path = ".forge/last_session.toml";

pub fn saveOpenTabs(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    paths: []const []const u8,
    active: usize,
) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "[session]\n");
    try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "active = {d}\n", .{active}));
    try out.appendSlice(allocator, "\n[tabs]\n");
    for (paths) |path| {
        try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "path = \"{s}\"\n", .{path}));
    }

    const wp = try workspace.WorkspacePath.parse(state_path);
    try workspace.atomic.replaceFile(io, root, wp, out.items);
}

pub fn loadOpenTabs(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
) !struct { paths: []const []const u8, active: usize } {
    const wp = workspace.WorkspacePath.parse(state_path) catch return .{ .paths = &.{}, .active = 0 };
    var snap = workspace.FileSnapshot.read(allocator, io, root, wp) catch return .{ .paths = &.{}, .active = 0 };
    defer snap.deinit();

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |path| allocator.free(path);
        list.deinit(allocator);
    }

    var active: usize = 0;
    var section: []const u8 = "";
    var lines = std.mem.splitScalar(u8, snap.content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, &std.ascii.whitespace, raw_line);
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            if (line.len < 3 or line[line.len - 1] != ']') continue;
            section = std.mem.trim(u8, &std.ascii.whitespace, line[1 .. line.len - 1]);
            continue;
        }
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, &std.ascii.whitespace, line[0..equals]);
        const value = std.mem.trim(u8, &std.ascii.whitespace, line[equals + 1 ..]);
        if (std.mem.eql(u8, section, "session") and std.mem.eql(u8, key, "active")) {
            active = std.fmt.parseInt(usize, value, 10) catch 0;
        } else if (std.mem.eql(u8, section, "tabs") and std.mem.eql(u8, key, "path")) {
            if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') continue;
            try list.append(allocator, try allocator.dupe(u8, value[1 .. value.len - 1]));
        }
    }

    return .{
        .paths = try list.toOwnedSlice(allocator),
        .active = active,
    };
}

pub fn freeLoadedTabs(allocator: std.mem.Allocator, paths: []const []const u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}
