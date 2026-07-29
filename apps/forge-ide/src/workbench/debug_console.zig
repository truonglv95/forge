const std = @import("std");
const forge_util = @import("forge-util");

pub const DebugConsole = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    lines: std.ArrayList([]const u8),
    mutex: forge_util.sync.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io) DebugConsole {
        return .{ .allocator = allocator, .io = io, .lines = .empty };
    }

    pub fn deinit(self: *DebugConsole) void {
        self.lock();
        defer self.unlock();
        for (self.lines.items) |line| self.allocator.free(line);
        self.lines.deinit(self.allocator);
        self.mutex.deinit();
    }

    pub fn lock(self: *DebugConsole) void {
        self.mutex.lock();
    }

    pub fn unlock(self: *DebugConsole) void {
        self.mutex.unlock();
    }

    pub fn clear(self: *DebugConsole) void {
        self.lock();
        defer self.unlock();
        for (self.lines.items) |line| self.allocator.free(line);
        self.lines.clearRetainingCapacity();
    }

    pub fn log(self: *DebugConsole, message: []const u8) !void {
        const owned = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(owned);
        self.lock();
        defer self.unlock();
        try self.lines.append(self.allocator, owned);
    }
};
