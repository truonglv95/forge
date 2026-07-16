//! Notification system — toast notifications for transient messages.
//!
//! Used for: file saved, agent started/finished, errors, info messages.
//! Notifications appear in the bottom-right corner and auto-dismiss
//! after a timeout (configurable per notification).

const std = @import("std");

pub const Level = enum {
    info,
    success,
    warning,
    err,

    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .info => "Info",
            .success => "Success",
            .warning => "Warning",
            .err => "Error",
        };
    }
};

pub const Notification = struct {
    id: u32,
    level: Level,
    title: []const u8,
    message: []const u8,
    /// Remaining display time in seconds. Decremented by tick().
    remaining: f32,
    /// Whether this notification is being faded out.
    fading: bool = false,

    pub fn deinit(self: *Notification, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Notification),
    next_id: u32 = 1,
    /// Maximum number of simultaneous notifications.
    max_visible: usize = 4,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{
            .allocator = allocator,
            .items = .empty,
        };
    }

    pub fn deinit(self: *Store) void {
        for (self.items.items) |*n| n.deinit(self.allocator);
        self.items.deinit(self.allocator);
    }

    /// Show a notification. `title` and `message` are duped.
    pub fn show(self: *Store, level: Level, title: []const u8, message: []const u8, duration_s: f32) !u32 {
        const id = self.next_id;
        self.next_id += 1;

        const title_owned = try self.allocator.dupe(u8, title);
        errdefer self.allocator.free(title_owned);
        const message_owned = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(message_owned);

        try self.items.append(self.allocator, .{
            .id = id,
            .level = level,
            .title = title_owned,
            .message = message_owned,
            .remaining = duration_s,
        });

        // Trim oldest if exceeding max_visible.
        while (self.items.items.len > self.max_visible) {
            var removed = self.items.orderedRemove(0);
            removed.deinit(self.allocator);
        }
        return id;
    }

    /// Convenience: show an info notification (3s default).
    pub fn info(self: *Store, message: []const u8) !u32 {
        return self.show(.info, "Info", message, 3.0);
    }

    /// Convenience: show a success notification (2.5s default).
    pub fn success(self: *Store, message: []const u8) !u32 {
        return self.show(.success, "Success", message, 2.5);
    }

    /// Convenience: show an error notification (5s default — longer for errors).
    pub fn err(self: *Store, message: []const u8) !u32 {
        return self.show(.err, "Error", message, 5.0);
    }

    /// Convenience: show a warning notification (4s default).
    pub fn warning(self: *Store, message: []const u8) !u32 {
        return self.show(.warning, "Warning", message, 4.0);
    }

    /// Dismiss a notification by ID.
    pub fn dismiss(self: *Store, id: u32) void {
        for (self.items.items, 0..) |n, i| {
            if (n.id == id) {
                var removed = self.items.orderedRemove(i);
                removed.deinit(self.allocator);
                return;
            }
        }
    }

    /// Dismiss all notifications.
    pub fn dismissAll(self: *Store) void {
        for (self.items.items) |*n| n.deinit(self.allocator);
        self.items.clearRetainingCapacity();
    }

    /// Tick the timer. Notifications whose time has expired are removed.
    pub fn tick(self: *Store, dt: f32) void {
        var i: usize = 0;
        while (i < self.items.items.len) {
            self.items.items[i].remaining -= dt;
            if (self.items.items[i].remaining <= 0) {
                var removed = self.items.orderedRemove(i);
                removed.deinit(self.allocator);
            } else {
                i += 1;
            }
        }
    }
};

test "Store show and dismiss" {
    const allocator = std.testing.allocator;
    var s = Store.init(allocator);
    defer s.deinit();

    const id1 = try s.info("hello");
    try std.testing.expectEqual(@as(usize, 1), s.items.items.len);
    try std.testing.expectEqualStrings("hello", s.items.items[0].message);

    s.dismiss(id1);
    try std.testing.expectEqual(@as(usize, 0), s.items.items.len);
}

test "Store tick expires notifications" {
    const allocator = std.testing.allocator;
    var s = Store.init(allocator);
    defer s.deinit();

    _ = try s.show(.info, "T", "msg", 1.0);
    s.tick(0.5);
    try std.testing.expectEqual(@as(usize, 1), s.items.items.len);
    s.tick(0.6);
    try std.testing.expectEqual(@as(usize, 0), s.items.items.len);
}

test "Store max_visible trims oldest" {
    const allocator = std.testing.allocator;
    var s = Store.init(allocator);
    defer s.deinit();
    s.max_visible = 2;

    _ = try s.info("a");
    _ = try s.info("b");
    _ = try s.info("c");
    try std.testing.expectEqual(@as(usize, 2), s.items.items.len);
    // Oldest ("a") should be removed; "b" and "c" remain.
    try std.testing.expectEqualStrings("b", s.items.items[0].message);
    try std.testing.expectEqualStrings("c", s.items.items[1].message);
}

test "Store convenience methods set level" {
    const allocator = std.testing.allocator;
    var s = Store.init(allocator);
    defer s.deinit();

    _ = try s.success("ok");
    _ = try s.warning("warn");
    _ = try s.err("bad");
    try std.testing.expectEqual(Level.success, s.items.items[0].level);
    try std.testing.expectEqual(Level.warning, s.items.items[1].level);
    try std.testing.expectEqual(Level.err, s.items.items[2].level);
}
