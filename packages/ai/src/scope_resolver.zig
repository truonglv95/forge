const std = @import("std");
const workspace = @import("forge-workspace");

pub const codebase_marker = "@codebase";
pub const folder_prefix = "@folder:";
pub const docs_marker = "@docs";
pub const docs_file_prefix = "@docs:";
pub const web_marker = "@web";
pub const web_url_prefix = "@web:";

pub const ResolvedScope = struct {
    files: []const []const u8,
    include_codebase: bool,
    include_docs: bool,
    docs_files: []const []const u8,
    include_web: bool,
    web_urls: []const []const u8,
};

pub fn resolve(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    explicit_files: []const []const u8,
) !ResolvedScope {
    var files: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (files.items) |path| allocator.free(path);
        files.deinit(allocator);
    }

    var include_codebase = false;
    var include_docs = false;
    var docs_files: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (docs_files.items) |path| allocator.free(path);
        docs_files.deinit(allocator);
    }
    var include_web = false;
    var web_urls: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (web_urls.items) |url| allocator.free(url);
        web_urls.deinit(allocator);
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var seen = std.StringHashMap(void).init(arena.allocator());

    for (explicit_files) |entry| {
        if (std.mem.eql(u8, entry, codebase_marker)) {
            include_codebase = true;
            continue;
        }
        if (std.mem.eql(u8, entry, docs_marker)) {
            include_docs = true;
            continue;
        }
        if (std.mem.startsWith(u8, entry, docs_file_prefix)) {
            const doc_path = entry[docs_file_prefix.len..];
            if (seen.contains(doc_path)) continue;
            try seen.put(doc_path, {});
            try docs_files.append(allocator, try allocator.dupe(u8, doc_path));
            continue;
        }
        if (std.mem.eql(u8, entry, web_marker)) {
            include_web = true;
            continue;
        }
        if (std.mem.startsWith(u8, entry, web_url_prefix)) {
            const url = entry[web_url_prefix.len..];
            if (seen.contains(url)) continue;
            try seen.put(url, {});
            try web_urls.append(allocator, try allocator.dupe(u8, url));
            continue;
        }
        if (std.mem.startsWith(u8, entry, folder_prefix)) {
            try expandFolder(allocator, io, root, entry[folder_prefix.len..], &files, &seen);
            continue;
        }
        if (seen.contains(entry)) continue;
        try seen.put(entry, {});
        try files.append(allocator, try allocator.dupe(u8, entry));
    }

    return .{
        .files = try files.toOwnedSlice(allocator),
        .include_codebase = include_codebase,
        .include_docs = include_docs,
        .docs_files = try docs_files.toOwnedSlice(allocator),
        .include_web = include_web,
        .web_urls = try web_urls.toOwnedSlice(allocator),
    };
}

pub fn freeResolved(allocator: std.mem.Allocator, resolved: *ResolvedScope) void {
    for (resolved.files) |path| allocator.free(path);
    allocator.free(resolved.files);
    for (resolved.docs_files) |path| allocator.free(path);
    allocator.free(resolved.docs_files);
    for (resolved.web_urls) |url| allocator.free(url);
    allocator.free(resolved.web_urls);
    resolved.* = undefined;
}

pub fn displayLabel(path: []const u8, out: []u8) []const u8 {
    if (std.mem.eql(u8, path, codebase_marker)) {
        return std.fmt.bufPrint(out, "@codebase", .{}) catch "@codebase";
    }
    if (std.mem.eql(u8, path, docs_marker)) {
        return std.fmt.bufPrint(out, "@docs", .{}) catch "@docs";
    }
    if (std.mem.startsWith(u8, path, docs_file_prefix)) {
        return std.fmt.bufPrint(out, "@{s}", .{path[docs_file_prefix.len..]}) catch path;
    }
    if (std.mem.eql(u8, path, web_marker)) {
        return std.fmt.bufPrint(out, "@web", .{}) catch "@web";
    }
    if (std.mem.startsWith(u8, path, web_url_prefix)) {
        return std.fmt.bufPrint(out, "@{s}", .{path[web_url_prefix.len..]}) catch path;
    }
    if (std.mem.startsWith(u8, path, folder_prefix)) {
        return std.fmt.bufPrint(out, "@{s}", .{path[folder_prefix.len..]}) catch path;
    }
    const base = std.fs.path.basename(path);
    return std.fmt.bufPrint(out, "@{s}", .{base}) catch path;
}

fn expandFolder(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    folder: []const u8,
    out: *std.ArrayList([]const u8),
    seen: *std.StringHashMap(void),
) !void {
    var summary = try workspace.tree.scan(allocator, io, root, ".");
    defer summary.deinit();

    const prefix = if (folder.len == 0 or std.mem.eql(u8, folder, "."))
        ""
    else blk: {
        if (std.mem.endsWith(u8, folder, "/")) break :blk folder;
        var buf: [512]u8 = undefined;
        break :blk try std.fmt.bufPrint(&buf, "{s}/", .{folder});
    };

    for (summary.entries) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.startsWith(u8, entry.path, ".forge/")) continue;
        if (prefix.len > 0 and !std.mem.startsWith(u8, entry.path, prefix)) continue;
        if (seen.contains(entry.path)) continue;
        try seen.put(entry.path, {});
        try out.append(allocator, try allocator.dupe(u8, entry.path));
    }
}

test "resolve expands folder scope" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir);

    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("src/a.zig"), "a");
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("src/b.zig"), "b");
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("other.zig"), "c");

    var resolved = try resolve(allocator, io, root, &[_][]const u8{ "@folder:src", codebase_marker });
    defer freeResolved(allocator, &resolved);

    try std.testing.expect(resolved.include_codebase);
    try std.testing.expectEqual(@as(usize, 2), resolved.files.len);
}

test "resolve handles @docs marker" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir);

    var resolved = try resolve(allocator, io, root, &[_][]const u8{ docs_marker, "@docs:docs/rfc/plan.md" });
    defer freeResolved(allocator, &resolved);

    try std.testing.expect(resolved.include_docs);
    try std.testing.expectEqual(@as(usize, 1), resolved.docs_files.len);
    try std.testing.expectEqualStrings("docs/rfc/plan.md", resolved.docs_files[0]);
}

test "resolve handles @web url scope" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir);

    var resolved = try resolve(allocator, io, root, &[_][]const u8{ web_marker, "@web:https://ziglang.org/documentation/" });
    defer freeResolved(allocator, &resolved);

    try std.testing.expect(resolved.include_web);
    try std.testing.expectEqual(@as(usize, 1), resolved.web_urls.len);
    try std.testing.expectEqualStrings("https://ziglang.org/documentation/", resolved.web_urls[0]);
}
