const std = @import("std");

pub const Entry = struct {
    path: []const u8,
    tab_index: usize,
};

pub const History = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry),
    index: usize = 0,
    suppress: bool = false,

    pub fn init(allocator: std.mem.Allocator) History {
        return .{ .allocator = allocator, .entries = .empty };
    }

    pub fn deinit(self: *History) void {
        for (self.entries.items) |entry| self.allocator.free(entry.path);
        self.entries.deinit(self.allocator);
    }

    pub fn canGoBack(self: *const History) bool {
        return self.index > 0;
    }

    pub fn canGoForward(self: *const History) bool {
        return self.index + 1 < self.entries.items.len;
    }

    pub fn record(self: *History, path: []const u8, tab_index: usize) !void {
        if (self.suppress) return;
        if (self.entries.items.len > 0 and self.index < self.entries.items.len) {
            const current = self.entries.items[self.index];
            if (std.mem.eql(u8, current.path, path) and current.tab_index == tab_index) return;
        }

        while (self.entries.items.len > self.index + 1) {
            const removed = self.entries.pop() orelse break;
            self.allocator.free(removed.path);
        }

        const owned = try self.allocator.dupe(u8, path);
        try self.entries.append(self.allocator, .{ .path = owned, .tab_index = tab_index });
        self.index = self.entries.items.len - 1;

        if (self.entries.items.len > 64) {
            const old = self.entries.orderedRemove(0);
            self.allocator.free(old.path);
            self.index -= 1;
        }
    }

    pub fn back(self: *History) ?Entry {
        if (!self.canGoBack()) return null;
        self.index -= 1;
        return self.entries.items[self.index];
    }

    pub fn forward(self: *History) ?Entry {
        if (!self.canGoForward()) return null;
        self.index += 1;
        return self.entries.items[self.index];
    }
};
