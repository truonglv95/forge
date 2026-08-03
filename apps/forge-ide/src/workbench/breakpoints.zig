const std = @import("std");

pub const Breakpoint = struct {
    path: []const u8,
    line: usize,

    pub fn deinit(self: *Breakpoint, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const Entry = struct {
    path: []const u8,
    line: usize,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Breakpoint),

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator, .items = .empty };
    }

    pub fn deinit(self: *Store) void {
        for (self.items.items) |*bp| bp.deinit(self.allocator);
        self.items.deinit(self.allocator);
    }

    pub fn toggle(self: *Store, path: []const u8, line: usize) !bool {
        for (self.items.items, 0..) |*bp, index| {
            if (std.mem.eql(u8, bp.path, path) and bp.line == line) {
                bp.deinit(self.allocator);
                _ = self.items.orderedRemove(index);
                return false;
            }
        }
        try self.items.append(self.allocator, .{
            .path = try self.allocator.dupe(u8, path),
            .line = line,
        });
        return true;
    }

    pub fn clear(self: *Store) void {
        for (self.items.items) |*bp| bp.deinit(self.allocator);
        self.items.clearRetainingCapacity();
    }

    pub fn hasAt(self: *const Store, path: []const u8, line: usize) bool {
        for (self.items.items) |bp| {
            if (std.mem.eql(u8, bp.path, path) and bp.line == line) return true;
        }
        return false;
    }

    pub fn restoreAll(self: *Store, entries: []const Entry) !void {
        self.clear();
        for (entries) |entry| {
            try self.items.append(self.allocator, .{
                .path = try self.allocator.dupe(u8, entry.path),
                .line = entry.line,
            });
        }
    }
};
