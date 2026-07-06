const std = @import("std");
const workspace = @import("forge-workspace");

pub const max_doc_files: usize = 16;
pub const max_doc_bytes: usize = 24 * 1024;

pub fn isDocPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".md") or std.mem.endsWith(u8, path, ".markdown");
}

pub fn collectWorkspaceDocs(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    limit: usize,
) ![]const []const u8 {
    var summary = try workspace.tree.scan(allocator, io, root, ".");
    defer summary.deinit();

    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |path| allocator.free(path);
        out.deinit(allocator);
    }

    for (summary.entries) |entry| {
        if (entry.kind != .file) continue;
        if (out.items.len >= limit) break;
        if (!isDocPath(entry.path)) continue;
        const in_docs = std.mem.startsWith(u8, entry.path, "docs/");
        const root_md = std.mem.eql(u8, entry.path, "FORGE.md") or std.mem.eql(u8, entry.path, "README.md");
        if (!in_docs and !root_md) continue;
        if (std.mem.startsWith(u8, entry.path, ".forge/")) continue;
        try out.append(allocator, try allocator.dupe(u8, entry.path));
    }

    return try out.toOwnedSlice(allocator);
}

pub fn freePaths(allocator: std.mem.Allocator, paths: []const []const u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

pub fn formatDocsBlock(allocator: std.mem.Allocator, paths: []const []const u8, previews: []const []const u8) !?[]const u8 {
    if (paths.len == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "# Project documentation\n\n");

    for (paths, 0..) |path, index| {
        const preview = if (index < previews.len) previews[index] else "";
        const section = try std.fmt.allocPrint(allocator, "## {s}\n```\n{s}\n```\n\n", .{ path, preview });
        defer allocator.free(section);
        try out.appendSlice(allocator, section);
    }

    return try out.toOwnedSlice(allocator);
}

test "collectWorkspaceDocs finds docs markdown" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir);

    try tmp.dir.createDirPath(io, "docs");
    try tmp.dir.createDirPath(io, "src");
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("docs/guide.md"), "# Guide\n");
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("src/main.zig"), "main");

    const paths = try collectWorkspaceDocs(allocator, io, root, 8);
    defer freePaths(allocator, paths);
    try std.testing.expectEqual(@as(usize, 1), paths.len);
}
