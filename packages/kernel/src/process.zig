const std = @import("std");
const cancellation = @import("cancellation.zig");

pub const ProcessOptions = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    token: ?cancellation.CancellationToken = null,
};

pub fn run(allocator: std.mem.Allocator, options: ProcessOptions) !std.process.Child.Term {
    var child = std.process.Child.init(options.argv, allocator);
    child.cwd = options.cwd;

    // Explicitly enforce no shell by ignoring stdin and piping out/err natively
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    if (options.token) |tok| {
        // In a more complex implementation, we would poll the token asynchronously.
        // For MVP, we check just before blocking wait.
        if (tok.isCancelled()) {
            _ = try child.kill();
            return std.process.Child.Term{ .Signal = std.posix.SIG.KILL };
        }
    }

    return try child.wait();
}

test "Process runner struct compiles" {
    // Tests deferred to integration due to environment isolation
}
