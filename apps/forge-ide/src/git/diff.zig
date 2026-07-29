const std = @import("std");
const process_spawn = @import("forge-util").process_spawn;

pub fn fileDiff(
    allocator: std.mem.Allocator,
    workspace_path: []const u8,
    path: []const u8,
    untracked: bool,
    is_staged: bool,
) ![]u8 {
    if (untracked) {
        const abs = try std.fs.path.join(allocator, &.{ workspace_path, path });
        defer allocator.free(abs);
        return runCapture(allocator, workspace_path, &.{
            "git", "diff", "--no-index", "--", "/dev/null", abs,
        });
    }
    if (is_staged) {
        return runCapture(allocator, workspace_path, &.{ "git", "diff", "--cached", "--", path });
    }
    return runCapture(allocator, workspace_path, &.{ "git", "diff", "--", path });
}

fn runCapture(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) ![]u8 {
    const result = try process_spawn.runCapture(allocator, args, .{ .cwd = cwd });
    const logger = @import("logger.zig");
    logger.log(args);
    defer allocator.free(result.output);
    if (result.output.len > 0) {
        return try allocator.dupe(u8, result.output);
    }
    return try allocator.dupe(u8, "(no diff)");
}

test "file diff in repo" {
    const allocator = std.testing.allocator;
    const diff = fileDiff(allocator, ".", "README.md", false, false) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer allocator.free(diff);
    _ = diff.len;
}
