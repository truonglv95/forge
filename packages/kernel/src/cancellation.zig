const std = @import("std");

pub const CancellationToken = struct {
    shared_state: *std.atomic.Value(bool),

    pub fn isCancelled(self: CancellationToken) bool {
        return self.shared_state.load(.acquire);
    }
};

pub const CancellationTokenSource = struct {
    allocator: std.mem.Allocator,
    shared_state: *std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator) !CancellationTokenSource {
        const state = try allocator.create(std.atomic.Value(bool));
        state.* = std.atomic.Value(bool).init(false);
        return CancellationTokenSource{
            .allocator = allocator,
            .shared_state = state,
        };
    }

    pub fn deinit(self: *CancellationTokenSource) void {
        self.allocator.destroy(self.shared_state);
    }

    pub fn cancel(self: *CancellationTokenSource) void {
        self.shared_state.store(true, .release);
    }

    pub fn getToken(self: CancellationTokenSource) CancellationToken {
        return CancellationToken{ .shared_state = self.shared_state };
    }
};

test "CancellationTokenSource cancels token" {
    var source = try CancellationTokenSource.init(std.testing.allocator);
    defer source.deinit();

    const token = source.getToken();
    try std.testing.expect(!token.isCancelled());

    source.cancel();
    try std.testing.expect(token.isCancelled());
}
