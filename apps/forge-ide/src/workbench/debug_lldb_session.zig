const std = @import("std");
const process_spawn = @import("forge-util").process_spawn;
const breakpoints_mod = @import("breakpoints.zig");
const forge_util = @import("forge-util");

pub const Session = struct {
    allocator: std.mem.Allocator,
    child: process_spawn.Child = .{},
    reader: ?std.Thread = null,
    running: std.atomic.Value(bool) = .init(false),
    on_line: *const fn (context: ?*anyopaque, line: []const u8) void,
    on_finished: *const fn (context: ?*anyopaque, exit_code: i32) void,
    context: ?*anyopaque,
    write_mutex: forge_util.sync.Mutex = .{},

    pub fn deinit(self: *Session) void {
        self.stop();
        self.write_mutex.deinit();
    }

    pub fn isActive(self: *const Session) bool {
        return self.running.load(.acquire);
    }

    pub fn start(
        self: *Session,
        allocator: std.mem.Allocator,
        workspace_path: []const u8,
        source_rel_path: []const u8,
        breakpoints: *const breakpoints_mod.Store,
        on_line: *const fn (context: ?*anyopaque, line: []const u8) void,
        on_finished: *const fn (context: ?*anyopaque, exit_code: i32) void,
        context: ?*anyopaque,
    ) !void {
        self.stop();
        self.allocator = allocator;
        self.on_line = on_line;
        self.on_finished = on_finished;
        self.context = context;

        self.child = try process_spawn.spawn(allocator, &.{ "lldb", "--no-lldbinit" }, .{
            .cwd = workspace_path,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        });

        self.running.store(true, .release);
        self.reader = try std.Thread.spawn(.{}, readerMain, .{self});

        try self.writeLine("settings set auto-confirm true");

        var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs_path = std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ workspace_path, source_rel_path }) catch return error.PathTooLong;

        for (breakpoints.items.items) |bp| {
            if (!std.mem.eql(u8, bp.path, source_rel_path)) continue;
            var bp_buf: [512]u8 = undefined;
            const cmd = try std.fmt.bufPrint(&bp_buf, "breakpoint set -f {s} -l {d}", .{ abs_path, bp.line + 1 });
            try self.writeLine(cmd);
        }

        var target_buf: [512]u8 = undefined;
        const target_cmd = try std.fmt.bufPrint(&target_buf, "target create -n forge -- zig run {s}", .{source_rel_path});
        try self.writeLine(target_cmd);
        try self.writeLine("process launch");
        self.on_line(context, "→ lldb session ready (F5 continue, F10 step over, F11 step in)");
    }

    pub fn stop(self: *Session) void {
        if (!self.running.swap(false, .acq_rel)) return;
        self.child.deinit();
        if (self.reader) |thread| thread.join();
        self.reader = null;
    }

    pub fn writeLine(self: *Session, line: []const u8) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        var buf: [512]u8 = undefined;
        const cmd = if (line.len + 1 <= buf.len) blk: {
            @memcpy(buf[0..line.len], line);
            buf[line.len] = '\n';
            break :blk buf[0 .. line.len + 1];
        } else line;
        try self.child.writeAll(cmd);
    }

    pub fn continueExecution(self: *Session) !void {
        try self.writeLine("process continue");
    }

    pub fn stepOver(self: *Session) !void {
        try self.writeLine("thread step-over");
        try self.writeLine("frame variable");
    }

    pub fn stepInto(self: *Session) !void {
        try self.writeLine("thread step-in");
        try self.writeLine("frame variable");
    }

    pub fn stepOut(self: *Session) !void {
        try self.writeLine("thread step-out");
        try self.writeLine("frame variable");
    }

    fn readerMain(self: *Session) void {
        defer {
            const code = self.child.wait();
            self.running.store(false, .release);
            self.on_finished(self.context, code);
        }

        var chunk: [4096]u8 = undefined;
        var pending: std.ArrayList(u8) = .empty;
        defer pending.deinit(self.allocator);

        while (self.running.load(.acquire)) {
            const n = std.posix.read(self.child.stdout_fd, &chunk) catch break;
            if (n == 0) break;
            pending.appendSlice(self.allocator, chunk[0..n]) catch break;

            while (std.mem.indexOfScalar(u8, pending.items, '\n')) |nl| {
                const line = pending.items[0..nl];
                emitTrimmed(self, line);
                const rest = pending.items[nl + 1 ..];
                pending.clearRetainingCapacity();
                pending.appendSlice(self.allocator, rest) catch break;
            }
        }

        if (pending.items.len > 0) emitTrimmed(self, pending.items);
    }

    fn emitTrimmed(self: *Session, line: []const u8) void {
        const trimmed = std.mem.trim(u8, &std.ascii.whitespace, line);
        if (trimmed.len == 0) return;
        if (std.mem.eql(u8, trimmed, "(lldb)")) return;
        self.on_line(self.context, trimmed);
    }
};
