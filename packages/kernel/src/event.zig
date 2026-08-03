const std = @import("std");

/// A small typed event bus for facts that have already occurred.
///
/// The bus owns its subscription list. Event payload ownership remains with the
/// publisher and callbacks may use it only for the duration of `publish`.
pub fn EventBus(comptime Event: type) type {
    return struct {
        const Self = @This();
        const Callback = *const fn (context: ?*anyopaque, event: Event) void;

        const Subscription = struct {
            id: u64,
            context: ?*anyopaque,
            callback: Callback,
        };

        pub const Token = struct { id: u64 };

        allocator: std.mem.Allocator,
        subscriptions: std.ArrayList(Subscription) = .empty,
        next_id: u64 = 1,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.subscriptions.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn subscribe(self: *Self, context: ?*anyopaque, callback: Callback) !Token {
            const token = Token{ .id = self.next_id };
            try self.subscriptions.append(self.allocator, .{
                .id = token.id,
                .context = context,
                .callback = callback,
            });
            self.next_id +|= 1;
            return token;
        }

        pub fn unsubscribe(self: *Self, token: Token) bool {
            for (self.subscriptions.items, 0..) |subscription, index| {
                if (subscription.id == token.id) {
                    _ = self.subscriptions.swapRemove(index);
                    return true;
                }
            }
            return false;
        }

        pub fn publish(self: *Self, event: Event) !void {
            const snapshot = try self.allocator.dupe(Subscription, self.subscriptions.items);
            defer self.allocator.free(snapshot);
            for (snapshot) |subscription| {
                subscription.callback(subscription.context, event);
            }
        }
    };
}

test "event bus publishes typed facts and supports unsubscribe" {
    const Event = union(enum) { opened: u32, closed };
    const Counter = struct {
        value: u32 = 0,

        fn receive(raw_context: ?*anyopaque, event: Event) void {
            const self: *@This() = @ptrCast(@alignCast(raw_context.?));
            switch (event) {
                .opened => |count| self.value += count,
                .closed => self.value += 1,
            }
        }
    };

    var bus = EventBus(Event).init(std.testing.allocator);
    defer bus.deinit();
    var counter = Counter{};
    const token = try bus.subscribe(&counter, Counter.receive);
    try bus.publish(.{ .opened = 2 });
    try std.testing.expectEqual(@as(u32, 2), counter.value);
    try std.testing.expect(bus.unsubscribe(token));
    try bus.publish(.closed);
    try std.testing.expectEqual(@as(u32, 2), counter.value);
}
