const std = @import("std");
const workspace = @import("forge-workspace");

pub const OpsError = error{
    InvalidName,
    PathEscape,
    NotEmpty,
    OutOfMemory,
} || workspace.WorkspacePath.ValidationError || std.Io.File.OpenError || std.Io.File.WriteError;

fn joinPath(allocator: std.mem.Allocator, parent: []const u8, name: []const u8) ![]const u8 {
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null or std.mem.eql(u8, name, "..")) {
        return error.InvalidName;
    }
    if (parent.len == 0) return allocator.dupe(u8, name);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, name });
}

pub fn createFileAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    parent_path: []const u8,
    name: []const u8,
) ![]const u8 {
    const rel = try joinPath(allocator, parent_path, name);
    errdefer allocator.free(rel);
    const wp = try workspace.WorkspacePath.parse(rel);
    try workspace.atomic.createFile(io, root, wp, "");
    return rel;
}

pub fn createFolder(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    parent_path: []const u8,
    name: []const u8,
) ![]const u8 {
    const rel = try joinPath(allocator, parent_path, name);
    errdefer allocator.free(rel);
    _ = try workspace.WorkspacePath.parse(rel);
    try workspace.atomic.createDirPath(io, root, rel);
    return rel;
}

pub fn deleteEntry(
    io: std.Io,
    root: workspace.WorkspaceRoot,
    path: []const u8,
    kind: std.Io.File.Kind,
) !void {
    const wp = try workspace.WorkspacePath.parse(path);
    switch (kind) {
        .file => try workspace.atomic.deleteFile(io, root, wp),
        .directory => try root.dir.deleteDir(io, path),
        else => {},
    }
}

pub fn renameEntry(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    path: []const u8,
    new_name: []const u8,
) ![]const u8 {
    const parent = std.fs.path.dirname(path) orelse "";
    const dest = try joinPath(allocator, parent, new_name);
    errdefer allocator.free(dest);
    _ = try workspace.WorkspacePath.parse(path);
    _ = try workspace.WorkspacePath.parse(dest);
    try std.Io.Dir.rename(root.dir, path, root.dir, dest, io);
    return dest;
}

test "create file under parent path" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();

    const root = workspace.WorkspaceRoot.init(tmp.dir);
    const created = try createFileAlloc(allocator, io, root, "src", "new.txt");
    defer allocator.free(created);

    try std.testing.expectEqualStrings("src/new.txt", created);
    var snap = try workspace.FileSnapshot.read(allocator, io, root, try workspace.WorkspacePath.parse(created));
    defer snap.deinit();
    try std.testing.expectEqual(@as(usize, 0), snap.content.len);
}
