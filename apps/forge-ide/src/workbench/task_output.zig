const std = @import("std");
const forge_util = @import("forge-util");

pub const TaskOutput = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    lines: std.ArrayList([]const u8),
    mutex: forge_util.sync.Mutex = .{},
    scroll_y: f32 = 0,
    running: bool = false,
    last_exit_code: ?i32 = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) TaskOutput {
        return .{
            .allocator = allocator,
            .io = io,
            .lines = .empty,
        };
    }

    pub fn lock(self: *TaskOutput) void {
        self.mutex.lock();
    }

    pub fn unlock(self: *TaskOutput) void {
        self.mutex.unlock();
    }

    pub fn deinit(self: *TaskOutput) void {
        self.lock();
        defer self.unlock();
        self.clearUnlocked();
        self.lines.deinit(self.allocator);
        self.mutex.deinit();
    }

    pub fn clear(self: *TaskOutput) void {
        self.lock();
        defer self.unlock();
        self.clearUnlocked();
    }

    fn clearUnlocked(self: *TaskOutput) void {
        for (self.lines.items) |line| self.allocator.free(line);
        self.lines.clearRetainingCapacity();
        self.last_exit_code = null;
    }

    pub fn appendLine(self: *TaskOutput, line: []const u8) !void {
        const owned = try self.allocator.dupe(u8, line);
        errdefer self.allocator.free(owned);
        self.lock();
        defer self.unlock();
        try self.lines.append(self.allocator, owned);
    }

    pub fn appendChunk(self: *TaskOutput, chunk: []const u8) !void {
        var start: usize = 0;
        for (chunk, 0..) |byte, index| {
            if (byte == '\n') {
                try self.appendLine(chunk[start..index]);
                start = index + 1;
            }
        }
        if (start < chunk.len) try self.appendLine(chunk[start..]);
    }

    pub fn setRunning(self: *TaskOutput, value: bool) void {
        self.lock();
        defer self.unlock();
        self.running = value;
    }

    pub fn setExitCode(self: *TaskOutput, code: i32) void {
        self.lock();
        defer self.unlock();
        self.last_exit_code = code;
    }

    pub fn isRunning(self: *TaskOutput) bool {
        self.lock();
        defer self.unlock();
        return self.running;
    }

    pub fn snapshotState(self: *TaskOutput) struct { running: bool, last_exit_code: ?i32 } {
        self.lock();
        defer self.unlock();
        return .{ .running = self.running, .last_exit_code = self.last_exit_code };
    }
};
