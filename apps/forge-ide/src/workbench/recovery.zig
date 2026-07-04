const std = @import("std");
const workspace = @import("forge-workspace");
const editor = @import("forge-editor");

const path_prefix = "FORGE_RECOVERY_PATH=";

pub fn snapshotDirtyDocs(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    tabs: *const editor.TabGroup,
) !void {
    try workspace.atomic.createDirPath(io, root, ".forge");
    try workspace.atomic.createDirPath(io, root, ".forge/recovery");

    for (tabs.tabs.items) |*doc| {
        if (!doc.isDirty()) continue;
        const content = try doc.buffer.content();
        defer doc.buffer.allocator.free(content);

        const header = try std.fmt.allocPrint(allocator, "{s}{s}\n", .{ path_prefix, doc.path });
        defer allocator.free(header);
        const payload = try std.mem.concat(allocator, u8, &.{ header, content });
        defer allocator.free(payload);

        var safe_path: std.ArrayList(u8) = .empty;
        defer safe_path.deinit(allocator);
        for (doc.path) |c| {
            const out = if (c == '/') '_' else c;
            try safe_path.append(allocator, out);
        }
        const rel = try std.fmt.allocPrint(allocator, ".forge/recovery/{s}.snap", .{safe_path.items});
        defer allocator.free(rel);

        const wp = try workspace.WorkspacePath.parse(rel);
        try workspace.atomic.replaceFile(io, root, wp, payload);
    }
}

pub fn listRecoveryFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
) ![]const []const u8 {
    var summary = try workspace.tree.scan(allocator, io, root, ".forge/recovery");
    defer summary.deinit();

    var paths: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }

    for (summary.entries) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".snap")) continue;
        try paths.append(allocator, try allocator.dupe(u8, entry.path));
    }
    return try paths.toOwnedSlice(allocator);
}

pub fn parseSnapshotPayload(payload: []const u8) struct { path: []const u8, content: []const u8 } {
    if (std.mem.startsWith(u8, payload, path_prefix)) {
        const line_end = std.mem.indexOfScalar(u8, payload, '\n') orelse payload.len;
        const path = payload[path_prefix.len..line_end];
        const content_start = if (line_end + 1 <= payload.len) line_end + 1 else payload.len;
        return .{ .path = path, .content = payload[content_start..] };
    }
    return .{ .path = "", .content = payload };
}

pub fn readSnapshot(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    snap_rel_path: []const u8,
) !struct { path: []const u8, content: []const u8 } {
    const wp = try workspace.WorkspacePath.parse(snap_rel_path);
    var snap = try workspace.FileSnapshot.read(allocator, io, root, wp);
    defer snap.deinit();

    const parsed = parseSnapshotPayload(snap.content);
    const path = if (parsed.path.len > 0)
        try allocator.dupe(u8, parsed.path)
    else
        try inferPathFromSnapName(allocator, snap_rel_path);
    const content = try allocator.dupe(u8, parsed.content);
    return .{ .path = path, .content = content };
}

fn inferPathFromSnapName(allocator: std.mem.Allocator, snap_rel_path: []const u8) ![]const u8 {
    const base = std.fs.path.basename(snap_rel_path);
    const stem = if (std.mem.endsWith(u8, base, ".snap"))
        base[0 .. base.len - ".snap".len]
    else
        base;
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(allocator);
    for (stem) |c| {
        try path.append(allocator, if (c == '_') '/' else c);
    }
    return try path.toOwnedSlice(allocator);
}

pub fn deleteSnapshot(
    io: std.Io,
    root: workspace.WorkspaceRoot,
    snap_rel_path: []const u8,
) !void {
    const wp = try workspace.WorkspacePath.parse(snap_rel_path);
    try workspace.atomic.deleteFile(io, root, wp);
}

pub fn countRecoveryFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
) !usize {
    const paths = try listRecoveryFiles(allocator, io, root);
    defer {
        for (paths) |path| allocator.free(path);
        allocator.free(paths);
    }
    return paths.len;
}

test "recovery writes snapshot for dirty doc" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();

    var tabs = editor.TabGroup.init(allocator);
    defer tabs.deinit();

    const doc = try tabs.openOrActivate("sample.txt");
    try doc.buffer.loadFromSlice("dirty content");
    try doc.buffer.insertString("!");

    const root = workspace.WorkspaceRoot.init(tmp.dir);
    try snapshotDirtyDocs(allocator, io, root, &tabs);

    const paths = try listRecoveryFiles(allocator, io, root);
    defer {
        for (paths) |path| allocator.free(path);
        allocator.free(paths);
    }
    try std.testing.expect(paths.len >= 1);

    const snap = try readSnapshot(allocator, io, root, paths[0]);
    defer allocator.free(snap.path);
    defer allocator.free(snap.content);
    try std.testing.expectEqualStrings("sample.txt", snap.path);
    try std.testing.expectEqualStrings("dirty content!", snap.content);
}

test "parseSnapshotPayload reads header" {
    const parsed = parseSnapshotPayload("FORGE_RECOVERY_PATH=src/main.zig\nhello");
    try std.testing.expectEqualStrings("src/main.zig", parsed.path);
    try std.testing.expectEqualStrings("hello", parsed.content);
}
