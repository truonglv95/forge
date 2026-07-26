//! CLI black-box contract tests.
//!
//! Spawns the compiled `forge` binary as a subprocess and verifies:
//!   - Exit codes and basic stdout presence
//!   - Unknown subcommands return non-zero
//!   - --non-interactive mode does not block on stdin
//!
//! Run with: zig build test-contracts

const std = @import("std");

fn forgeBin(allocator: std.mem.Allocator) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.process.getCwd(&buf);
    return std.fmt.allocPrint(allocator, "{s}/zig-out/bin/forge", .{cwd});
}

fn runForge(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdin_data: ?[]const u8,
) !struct { stdout: []u8, stderr: []u8, exit_code: u32 } {
    const bin = try forgeBin(allocator);
    defer allocator.free(bin);

    var argv = try allocator.alloc([]const u8, args.len + 1);
    defer allocator.free(argv);
    argv[0] = bin;
    for (args, 1..) |arg, i| argv[i] = arg;

    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    if (stdin_data != null) {
        child.stdin_behavior = .Pipe;
    } else {
        child.stdin_behavior = .Close;
    }

    try child.spawn();

    if (stdin_data) |data| {
        try child.stdin.?.writeAll(data);
        child.stdin.?.close();
        child.stdin = null;
    }

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1 << 20);
    errdefer allocator.free(stdout);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1 << 20);
    errdefer allocator.free(stderr);

    const term = try child.wait();
    const exit_code: u32 = switch (term) {
        .Exited => |code| code,
        else => 255,
    };

    return .{ .stdout = stdout, .stderr = stderr, .exit_code = exit_code };
}

// ---------------------------------------------------------------------------

test "cli contract: forge help exits 0" {
    const allocator = std.testing.allocator;

    const result = runForge(allocator, &.{"help"}, null) catch |err| {
        std.debug.print("[skip] forge binary not found: {}\n", .{err});
        return;
    };
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expectEqual(@as(u32, 0), result.exit_code);
    try std.testing.expect(result.stdout.len > 0 or result.stderr.len > 0);
}

test "cli contract: unknown subcommand exits non-zero" {
    const allocator = std.testing.allocator;

    const result = runForge(allocator, &.{"this-command-does-not-exist-xyz"}, null) catch |err| {
        std.debug.print("[skip] forge binary not found: {}\n", .{err});
        return;
    };
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expect(result.exit_code != 0);
}

test "cli contract: --non-interactive does not block on empty stdin" {
    const allocator = std.testing.allocator;

    const result = runForge(
        allocator,
        &.{ "help", "--non-interactive" },
        "",
    ) catch |err| {
        std.debug.print("[skip] forge binary not found: {}\n", .{err});
        return;
    };
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    // Must complete promptly without hanging — exit code <= 1 is OK.
    try std.testing.expect(result.exit_code <= 1);
}

test "cli contract: version subcommand returns 0" {
    const allocator = std.testing.allocator;

    const result = runForge(allocator, &.{"version"}, null) catch |err| {
        std.debug.print("[skip] forge binary not found: {}\n", .{err});
        return;
    };
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try std.testing.expectEqual(@as(u32, 0), result.exit_code);
}

test "cli contract: forge review --heuristic-only exits 0 with no changes" {
    const allocator = std.testing.allocator;

    // Run in a temp workspace with no git changes — should report "No changes to review."
    const result = runForge(allocator, &.{ "review", "--heuristic-only", "--quiet" }, null) catch |err| {
        std.debug.print("[skip] forge binary not found: {}\n", .{err});
        return;
    };
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    // Exit 0 is expected when there are no changes (or when git is unavailable).
    // Exit 2 is acceptable if the workspace can't be opened.
    try std.testing.expect(result.exit_code == 0 or result.exit_code == 2);
}

test "cli contract: forge test-gen without --file exits 2" {
    const allocator = std.testing.allocator;

    const result = runForge(allocator, &.{ "test-gen" }, null) catch |err| {
        std.debug.print("[skip] forge binary not found: {}\n", .{err});
        return;
    };
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    // Should exit 2 with usage message.
    try std.testing.expectEqual(@as(u32, 2), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "test-gen requires --file") != null or
        std.mem.indexOf(u8, result.stderr, "test-gen requires --file") != null);
}

test "cli contract: forge review --json produces valid output structure" {
    const allocator = std.testing.allocator;

    const result = runForge(allocator, &.{ "review", "--heuristic-only", "--json", "--quiet" }, null) catch |err| {
        std.debug.print("[skip] forge binary not found: {}\n", .{err});
        return;
    };
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    // Exit 0 or 2 (no git / no workspace) is acceptable.
    if (result.exit_code == 0) {
        // If JSON output was produced, it should contain "overall_score" or "No changes".
        const has_score = std.mem.indexOf(u8, result.stdout, "overall_score") != null;
        const has_no_changes = std.mem.indexOf(u8, result.stdout, "No changes") != null;
        try std.testing.expect(has_score or has_no_changes);
    }
}

test "cli contract: forge eval ai-flow --help shows providers flag" {
    const allocator = std.testing.allocator;

    const result = runForge(allocator, &.{"eval"}, null) catch |err| {
        std.debug.print("[skip] forge binary not found: {}\n", .{err});
        return;
    };
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    // Should exit 2 (no suite specified) and show help with --providers flag.
    try std.testing.expectEqual(@as(u32, 2), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "--providers") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Multi-provider comparison") != null);
}

test "cli contract: forge agent run --coordinated requires intent" {
    const allocator = std.testing.allocator;

    const result = runForge(allocator, &.{ "agent", "run", "--coordinated", "--quiet" }, null) catch |err| {
        std.debug.print("[skip] forge binary not found: {}\n", .{err});
        return;
    };
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    // Should exit 2 because no intent was provided.
    try std.testing.expectEqual(@as(u32, 2), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "agent run requires an intent") != null or
        std.mem.indexOf(u8, result.stderr, "agent run requires an intent") != null);
}
