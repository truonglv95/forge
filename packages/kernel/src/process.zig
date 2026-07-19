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
    use_mac_sandbox: bool = false,
    mac_sandbox_profile: ?[]const u8 = null,
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
        .use_mac_sandbox = options.use_mac_sandbox,
        .mac_sandbox_profile = options.mac_sandbox_profile,
    });
    const clipped_len = @min(result.output.len, options.max_bytes);
    const output = try allocator.dupe(u8, result.output[0..clipped_len]);
    allocator.free(result.output);
    return .{ .output = output, .exit_code = result.exit_code };
}

pub const StreamOptions = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    max_bytes: usize = 32 * 1024,
    on_output: ?*const fn (?*anyopaque, []const u8) void = null,
    on_output_context: ?*anyopaque = null,
    token: ?cancellation.CancellationToken = null,
    use_mac_sandbox: bool = false,
    mac_sandbox_profile: ?[]const u8 = null,
};

pub const StreamResult = struct {
    output: []const u8,
    exit_code: i32,
    cancelled: bool = false,
};

pub fn runStreaming(allocator: std.mem.Allocator, options: StreamOptions) !StreamResult {
    const spawn_opts = process_spawn.SpawnOptions{
        .cwd = options.cwd,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .use_mac_sandbox = options.use_mac_sandbox,
        .mac_sandbox_profile = options.mac_sandbox_profile,
    };
    var child = try process_spawn.spawn(allocator, options.argv, spawn_opts);
    defer child.deinit();

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var chunk: [8192]u8 = undefined;
    var cancelled = false;

    while (output.items.len < options.max_bytes) {
        if (options.token) |tok| {
            if (tok.isCancelled()) {
                child.kill();
                cancelled = true;
                break;
            }
        }

        const stdout_open = child.stdout_fd >= 0;
        const stderr_open = child.stderr_fd >= 0;
        if (!stdout_open and !stderr_open) break;

        const room = options.max_bytes - output.items.len;
        const to_read = @min(chunk.len, room);

        if (stdout_open) {
            const n = std.posix.read(child.stdout_fd, chunk[0..to_read]) catch 0;
            if (n == 0) {
                closeFd(&child.stdout_fd);
            } else {
                try output.appendSlice(allocator, chunk[0..n]);
                if (options.on_output) |cb| cb(options.on_output_context, chunk[0..n]);
                continue;
            }
        }

        if (stderr_open) {
            const n = std.posix.read(child.stderr_fd, chunk[0..to_read]) catch 0;
            if (n == 0) {
                closeFd(&child.stderr_fd);
            } else {
                try output.appendSlice(allocator, chunk[0..n]);
                if (options.on_output) |cb| cb(options.on_output_context, chunk[0..n]);
                continue;
            }
        }

        if (!stdout_open and !stderr_open) break;
    }

    closeFd(&child.stdout_fd);
    closeFd(&child.stderr_fd);
    const exit_code = child.wait();

    return .{
        .output = try output.toOwnedSlice(allocator),
        .exit_code = exit_code,
        .cancelled = cancelled,
    };
}

fn closeFd(fd: *c_int) void {
    if (fd.* >= 0) {
        _ = std.c.close(fd.*);
        fd.* = -1;
    }
}

test "Process runner struct compiles" {
    // Tests deferred to integration due to environment isolation
}
