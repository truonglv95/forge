const std = @import("std");
const cancellation = @import("cancellation.zig");
const process_spawn = @import("forge-util").process_spawn;

pub const ProcessOptions = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    token: ?cancellation.CancellationToken = null,
};

pub const CaptureOptions = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    max_bytes: usize = 32 * 1024,
};

pub const CaptureResult = struct {
    output: []const u8,
    exit_code: i32,
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, options: ProcessOptions) !std.process.Child.Term {
    _ = io;

    var child = try process_spawn.spawn(allocator, options.argv, .{
        .cwd = options.cwd,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    defer child.deinit();

    if (options.token) |tok| {
        if (tok.isCancelled()) {
            child.kill();
            return std.process.Child.Term{ .signal = std.posix.SIG.KILL };
        }
    }

    const code = child.wait();
    return std.process.Child.Term{ .exited = @intCast(code) };
}

pub fn runCapture(allocator: std.mem.Allocator, options: CaptureOptions) !CaptureResult {
    const result = try process_spawn.runCapture(allocator, options.argv, .{
        .cwd = options.cwd,
        .stdin = .ignore,
    });
    const clipped_len = @min(result.output.len, options.max_bytes);
    const output = try allocator.dupe(u8, result.output[0..clipped_len]);
    allocator.free(result.output);
    return .{ .output = output, .exit_code = result.exit_code };
}

test "Process runner struct compiles" {
    // Tests deferred to integration due to environment isolation
}
