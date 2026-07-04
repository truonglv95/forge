const std = @import("std");
const process_spawn = @import("forge-util").process_spawn;

pub const CaptureOptions = struct {
    max_bytes: usize = 32 * 1024,
    max_paths: usize = 32,
};

/// Parses `git status --porcelain` and returns changed file paths (new path for renames).
pub fn listChangedPaths(
    allocator: std.mem.Allocator,
    workspace_cwd: []const u8,
    max_paths: usize,
) ![]const []const u8 {
    const repo_check = process_spawn.runCapture(allocator, &.{
        "git", "-C", workspace_cwd, "rev-parse", "--is-inside-work-tree",
    }, .{}) catch return &.{};
    defer allocator.free(repo_check.output);
    if (repo_check.exit_code != 0) return &.{};
    if (!std.mem.startsWith(u8, std.mem.trim(u8, repo_check.output, " \t\r\n"), "true")) return &.{};

    const porcelain = process_spawn.runCapture(allocator, &.{
        "git", "-C", workspace_cwd, "status", "--porcelain",
    }, .{}) catch return &.{};
    defer allocator.free(porcelain.output);
    if (porcelain.exit_code != 0) return &.{};

    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |path| allocator.free(path);
        out.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, porcelain.output, '\n');
    while (lines.next()) |line| {
        if (line.len < 4) continue;
        if (out.items.len >= max_paths) break;
        const raw = if (line.len > 3 and line[3] == ' ') line[3..] else continue;
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) continue;

        const path = if (std.mem.indexOf(u8, trimmed, " -> ")) |arrow|
            std.mem.trim(u8, trimmed[arrow + 4 ..], " \t\r\n")
        else
            trimmed;

        if (path.len == 0) continue;
        try out.append(allocator, try allocator.dupe(u8, path));
    }

    return try out.toOwnedSlice(allocator);
}

pub fn freePaths(allocator: std.mem.Allocator, paths: []const []const u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

/// Returns a human-readable summary of uncommitted changes, or null if not a git repo.
pub fn captureWorkingDiff(
    allocator: std.mem.Allocator,
    workspace_cwd: []const u8,
    options: CaptureOptions,
) !?[]const u8 {
    const repo_check = process_spawn.runCapture(allocator, &.{
        "git", "-C", workspace_cwd, "rev-parse", "--is-inside-work-tree",
    }, .{}) catch return null;
    defer allocator.free(repo_check.output);
    if (repo_check.exit_code != 0) return null;
    if (!std.mem.startsWith(u8, std.mem.trim(u8, repo_check.output, " \t\r\n"), "true")) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "=== Git working tree (uncommitted) ===\n");

    const branch_out = process_spawn.runCapture(allocator, &.{
        "git", "-C", workspace_cwd, "branch", "--show-current",
    }, .{}) catch null;
    if (branch_out) |branch| {
        defer allocator.free(branch.output);
        const name = std.mem.trim(u8, branch.output, " \t\r\n");
        if (name.len > 0) {
            try out.appendSlice(allocator, "Branch: ");
            try out.appendSlice(allocator, name);
            try out.append(allocator, '\n');
        }
    }

    const stat = process_spawn.runCapture(allocator, &.{
        "git", "-C", workspace_cwd, "diff", "--stat", "HEAD",
    }, .{}) catch null;
    if (stat) |result| {
        defer allocator.free(result.output);
        const trimmed = std.mem.trim(u8, result.output, " \t\r\n");
        if (trimmed.len > 0) {
            try out.appendSlice(allocator, "\n--- diff --stat ---\n");
            try appendTruncated(allocator, &out, trimmed, options.max_bytes);
        }
    }

    const porcelain = process_spawn.runCapture(allocator, &.{
        "git", "-C", workspace_cwd, "status", "--porcelain",
    }, .{}) catch null;
    if (porcelain) |result| {
        defer allocator.free(result.output);
        const trimmed = std.mem.trim(u8, result.output, " \t\r\n");
        if (trimmed.len > 0) {
            try out.appendSlice(allocator, "\n--- status ---\n");
            try appendTruncated(allocator, &out, trimmed, options.max_bytes);
        }
    }

    const remaining = options.max_bytes -| out.items.len;
    if (remaining > 256) {
        const diff = process_spawn.runCapture(allocator, &.{
            "git", "-C", workspace_cwd, "diff", "--no-color", "HEAD",
        }, .{}) catch null;
        if (diff) |result| {
            defer allocator.free(result.output);
            const trimmed = std.mem.trim(u8, result.output, " \t\r\n");
            if (trimmed.len > 0) {
                try out.appendSlice(allocator, "\n--- diff ---\n");
                try appendTruncated(allocator, &out, trimmed, remaining);
            }
        }
    }

    if (out.items.len <= "=== Git working tree (uncommitted) ===\n".len) return null;
    return try out.toOwnedSlice(allocator);
}

fn appendTruncated(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8, max_add: usize) !void {
    const take = @min(text.len, max_add);
    try out.appendSlice(allocator, text[0..take]);
    if (take < text.len) {
        try out.appendSlice(allocator, "\n... [truncated]\n");
    } else {
        try out.append(allocator, '\n');
    }
}

test "captureWorkingDiff handles missing git gracefully" {
    const allocator = std.testing.allocator;
    const result = try captureWorkingDiff(allocator, "/tmp/forge-non-git-path", .{});
    if (result) |text| {
        defer allocator.free(text);
    }
}
