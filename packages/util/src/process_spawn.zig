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
    /// Extra/overriding environment variables (merged with inherited environ).
    extra_env: []const EnvEntry = &.{},
    /// Enable macos sandbox-exec wrapping (only applies on macos)
    use_mac_sandbox: bool = false,
    mac_sandbox_profile: ?[]const u8 = null,
};

pub const EnvEntry = struct {
    key: []const u8,
    value: []const u8,
};

const EnvpPtr = [*]const ?[*:0]const u8;

const EnvpBundle = struct {
    pairs: [][:0]u8,
    ptr: EnvpPtr,
    ptr_storage: []?[*:0]const u8,
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
    if (options.extra_env.len == 0) {
        return spawnRaw(allocator, argv_in, options, null);
    }
    const envp = try buildEnvp(allocator, options.extra_env);
    defer freeEnvp(allocator, envp);
    return spawnRaw(allocator, argv_in, options, envp.ptr);
}

fn spawnRaw(
    allocator: std.mem.Allocator,
    argv_in: []const []const u8,
    options: SpawnOptions,
    envp: ?EnvpPtr,
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

    var out_arg_idx: usize = 0;
    const builtin = @import("builtin");
    if (builtin.os.tag == .macos and options.use_mac_sandbox and options.mac_sandbox_profile != null) {
        if (argv_in.len + 3 > max_spawn_args) return error.EmptyArgv;

        const sandbox_bin = "sandbox-exec";
        @memcpy(arg_storage[out_arg_idx][0..sandbox_bin.len], sandbox_bin);
        arg_storage[out_arg_idx][sandbox_bin.len] = 0;
        c_argv[out_arg_idx] = &arg_storage[out_arg_idx];
        out_arg_idx += 1;

        const p_flag = "-p";
        @memcpy(arg_storage[out_arg_idx][0..p_flag.len], p_flag);
        arg_storage[out_arg_idx][p_flag.len] = 0;
        c_argv[out_arg_idx] = &arg_storage[out_arg_idx];
        out_arg_idx += 1;

        const profile = options.mac_sandbox_profile.?;
        if (profile.len >= max_arg_bytes) return error.PathTooLong;
        @memcpy(arg_storage[out_arg_idx][0..profile.len], profile);
        arg_storage[out_arg_idx][profile.len] = 0;
        c_argv[out_arg_idx] = &arg_storage[out_arg_idx];
        out_arg_idx += 1;
    }

    for (argv_in) |arg| {
        if (arg.len >= max_arg_bytes) return error.PathTooLong;
        @memcpy(arg_storage[out_arg_idx][0..arg.len], arg);
        arg_storage[out_arg_idx][arg.len] = 0;
        c_argv[out_arg_idx] = &arg_storage[out_arg_idx];
        out_arg_idx += 1;
    }

    var spawned: c.forge_process_child = undefined;
    const spawn_rc = if (envp) |env_ptr|
        c.forge_process_spawn_env(
            cwd_ptr,
            @ptrCast(&c_argv),
            @ptrCast(env_ptr),
            mapStdio(options.stdin),
            mapStdio(options.stdout),
            mapStdio(options.stderr),
            &spawned,
        )
    else
        c.forge_process_spawn(
            cwd_ptr,
            @ptrCast(&c_argv),
            mapStdio(options.stdin),
            mapStdio(options.stdout),
            mapStdio(options.stderr),
            &spawned,
        );
    if (spawn_rc != 0) {
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

fn buildEnvp(allocator: std.mem.Allocator, extra: []const EnvEntry) RunError!EnvpBundle {
    var map = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var it_free = map.iterator();
        while (it_free.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        map.deinit();
    }

    if (c.environ) |env| {
        var i: usize = 0;
        while (env[i]) |entry| : (i += 1) {
            const line: []const u8 = std.mem.span(entry);
            if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
                const key = try allocator.dupe(u8, line[0..eq]);
                const value = try allocator.dupe(u8, line[eq + 1 ..]);
                try map.put(key, value);
            }
        }
    }

    for (extra) |item| {
        const owned_key = try allocator.dupe(u8, item.key);
        const owned_val = try allocator.dupe(u8, item.value);
        const gop = try map.getOrPut(owned_key);
        if (gop.found_existing) {
            allocator.free(owned_key);
            allocator.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = owned_val;
    }

    var pairs: std.ArrayList([:0]u8) = .empty;
    errdefer {
        for (pairs.items) |pair| allocator.free(pair);
        pairs.deinit(allocator);
    }

    var it = map.iterator();
    while (it.next()) |entry| {
        const pair = try std.fmt.allocPrintSentinel(allocator, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* }, 0);
        try pairs.append(allocator, pair);
    }

    var it_free = map.iterator();
    while (it_free.next()) |e| {
        allocator.free(e.key_ptr.*);
        allocator.free(e.value_ptr.*);
    }
    map.deinit();

    const owned_pairs = try pairs.toOwnedSlice(allocator);
    const ptr_buf = try allocator.alloc(?[*:0]const u8, owned_pairs.len + 1);
    for (owned_pairs, 0..) |pair, i| ptr_buf[i] = pair.ptr;
    ptr_buf[owned_pairs.len] = null;

    return .{ .pairs = owned_pairs, .ptr = ptr_buf.ptr, .ptr_storage = ptr_buf };
}

fn freeEnvp(allocator: std.mem.Allocator, envp: EnvpBundle) void {
    for (envp.pairs) |pair| allocator.free(pair);
    allocator.free(envp.pairs);
    allocator.free(envp.ptr_storage);
}

test "runCapture reads echo output" {
    const allocator = std.testing.allocator;
    const result = try runCapture(allocator, &.{ "echo", "forge" }, .{});
    defer allocator.free(result.output);
    try std.testing.expect(result.exit_code == 0);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "forge") != null);
}
