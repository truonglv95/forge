//! @mention resolver — resolves parsed mentions to context content.
//!
//! Phase 2 implementation of RFC-0017 mention resolution:
//! - @file: read file content via workspace snapshot
//! - @symbol: stub (LSP workspace_symbol — needs LSP controller, deferred)
//! - @web: stub (fetch_url tool — needs provider context, deferred)
//! - @docs: stub (indexed docs — needs RAG index, deferred)
//! - @spec: read spec file from specs/ directory
//! - @recent: stub (needs recent files store, deferred)
//! - @git:diff: run `git diff --stat` via subprocess
//! - @git:status: run `git status --porcelain` via subprocess

const std = @import("std");
const workspace = @import("forge-workspace");
const process_spawn = @import("forge-util").process_spawn;
const mention_parser = @import("mention_parser.zig");

pub const ResolveError = error{
    OutOfMemory,
    FileNotFound,
    ReadFailed,
    SubprocessFailed,
    InvalidPath,
};

pub const ResolvedMention = struct {
    kind: []const u8, // "file", "symbol", "web", "spec", "recent", "git_diff", "git_status"
    label: []const u8, // display label e.g. "src/main.zig" or "git diff"
    content: []const u8, // resolved content
    bytes: usize,
    error_message: ?[]const u8 = null,

    pub fn deinit(self: *ResolvedMention, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.content);
        if (self.error_message) |m| allocator.free(m);
    }
};

/// Resolve all mentions to context content. Returns owned slice.
/// Caller must deinit each ResolvedMention and free the slice.
pub fn resolveAll(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: ?workspace.WorkspaceRoot,
    mentions: []const mention_parser.Mention,
) ![]ResolvedMention {
    var results: std.ArrayList(ResolvedMention) = .empty;
    defer results.deinit(allocator);

    for (mentions) |m| {
        const resolved = resolveOne(allocator, io, root, m) catch |err| {
            // On error, add an error entry instead of skipping.
            const label = labelForMention(allocator, m) catch try allocator.dupe(u8, "unknown");
            const err_msg = std.fmt.allocPrint(allocator, "failed to resolve: {}", .{err}) catch try allocator.dupe(u8, "resolve failed");
            try results.append(allocator, .{
                .kind = kindForMention(m),
                .label = label,
                .content = try allocator.dupe(u8, ""),
                .bytes = 0,
                .error_message = err_msg,
            });
            continue;
        };
        try results.append(allocator, resolved);
    }

    return results.toOwnedSlice(allocator);
}

fn resolveOne(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: ?workspace.WorkspaceRoot,
    mention: mention_parser.Mention,
) !ResolvedMention {
    switch (mention) {
        .file => |f| return resolveFile(allocator, io, root, f.path, f.line_range),
        .symbol => |s| return resolveSymbol(allocator, io, root, s),
        .web => |w| return resolveWeb(allocator, io, w),
        .docs => |d| return resolveDocs(allocator, io, root, d),
        .spec => |sp| return resolveSpec(allocator, io, root, sp),
        .recent => return resolveRecent(allocator),
        .git_diff => return resolveGitDiff(allocator, io, root),
        .git_status => return resolveGitStatus(allocator, io, root),
    }
}

fn resolveFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: ?workspace.WorkspaceRoot,
    path: []const u8,
    line_range: ?mention_parser.LineRange,
) !ResolvedMention {
    const label = try std.fmt.allocPrint(allocator, "@file:{s}", .{path});

    if (root == null) {
        return .{
            .kind = "file",
            .label = label,
            .content = try allocator.dupe(u8, ""),
            .bytes = 0,
            .error_message = try allocator.dupe(u8, "no workspace open"),
        };
    }

    const rel_path = workspace.WorkspacePath.parse(path) catch {
        return .{
            .kind = "file",
            .label = label,
            .content = try allocator.dupe(u8, ""),
            .bytes = 0,
            .error_message = try std.fmt.allocPrint(allocator, "invalid path: {s}", .{path}),
        };
    };

    var snapshot = workspace.snapshot.FileSnapshot.read(allocator, io, root.?, rel_path) catch |err| {
        return .{
            .kind = "file",
            .label = label,
            .content = try allocator.dupe(u8, ""),
            .bytes = 0,
            .error_message = try std.fmt.allocPrint(allocator, "read failed: {}", .{err}),
        };
    };
    defer snapshot.deinit();

    // If line range specified, extract just those lines.
    if (line_range) |range| {
        const sliced = try sliceLines(allocator, snapshot.content, range.start, range.end);
        return .{
            .kind = "file",
            .label = label,
            .content = sliced,
            .bytes = sliced.len,
        };
    }

    const content = try allocator.dupe(u8, snapshot.content);
    return .{
        .kind = "file",
        .label = label,
        .content = content,
        .bytes = content.len,
    };
}

fn sliceLines(allocator: std.mem.Allocator, content: []const u8, start: u32, end: u32) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    var current_line: u32 = 1;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        if (current_line >= start and current_line <= end) {
            try buf.appendSlice(allocator, line);
            try buf.append(allocator, '\n');
        }
        if (current_line > end) break;
        current_line += 1;
    }

    return buf.toOwnedSlice(allocator);
}

fn resolveSymbol(allocator: std.mem.Allocator, io: std.Io, root: ?workspace.WorkspaceRoot, name: []const u8) !ResolvedMention {
    const label = try std.fmt.allocPrint(allocator, "@symbol:{s}", .{name});

    if (root == null) {
        return .{
            .kind = "symbol",
            .label = label,
            .content = try allocator.dupe(u8, ""),
            .bytes = 0,
            .error_message = try allocator.dupe(u8, "no workspace open"),
        };
    }

    // Fallback: text search for the symbol name in workspace files.
    // Full LSP workspace_symbol resolution requires an active LSP session
    // (Phase 4 when LSP controller is wired into chat).
    const search_results = searchWorkspaceForSymbol(allocator, io, root.?, name) catch |err| {
        return .{
            .kind = "symbol",
            .label = label,
            .content = try allocator.dupe(u8, ""),
            .bytes = 0,
            .error_message = try std.fmt.allocPrint(allocator, "search failed: {}", .{err}),
        };
    };
    defer allocator.free(search_results);

    if (search_results.len == 0) {
        return .{
            .kind = "symbol",
            .label = label,
            .content = try allocator.dupe(u8, ""),
            .bytes = 0,
            .error_message = try std.fmt.allocPrint(allocator, "symbol '{s}' not found in workspace (LSP integration pending)", .{name}),
        };
    }

    return .{
        .kind = "symbol",
        .label = label,
        .content = search_results,
        .bytes = search_results.len,
    };
}

fn searchWorkspaceForSymbol(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot, name: []const u8) ![]u8 {
    _ = io;
    // Use grep-like search via process_spawn.
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "grep");
    try argv.append(allocator, "-rn");
    try argv.append(allocator, "--include=*.zig");
    try argv.append(allocator, "--include=*.py");
    try argv.append(allocator, "--include=*.ts");
    try argv.append(allocator, "--include=*.rs");
    try argv.append(allocator, "--include=*.go");
    try argv.append(allocator, "--include=*.js");
    try argv.append(allocator, "-l");
    try argv.append(allocator, name);
    try argv.append(allocator, ".");

    const spawn_opts = process_spawn.SpawnOptions{
        .cwd = root.path,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    };

    const result = process_spawn.runCapture(allocator, argv.items, spawn_opts) catch return error.SubprocessFailed;
    if (result.exit_code > 1) {
        allocator.free(result.output);
        return error.SubprocessFailed;
    }

    // Limit to first 2000 bytes to keep context manageable.
    const trimmed = if (result.output.len > 2000) result.output[0..2000] else result.output;
    const dup = try allocator.dupe(u8, trimmed);
    allocator.free(result.output);
    return dup;
}

fn resolveWeb(allocator: std.mem.Allocator, io: std.Io, query: []const u8) !ResolvedMention {
    const label = try std.fmt.allocPrint(allocator, "@web:{s}", .{query});
    _ = io;

    // If query looks like a URL (starts with http:// or https://), fetch it directly.
    if (std.mem.startsWith(u8, query, "http://") or std.mem.startsWith(u8, query, "https://")) {
        const content = fetchUrl(allocator, query) catch |err| {
            return .{
                .kind = "web",
                .label = label,
                .content = try allocator.dupe(u8, ""),
                .bytes = 0,
                .error_message = try std.fmt.allocPrint(allocator, "fetch failed: {}", .{err}),
            };
        };
        return .{
            .kind = "web",
            .label = label,
            .content = content,
            .bytes = content.len,
        };
    }

    // Otherwise, treat as a search query — return a stub pointing to search.
    return .{
        .kind = "web",
        .label = label,
        .content = try allocator.dupe(u8, ""),
        .bytes = 0,
        .error_message = try std.fmt.allocPrint(allocator, "web search for '{s}' requires a search API (pass a URL to fetch directly)", .{query}),
    };
}

fn fetchUrl(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    var client = std.http.Client{ .allocator = allocator, .io = undefined };
    defer client.deinit();

    var response_alloc = std.Io.Writer.Allocating.init(allocator);
    defer response_alloc.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &response_alloc.writer,
    }) catch return error.NetworkError;

    if (result.status != .ok) return error.HttpError;

    const body = response_alloc.written();
    // Limit to 8KB for context.
    const trimmed = if (body.len > 8192) body[0..8192] else body;
    return allocator.dupe(u8, trimmed);
}

fn resolveDocs(allocator: std.mem.Allocator, io: std.Io, root: ?workspace.WorkspaceRoot, library: []const u8) !ResolvedMention {
    const label = try std.fmt.allocPrint(allocator, "@docs:{s}", .{library});

    if (root == null) {
        return .{
            .kind = "docs",
            .label = label,
            .content = try allocator.dupe(u8, ""),
            .bytes = 0,
            .error_message = try allocator.dupe(u8, "no workspace open"),
        };
    }

    // Fallback: search docs/ directory in workspace for the library name.
    const docs_path_str = std.fmt.allocPrint(allocator, "docs/{s}.md", .{library}) catch {
        return .{
            .kind = "docs",
            .label = label,
            .content = try allocator.dupe(u8, ""),
            .bytes = 0,
            .error_message = try allocator.dupe(u8, "out of memory"),
        };
    };
    defer allocator.free(docs_path_str);

    const rel_path = workspace.WorkspacePath.parse(docs_path_str) catch {
        return .{
            .kind = "docs",
            .label = label,
            .content = try allocator.dupe(u8, ""),
            .bytes = 0,
            .error_message = try std.fmt.allocPrint(allocator, "invalid docs path for '{s}'", .{library}),
        };
    };

    var snapshot = workspace.snapshot.FileSnapshot.read(allocator, io, root.?, rel_path) catch {
        return .{
            .kind = "docs",
            .label = label,
            .content = try allocator.dupe(u8, ""),
            .bytes = 0,
            .error_message = try std.fmt.allocPrint(allocator, "docs '{s}' not found (looked for docs/{s}.md)", .{ library, library }),
        };
    };
    defer snapshot.deinit();

    const content = try allocator.dupe(u8, snapshot.content);
    return .{
        .kind = "docs",
        .label = label,
        .content = content,
        .bytes = content.len,
    };
}

fn resolveSpec(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: ?workspace.WorkspaceRoot,
    spec_id: []const u8,
) !ResolvedMention {
    const label = try std.fmt.allocPrint(allocator, "@spec:{s}", .{spec_id});

    if (root == null) {
        return .{
            .kind = "spec",
            .label = label,
            .content = try allocator.dupe(u8, ""),
            .bytes = 0,
            .error_message = try allocator.dupe(u8, "no workspace open"),
        };
    }

    // Try specs/features/<id>.md, specs/bugfixes/<id>.md, etc.
    const subdirs = [_][]const u8{ "features", "bugfixes", "refactors", "spikes" };
    for (subdirs) |subdir| {
        const rel_path_str = std.fmt.allocPrint(allocator, "specs/{s}/{s}.md", .{ subdir, spec_id }) catch continue;
        defer allocator.free(rel_path_str);
        const rel_path = workspace.WorkspacePath.parse(rel_path_str) catch continue;
        var snapshot = workspace.snapshot.FileSnapshot.read(allocator, io, root.?, rel_path) catch continue;
        defer snapshot.deinit();
        const content = try allocator.dupe(u8, snapshot.content);
        return .{
            .kind = "spec",
            .label = label,
            .content = content,
            .bytes = content.len,
        };
    }

    return .{
        .kind = "spec",
        .label = label,
        .content = try allocator.dupe(u8, ""),
        .bytes = 0,
        .error_message = try std.fmt.allocPrint(allocator, "spec '{s}' not found in specs/", .{spec_id}),
    };
}

fn resolveRecent(allocator: std.mem.Allocator) !ResolvedMention {
    return .{
        .kind = "recent",
        .label = try allocator.dupe(u8, "@recent"),
        .content = try allocator.dupe(u8, ""),
        .bytes = 0,
        .error_message = try allocator.dupe(u8, "recent files resolution needs recent files store (Phase 3)"),
    };
}

fn resolveGitDiff(allocator: std.mem.Allocator, io: std.Io, root: ?workspace.WorkspaceRoot) !ResolvedMention {
    const label = try allocator.dupe(u8, "@git:diff");
    if (root == null) {
        return .{
            .kind = "git_diff",
            .label = label,
            .content = try allocator.dupe(u8, ""),
            .bytes = 0,
            .error_message = try allocator.dupe(u8, "no workspace open"),
        };
    }

    // Run `git diff --stat` in the workspace root.
    const output = runGitCommand(allocator, io, root.?, &.{ "diff", "--stat" }) catch |err| {
        return .{
            .kind = "git_diff",
            .label = label,
            .content = try allocator.dupe(u8, ""),
            .bytes = 0,
            .error_message = try std.fmt.allocPrint(allocator, "git diff failed: {}", .{err}),
        };
    };

    return .{
        .kind = "git_diff",
        .label = label,
        .content = output,
        .bytes = output.len,
    };
}

fn resolveGitStatus(allocator: std.mem.Allocator, io: std.Io, root: ?workspace.WorkspaceRoot) !ResolvedMention {
    const label = try allocator.dupe(u8, "@git:status");
    if (root == null) {
        return .{
            .kind = "git_status",
            .label = label,
            .content = try allocator.dupe(u8, ""),
            .bytes = 0,
            .error_message = try allocator.dupe(u8, "no workspace open"),
        };
    }

    const output = runGitCommand(allocator, io, root.?, &.{ "status", "--porcelain" }) catch |err| {
        return .{
            .kind = "git_status",
            .label = label,
            .content = try allocator.dupe(u8, ""),
            .bytes = 0,
            .error_message = try std.fmt.allocPrint(allocator, "git status failed: {}", .{err}),
        };
    };

    return .{
        .kind = "git_status",
        .label = label,
        .content = output,
        .bytes = output.len,
    };
}

fn runGitCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    args: []const []const u8,
) ![]u8 {
    _ = io;
    // Build argv: git <args>
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    for (args) |a| try argv.append(allocator, a);

    const spawn_opts = process_spawn.SpawnOptions{
        .cwd = root.path,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    };

    const result = process_spawn.runCapture(allocator, argv.items, spawn_opts) catch return error.SubprocessFailed;
    if (result.exit_code != 0) {
        allocator.free(result.output);
        return error.SubprocessFailed;
    }

    return result.output;
}

fn kindForMention(m: mention_parser.Mention) []const u8 {
    return switch (m) {
        .file => "file",
        .symbol => "symbol",
        .web => "web",
        .docs => "docs",
        .spec => "spec",
        .recent => "recent",
        .git_diff => "git_diff",
        .git_status => "git_status",
    };
}

fn labelForMention(allocator: std.mem.Allocator, m: mention_parser.Mention) ![]u8 {
    return switch (m) {
        .file => |f| std.fmt.allocPrint(allocator, "@file:{s}", .{f.path}),
        .symbol => |s| std.fmt.allocPrint(allocator, "@symbol:{s}", .{s}),
        .web => |w| std.fmt.allocPrint(allocator, "@web:{s}", .{w}),
        .docs => |d| std.fmt.allocPrint(allocator, "@docs:{s}", .{d}),
        .spec => |sp| std.fmt.allocPrint(allocator, "@spec:{s}", .{sp}),
        .recent => allocator.dupe(u8, "@recent"),
        .git_diff => allocator.dupe(u8, "@git:diff"),
        .git_status => allocator.dupe(u8, "@git:status"),
    };
}

test "resolveAll handles empty mentions" {
    const allocator = std.testing.allocator;
    const results = try resolveAll(allocator, std.testing.io, null, &.{});
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "resolveFile returns error without workspace" {
    const allocator = std.testing.allocator;
    const mentions = [_]mention_parser.Mention{.{ .file = .{ .path = "test.zig" } }};
    const results = try resolveAll(allocator, std.testing.io, null, &mentions);
    defer {
        for (results) |*r| {
            var r_mut = r.*;
            r_mut.deinit(allocator);
        }
        allocator.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expect(results[0].error_message != null);
}

test "resolveSpec returns error without workspace" {
    const allocator = std.testing.allocator;
    const mentions = [_]mention_parser.Mention{.{ .spec = "test-spec" }};
    const results = try resolveAll(allocator, std.testing.io, null, &mentions);
    defer {
        for (results) |*r| {
            var r_mut = r.*;
            r_mut.deinit(allocator);
        }
        allocator.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expect(results[0].error_message != null);
}

test "resolveSymbol returns error without workspace" {
    const allocator = std.testing.allocator;
    const mentions = [_]mention_parser.Mention{.{ .symbol = "foo" }};
    const results = try resolveAll(allocator, std.testing.io, null, &mentions);
    defer {
        for (results) |*r| {
            var r_mut = r.*;
            r_mut.deinit(allocator);
        }
        allocator.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expect(results[0].error_message != null);
    try std.testing.expect(std.mem.indexOf(u8, results[0].error_message.?, "no workspace") != null);
}

test "sliceLines extracts range" {
    const allocator = std.testing.allocator;
    const content = "line1\nline2\nline3\nline4\nline5\n";
    const sliced = try sliceLines(allocator, content, 2, 4);
    defer allocator.free(sliced);
    try std.testing.expectEqualStrings("line2\nline3\nline4\n", sliced);
}
