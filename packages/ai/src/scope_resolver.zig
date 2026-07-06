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
    const arena_alloc = arena.allocator();
    var seen = std.StringHashMap(void).init(arena_alloc);

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
            try markScopeSeen(arena_alloc, &seen, doc_path);
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
            try markScopeSeen(arena_alloc, &seen, url);
            try web_urls.append(allocator, try allocator.dupe(u8, url));
            continue;
        }
        if (std.mem.startsWith(u8, entry, folder_prefix)) {
            try expandFolder(allocator, io, root, entry[folder_prefix.len..], arena_alloc, &files, &seen);
            continue;
        }
        if (seen.contains(entry)) continue;
        try markScopeSeen(arena_alloc, &seen, entry);
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

fn copyLabel(out: []u8, label: []const u8) []const u8 {
    if (out.len == 0) return "";
    const n = @min(label.len, out.len - 1);
    @memcpy(out[0..n], label[0..n]);
    out[n] = 0;
    return out[0..n];
}

fn formatAtSuffix(out: []u8, suffix: []const u8) []const u8 {
    if (out.len == 0) return "";
    if (std.fmt.bufPrint(out, "@{s}", .{suffix})) |written| {
        return written;
    } else |_| {}
    const max_suffix = out.len -| 2;
    out[0] = '@';
    const n = @min(suffix.len, max_suffix);
    if (n > 0) @memcpy(out[1..][0..n], suffix[0..n]);
    out[1 + n] = 0;
    return out[0 .. 1 + n];
}

pub fn displayLabel(path: []const u8, out: []u8) []const u8 {
    if (std.mem.eql(u8, path, codebase_marker)) return copyLabel(out, "@codebase");
    if (std.mem.eql(u8, path, docs_marker)) return copyLabel(out, "@docs");
    if (std.mem.startsWith(u8, path, docs_file_prefix)) {
        return formatAtSuffix(out, path[docs_file_prefix.len..]);
    }
    if (std.mem.eql(u8, path, web_marker)) return copyLabel(out, "@web");
    if (std.mem.startsWith(u8, path, web_url_prefix)) {
        return formatAtSuffix(out, path[web_url_prefix.len..]);
    }
    if (std.mem.startsWith(u8, path, folder_prefix)) {
        return formatAtSuffix(out, path[folder_prefix.len..]);
    }
    const base = std.fs.path.basename(path);
    if (base.len > 0) return formatAtSuffix(out, base);
    return formatAtSuffix(out, path);
}

fn markScopeSeen(arena_alloc: std.mem.Allocator, seen: *std.StringHashMap(void), path: []const u8) !void {
    const owned = try arena_alloc.dupe(u8, path);
    const gop = try seen.getOrPut(owned);
    if (gop.found_existing) {}
}

fn expandFolder(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    folder: []const u8,
    arena_alloc: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    seen: *std.StringHashMap(void),
) !void {
    var summary = try workspace.tree.scan(allocator, io, root, ".");
    defer summary.deinit();

    const prefix_owned = if (folder.len == 0 or std.mem.eql(u8, folder, "."))
        try arena_alloc.dupe(u8, "")
    else if (std.mem.endsWith(u8, folder, "/"))
        try arena_alloc.dupe(u8, folder)
    else
        try std.fmt.allocPrint(arena_alloc, "{s}/", .{folder});
    const prefix = prefix_owned;

    for (summary.entries) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.startsWith(u8, entry.path, ".forge/")) continue;
        if (prefix.len > 0 and !std.mem.startsWith(u8, entry.path, prefix)) continue;
        if (seen.contains(entry.path)) continue;
        try markScopeSeen(arena_alloc, seen, entry.path);
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

test "resolve folder scope then explicit file reuses seen safely" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir);

    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("src/a.zig"), "a");
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("src/b.zig"), "b");

    var resolved = try resolve(allocator, io, root, &[_][]const u8{ "@folder:src", "src/a.zig" });
    defer freeResolved(allocator, &resolved);

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

test "displayLabel truncates to output buffer" {
    var out: [16]u8 = undefined;
    var path_buf: [128]u8 = undefined;
    @memcpy(path_buf[0..folder_prefix.len], folder_prefix);
    const suffix = "packages/ai/src/context_loader.zig";
    @memcpy(path_buf[folder_prefix.len..][0..suffix.len], suffix);
    const path = path_buf[0 .. folder_prefix.len + suffix.len];

    const label = displayLabel(path, &out);
    try std.testing.expect(label.len < out.len);
    try std.testing.expect(label[0] == '@');
}
