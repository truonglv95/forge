const std = @import("std");
const builtin = @import("builtin");
const renderer = @import("forge-renderer");
const forge_util = @import("forge-util");

const c = @cImport({
    @cInclude("pty_spawn.h");
    @cInclude("unistd.h");
    @cInclude("signal.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/types.h");
    @cInclude("sys/wait.h");
    @cInclude("stdlib.h");
});

const posix = std.posix;
const terminal_filter = @import("terminal_filter.zig");

const fallback_prompt = "$ ";

pub const TerminalSession = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
    lines: std.ArrayList([]const u8),
    pending_write: std.ArrayList(u8),
    mutex: forge_util.sync.Mutex = .{},
    master_fd: c_int = -1,
    child_pid: c.pid_t = -1,
    local_input: ?[]const u8 = null,
    prompt_line: ?[]const u8 = null,
    running: bool = false,
    starting: bool = false,
    exited: bool = false,
    last_cols: u16 = 0,
    last_rows: u16 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, workspace_path: []const u8) !TerminalSession {
        return .{
            .allocator = allocator,
            .io = io,
            .workspace_path = try allocator.dupe(u8, workspace_path),
            .lines = .empty,
            .pending_write = .empty,
        };
    }

    pub fn deinit(self: *TerminalSession) void {
        self.stop();
        for (self.lines.items) |line| self.allocator.free(line);
        if (self.local_input) |line| self.allocator.free(line);
        if (self.prompt_line) |line| self.allocator.free(line);
        self.lines.deinit(self.allocator);
        self.pending_write.deinit(self.allocator);
        self.allocator.free(self.workspace_path);
        self.mutex.deinit();
    }

    pub fn lock(self: *TerminalSession) void {
        self.mutex.lock();
    }

    pub fn unlock(self: *TerminalSession) void {
        self.mutex.unlock();
    }

    pub fn isActive(self: *const TerminalSession) bool {
        return self.running or self.starting;
    }

    pub fn resize(self: *TerminalSession, cols: u16, rows: u16) void {
        self.lock();
        defer self.unlock();
        if (self.master_fd < 0 or !self.running) return;
        if (self.last_cols == cols and self.last_rows == rows) return;
        self.last_cols = cols;
        self.last_rows = rows;
        var ws: c.struct_winsize = .{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        _ = c.ioctl(self.master_fd, c.TIOCSWINSZ, &ws);
    }

    pub fn ensureStarted(self: *TerminalSession) !void {
        self.lock();
        if (self.running or self.starting) {
            self.unlock();
            return;
        }
        if (self.exited) {
            for (self.lines.items) |line| self.allocator.free(line);
            self.lines.clearRetainingCapacity();
            if (self.local_input) |line| {
                self.allocator.free(line);
                self.local_input = null;
            }
            if (self.prompt_line) |line| {
                self.allocator.free(line);
                self.prompt_line = null;
            }
            self.pending_write.clearRetainingCapacity();
        }
        self.starting = true;
        self.exited = false;
        self.unlock();

        // Spawn the PTY shell on the caller thread (main/UI). Avoid fork/spawn from
        // a background thread while AppKit and other workers are active.
        const shell = defaultShellPath();
        std.debug.print("[terminal] spawning shell on main thread: {s}\n", .{shell});

        const spawn = spawnShellInPty(self.workspace_path, shell) catch {
            std.debug.print("[terminal] spawn failed\n", .{});
            try self.appendLine("[terminal] failed to start shell");
            self.lock();
            self.starting = false;
            self.exited = true;
            self.unlock();
            return error.SpawnFailed;
        };

        self.lock();
        self.master_fd = spawn.master;
        self.child_pid = spawn.child;
        self.running = true;
        self.starting = false;
        self.flushPendingWriteLocked();
        self.unlock();

        std.debug.print("[terminal] shell pid={} master_fd={}\n", .{ spawn.child, spawn.master });

        const thread = std.Thread.spawn(.{}, readerMain, .{self}) catch |err| {
            self.stop();
            return err;
        };
        thread.detach();
    }

    pub fn stop(self: *TerminalSession) void {
        self.lock();
        const pid = self.child_pid;
        const master = self.master_fd;
        self.child_pid = -1;
        self.master_fd = -1;
        self.running = false;
        self.starting = false;
        self.unlock();

        if (pid > 0) {
            _ = c.kill(pid, c.SIGTERM);
            var status: c_int = 0;
            _ = c.waitpid(pid, &status, 0);
        }
        if (master >= 0) _ = c.close(master);
    }

    pub fn writeInput(self: *TerminalSession, bytes: []const u8) void {
        if (bytes.len == 0) return;
        self.applyLocalEcho(bytes) catch {};
        self.ensureStarted() catch return;
        self.stagePtyBytes(bytes) catch {};
    }

    pub fn encodeKey(event: renderer.KeyEvent, buf: []u8) ?[]const u8 {
        const cmd_mask: i32 = 0x08;
        if (event.modifiers & cmd_mask != 0) return null;

        switch (event.keycode) {
            36 => return copyBytes(buf, "\r"),
            51 => return copyBytes(buf, "\x7f"),
            48 => return copyBytes(buf, "\t"),
            126 => return copyBytes(buf, "\x1b[A"),
            125 => return copyBytes(buf, "\x1b[B"),
            123 => return copyBytes(buf, "\x1b[D"),
            124 => return copyBytes(buf, "\x1b[C"),
            53 => return copyBytes(buf, "\x1b"),
            else => {},
        }

        if (event.chars.len > 0) {
            if (event.chars.len <= buf.len) return event.chars[0..event.chars.len];
        }
        return null;
    }

    pub fn appendLine(self: *TerminalSession, line: []const u8) !void {
        try self.appendDisplayLine(line);
    }

    fn appendDisplayLine(self: *TerminalSession, line: []const u8) !void {
        if (line.len == 0) return;
        const owned = try self.allocator.dupe(u8, line);
        errdefer self.allocator.free(owned);
        self.lock();
        defer self.unlock();
        try self.lines.append(self.allocator, owned);
    }

    pub fn setPromptLine(self: *TerminalSession, line: []const u8) !void {
        self.lock();
        defer self.unlock();
        if (self.prompt_line) |prev| self.allocator.free(prev);
        self.prompt_line = try self.allocator.dupe(u8, line);
    }

    pub fn activeLine(self: *const TerminalSession, buf: []u8) []const u8 {
        const prompt = self.prompt_line orelse fallback_prompt;
        var len: usize = 0;
        const prefix_n = @min(prompt.len, buf.len);
        @memcpy(buf[0..prefix_n], prompt[0..prefix_n]);
        len = prefix_n;
        if (self.local_input) |input| {
            const room = buf.len - len;
            if (room > 0) {
                const n = @min(input.len, room);
                @memcpy(buf[len..][0..n], input[0..n]);
                len += n;
            }
        }
        return buf[0..len];
    }

    fn stagePtyBytes(self: *TerminalSession, bytes: []const u8) !void {
        self.lock();
        defer self.unlock();
        try self.pending_write.appendSlice(self.allocator, bytes);
        self.flushPendingWriteLocked();
    }

    fn flushPendingWriteLocked(self: *TerminalSession) void {
        if (self.master_fd < 0 or self.pending_write.items.len == 0) return;
        _ = c.write(self.master_fd, self.pending_write.items.ptr, self.pending_write.items.len);
        self.pending_write.clearRetainingCapacity();
    }

    fn applyLocalEcho(self: *TerminalSession, bytes: []const u8) !void {
        self.lock();
        defer self.unlock();

        var input = std.ArrayList(u8).empty;
        errdefer input.deinit(self.allocator);
        if (self.local_input) |existing| {
            try input.appendSlice(self.allocator, existing);
        }

        var index: usize = 0;
        while (index < bytes.len) {
            const byte = bytes[index];
            switch (byte) {
                '\r', '\n' => {
                    try self.appendCommittedLineLocked(&input);
                    input.clearRetainingCapacity();
                    index += 1;
                },
                '\x7f', '\x08' => {
                    popLastUtf8(&input);
                    index += 1;
                },
                '\t' => {
                    try input.append(self.allocator, '\t');
                    index += 1;
                },
                else => {
                    if (byte < 32) {
                        index += 1;
                        continue;
                    }
                    const seq_len = utf8SequenceLen(bytes[index..]) orelse 1;
                    const end = @min(index + seq_len, bytes.len);
                    try input.appendSlice(self.allocator, bytes[index..end]);
                    index = end;
                },
            }
        }

        if (self.local_input) |old| self.allocator.free(old);
        self.local_input = if (input.items.len == 0)
            null
        else
            try input.toOwnedSlice(self.allocator);
    }

    fn appendCommittedLineLocked(self: *TerminalSession, input: *std.ArrayList(u8)) !void {
        if (input.items.len == 0) return;

        var combined = std.ArrayList(u8).empty;
        defer combined.deinit(self.allocator);
        const prompt = self.prompt_line orelse fallback_prompt;
        try combined.appendSlice(self.allocator, prompt);
        try combined.appendSlice(self.allocator, input.items);

        const owned = try self.allocator.dupe(u8, combined.items);
        try self.lines.append(self.allocator, owned);
    }
};

fn utf8SequenceLen(bytes: []const u8) ?usize {
    if (bytes.len == 0) return null;
    const cp = std.unicode.utf8Decode(bytes) catch return 1;
    return std.unicode.utf8CodepointSequenceLength(cp) catch 1;
}

fn popLastUtf8(input: *std.ArrayList(u8)) void {
    if (input.items.len == 0) return;
    var index = input.items.len;
    while (index > 0) {
        index -= 1;
        if (input.items[index] & 0xC0 != 0x80) break;
    }
    input.shrinkRetainingCapacity(index);
}

const PtySpawn = struct {
    master: c_int,
    child: c.pid_t,
};

fn spawnShellInPty(workspace_path: []const u8, shell: []const u8) !PtySpawn {
    var cwd_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (workspace_path.len >= cwd_buf.len) return error.PathTooLong;
    @memcpy(cwd_buf[0..workspace_path.len], workspace_path);
    cwd_buf[workspace_path.len] = 0;

    var shell_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (shell.len >= shell_buf.len) return error.PathTooLong;
    @memcpy(shell_buf[0..shell.len], shell);
    shell_buf[shell.len] = 0;

    var master: c_int = undefined;
    var child: c.pid_t = undefined;
    if (c.forge_pty_spawn(&cwd_buf, &shell_buf, &master, &child) != 0) return error.SpawnFailed;
    return .{ .master = master, .child = child };
}

fn copyBytes(buf: []u8, bytes: []const u8) ?[]const u8 {
    if (bytes.len > buf.len) return null;
    @memcpy(buf[0..bytes.len], bytes);
    return buf[0..bytes.len];
}

fn appendFilteredLine(ctx: *anyopaque, line: []const u8) !void {
    const session: *TerminalSession = @ptrCast(@alignCast(ctx));
    try session.appendDisplayLine(line);
}

fn readMaster(fd: c_int, buf: *[4096]u8) !usize {
    return posix.read(fd, buf);
}

fn defaultShellPath() []const u8 {
    if (comptime builtin.target.os.tag.isDarwin()) {
        return "/bin/zsh";
    }
    if (c.getenv("SHELL")) |value| return std.mem.span(value);
    return "/bin/zsh";
}

fn readerMain(session: *TerminalSession) void {
    var assembler = terminal_filter.LineAssembler.init(session.allocator);
    defer assembler.deinit(session.allocator);

    const master = blk: {
        session.lock();
        defer session.unlock();
        break :blk session.master_fd;
    };
    if (master < 0) return;

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = readMaster(master, &buf) catch |err| {
            std.debug.print("[terminal] read error: {}\n", .{err});
            break;
        };
        if (n == 0) {
            std.debug.print("[terminal] read EOF\n", .{});
            break;
        }
        assembler.feed(session.allocator, buf[0..n], session, appendFilteredLine) catch {};
    }

    session.lock();
    const pid = session.child_pid;
    session.unlock();

    if (pid > 0) {
        var status: c_int = 0;
        _ = c.waitpid(pid, &status, 0);
        std.debug.print("[terminal] shell exited status={}\n", .{status});
    }

    session.appendLine("[terminal] shell exited — click TERMINAL tab to restart") catch {};

    session.lock();
    session.running = false;
    session.exited = true;
    session.child_pid = -1;
    if (session.master_fd >= 0) {
        _ = c.close(session.master_fd);
        session.master_fd = -1;
    }
    session.unlock();
}
