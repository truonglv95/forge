//! Watch expressions — user-defined expressions evaluated by the DAP
//! debugger at each stop. Stored in a list, evaluated via the `evaluate`
//! DAP request when the debug session is stopped.
//!
//! Users add watch expressions via the debug panel (e.g. `my_var.length`,
//! `items[0]`, `count + 1`). The expressions are evaluated on each stop
//! and the results displayed in the variables panel.

const std = @import("std");

pub const WatchEntry = struct {
    /// The expression text (owned).
    expression: []const u8,
    /// Last evaluated result (owned, null if not yet evaluated).
    result: ?[]const u8 = null,
    /// Whether the last evaluation succeeded.
    ok: bool = true,
    /// Whether this entry is currently being edited.
    editing: bool = false,

    pub fn deinit(self: *WatchEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.expression);
        if (self.result) |r| allocator.free(r);
        self.* = undefined;
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(WatchEntry),

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{
            .allocator = allocator,
            .items = .empty,
        };
    }

    pub fn deinit(self: *Store) void {
        self.clear();
        self.items.deinit(self.allocator);
    }

    pub fn clear(self: *Store) void {
        for (self.items.items) |*entry| entry.deinit(self.allocator);
        self.items.clearRetainingCapacity();
    }

    /// Add a watch expression. Returns the index.
    pub fn add(self: *Store, expression: []const u8) !usize {
        const owned = try self.allocator.dupe(u8, expression);
        errdefer self.allocator.free(owned);
        try self.items.append(self.allocator, .{
            .expression = owned,
        });
        return self.items.items.len - 1;
    }

    /// Remove a watch expression by index.
    pub fn remove(self: *Store, index: usize) void {
        if (index >= self.items.items.len) return;
        var removed = self.items.orderedRemove(index);
        removed.deinit(self.allocator);
    }

    /// Update the result of a watch expression (called after DAP evaluate).
    pub fn setResult(self: *Store, index: usize, result: []const u8, ok: bool) void {
        if (index >= self.items.items.len) return;
        const entry = &self.items.items[index];
        if (entry.result) |r| self.allocator.free(r);
        entry.result = self.allocator.dupe(u8, result) catch null;
        entry.ok = ok;
    }

    /// Clear all results (e.g. when debug session ends).
    pub fn clearResults(self: *Store) void {
        for (self.items.items) |*entry| {
            if (entry.result) |r| self.allocator.free(r);
            entry.result = null;
            entry.ok = true;
        }
    }

    pub fn count(self: *const Store) usize {
        return self.items.items.len;
    }

    pub fn get(self: *const Store, index: usize) ?WatchEntry {
        if (index >= self.items.items.len) return null;
        return self.items.items[index];
    }
};

test "Store add and remove" {
    const allocator = std.testing.allocator;
    var s = Store.init(allocator);
    defer s.deinit();

    const idx = try s.add("my_var");
    try std.testing.expectEqual(@as(usize, 0), idx);
    try std.testing.expectEqual(@as(usize, 1), s.count());
    try std.testing.expectEqualStrings("my_var", s.get(0).?.expression);

    s.remove(0);
    try std.testing.expectEqual(@as(usize, 0), s.count());
}

test "Store setResult updates entry" {
    const allocator = std.testing.allocator;
    var s = Store.init(allocator);
    defer s.deinit();

    _ = try s.add("count + 1");
    s.setResult(0, "42", true);
    try std.testing.expectEqualStrings("42", s.get(0).?.result.?);
    try std.testing.expect(s.get(0).?.ok);
}

test "Store clearResults frees results" {
    const allocator = std.testing.allocator;
    var s = Store.init(allocator);
    defer s.deinit();

    _ = try s.add("x");
    s.setResult(0, "10", true);
    try std.testing.expect(s.get(0).?.result != null);

    s.clearResults();
    try std.testing.expect(s.get(0).?.result == null);
}
