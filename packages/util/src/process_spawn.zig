const std = @import("std");

const c = @cImport({
    @cInclude("process_spawn.h");
    @cInclude("unistd.h");
});

const max_spawn_args = 32;
const max_arg_bytes = 4096;

pub const RunError = error{
    SpawnFailed,
    PathTooLong,
    EmptyArgv,
    WriteFailed,
    ReadFailed,
    OutOfMemory,
};

pub const Stdio = enum {
    inherit,
    ignore,
    pipe,
};

pub const SpawnOptions = struct {
    cwd: ?[]const u8 = null,
    stdin: Stdio = .inherit,
    stdout: Stdio = .inherit,
    stderr: Stdio = .inherit,
};

pub const CaptureResult = struct {
    output: []u8,
    exit_code: i32,
};

pub const Child = struct {
    pid: c.pid_t = -1,
    stdin_fd: c_int = -1,
    stdout_fd: c_int = -1,
    stderr_fd: c_int = -1,

    pub fn closeStdin(self: *Child) void {
        closeFd(&self.stdin_fd);
    }

    pub fn writeAll(self: *Child, data: []const u8) RunError!void {
        if (self.stdin_fd < 0) return error.WriteFailed;
        var offset: usize = 0;
        while (offset < data.len) {
            const n = c.write(self.stdin_fd, data.ptr + offset, data.len - offset);
            if (n <= 0) return error.WriteFailed;
            offset += @intCast(n);
        }
    }

    pub fn readStdoutAll(self: *Child, allocator: std.mem.Allocator, max_bytes: usize) RunError![]u8 {
        return readFdAll(allocator, self.stdout_fd, max_bytes);
    }

    pub fn kill(self: *Child) void {
        if (self.pid > 0) c.forge_process_kill(self.pid);
    }

    pub fn wait(self: *Child) i32 {
        if (self.pid <= 0) return 1;
        const code = c.forge_process_wait(self.pid);
        self.pid = -1;
        return code;
    }

    pub fn deinit(self: *Child) void {
        self.closeStdin();
        closeFd(&self.stdout_fd);
        closeFd(&self.stderr_fd);
        if (self.pid > 0) {
            self.kill();
            _ = self.wait();
        }
    }
};

/// Spawns a child without going through std.process.spawn(Io).
pub fn spawn(
    allocator: std.mem.Allocator,
    argv_in: []const []const u8,
    options: SpawnOptions,
) RunError!Child {
    _ = allocator;
    if (argv_in.len == 0) return error.EmptyArgv;
    if (argv_in.len > max_spawn_args) return error.EmptyArgv;

    var cwd_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    var cwd_ptr: ?[*:0]const u8 = null;
    if (options.cwd) |cwd| {
        if (cwd.len >= cwd_buf.len) return error.PathTooLong;
        @memcpy(cwd_buf[0..cwd.len], cwd);
        cwd_buf[cwd.len] = 0;
        cwd_ptr = &cwd_buf;
    }

    var arg_storage: [max_spawn_args][max_arg_bytes:0]u8 = undefined;
    var c_argv: [max_spawn_args + 1]?[*:0]const u8 = .{null} ** (max_spawn_args + 1);
    for (argv_in, 0..) |arg, i| {
        if (arg.len >= max_arg_bytes) return error.PathTooLong;
        @memcpy(arg_storage[i][0..arg.len], arg);
        arg_storage[i][arg.len] = 0;
        c_argv[i] = &arg_storage[i];
    }

    var spawned: c.forge_process_child = undefined;
    if (c.forge_process_spawn(
        cwd_ptr,
        @ptrCast(&c_argv),
        mapStdio(options.stdin),
        mapStdio(options.stdout),
        mapStdio(options.stderr),
        &spawned,
    ) != 0) {
        return error.SpawnFailed;
    }

    return .{
        .pid = spawned.pid,
        .stdin_fd = spawned.stdin_fd,
        .stdout_fd = spawned.stdout_fd,
        .stderr_fd = spawned.stderr_fd,
    };
}

pub fn runCapture(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    options: SpawnOptions,
) RunError!CaptureResult {
    var spawn_opts = options;
    spawn_opts.stdout = .pipe;
    spawn_opts.stderr = .pipe;

    var child = try spawn(allocator, argv, spawn_opts);
    defer child.deinit();

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try appendFd(allocator, &output, child.stdout_fd, std.math.maxInt(usize));
    try appendFd(allocator, &output, child.stderr_fd, std.math.maxInt(usize));
    closeFd(&child.stdout_fd);
    closeFd(&child.stderr_fd);

    return .{
        .output = try output.toOwnedSlice(allocator),
        .exit_code = child.wait(),
    };
}

pub fn runWait(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    options: SpawnOptions,
) RunError!i32 {
    var child = try spawn(allocator, argv, options);
    defer child.deinit();
    return child.wait();
}

pub fn readFdAll(allocator: std.mem.Allocator, fd: c_int, max_bytes: usize) RunError![]u8 {
    if (fd < 0) return error.ReadFailed;

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var chunk: [8192]u8 = undefined;

    while (output.items.len < max_bytes) {
        const room = max_bytes - output.items.len;
        const to_read = @min(chunk.len, room);
        const n = std.posix.read(fd, chunk[0..to_read]) catch return error.ReadFailed;
        if (n == 0) break;
        try output.appendSlice(allocator, chunk[0..n]);
    }

    return try output.toOwnedSlice(allocator);
}

fn mapStdio(mode: Stdio) c.forge_stdio_mode {
    return switch (mode) {
        .inherit => c.FORGE_STDIO_INHERIT,
        .ignore => c.FORGE_STDIO_IGNORE,
        .pipe => c.FORGE_STDIO_PIPE,
    };
}

fn appendFd(allocator: std.mem.Allocator, output: *std.ArrayList(u8), fd: c_int, max_bytes: usize) RunError!void {
    if (fd < 0) return;
    const bytes = try readFdAll(allocator, fd, max_bytes);
    defer allocator.free(bytes);
    try output.appendSlice(allocator, bytes);
}

fn closeFd(fd: *c_int) void {
    if (fd.* >= 0) {
        _ = c.close(fd.*);
        fd.* = -1;
    }
}

test "runCapture reads echo output" {
    const allocator = std.testing.allocator;
    const result = try runCapture(allocator, &.{ "echo", "forge" }, .{});
    defer allocator.free(result.output);
    try std.testing.expect(result.exit_code == 0);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "forge") != null);
}
