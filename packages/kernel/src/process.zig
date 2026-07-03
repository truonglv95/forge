const std = @import("std");
const cancellation = @import("cancellation.zig");

pub const ProcessOptions = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    token: ?cancellation.CancellationToken = null,
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, options: ProcessOptions) !std.process.Child.Term {
    _ = allocator;

    const cwd: std.process.Child.Cwd = if (options.cwd) |path| .{ .path = path } else .inherit;

    var child = try std.process.spawn(io, .{
        .argv = options.argv,
        .cwd = cwd,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    if (options.token) |tok| {
        if (tok.isCancelled()) {
            child.kill(io);
            return std.process.Child.Term{ .signal = std.posix.SIG.KILL };
        }
    }

    return try child.wait(io);
}

test "Process runner struct compiles" {
    // Tests deferred to integration due to environment isolation
}
