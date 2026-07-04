const std = @import("std");
const cancellation = @import("cancellation.zig");
const process_spawn = @import("forge-util").process_spawn;

pub const ProcessOptions = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    token: ?cancellation.CancellationToken = null,
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

test "Process runner struct compiles" {
    // Tests deferred to integration due to environment isolation
}
