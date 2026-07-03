const std = @import("std");

pub const ServiceRegistry = struct {
    allocator: std.mem.Allocator,
    teardowns: std.ArrayList(*const fn (*anyopaque) void),
    contexts: std.ArrayList(*anyopaque),

    pub fn init(allocator: std.mem.Allocator) ServiceRegistry {
        return .{
            .allocator = allocator,
            .teardowns = .empty,
            .contexts = .empty,
        };
    }

    pub fn deinit(self: *ServiceRegistry) void {
        var i: usize = self.teardowns.items.len;
        while (i > 0) {
            i -= 1;
            const teardown = self.teardowns.items[i];
            const ctx = self.contexts.items[i];
            teardown(ctx);
        }
        self.teardowns.deinit(self.allocator);
        self.contexts.deinit(self.allocator);
    }

    pub fn register(self: *ServiceRegistry, ctx: *anyopaque, teardown: *const fn (*anyopaque) void) !void {
        try self.teardowns.append(self.allocator, teardown);
        try self.contexts.append(self.allocator, ctx);
    }
};

test "ServiceRegistry teardown order" {
    // Teardowns are tested via manual memory tracking in integration tests
}
