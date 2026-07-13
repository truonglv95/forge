const std = @import("std");

/// LSP cancel request support ($/cancelRequest).
///
/// When the user types quickly, multiple completion/hover requests may be
/// in flight. The LSP spec allows canceling a pending request by sending
/// a `$/cancelRequest` notification with the request ID.
///
/// This module provides:
/// - A CancelTracker that tracks in-flight request IDs
/// - buildCancelNotification() to produce the JSON-RPC notification
/// - Integration point: the LSP proxy can check isCancelled() before
///   delivering the response to a stale request.
pub const CancelTracker = struct {
    allocator: std.mem.Allocator,
    /// Set of cancelled request IDs. When a response arrives, check
    /// if its ID is in this set — if so, discard the response.
    cancelled: std.AutoHashMap(i32, void),

    pub fn init(allocator: std.mem.Allocator) CancelTracker {
        return .{
            .allocator = allocator,
            .cancelled = std.AutoHashMap(i32, void).init(allocator),
        };
    }

    pub fn deinit(self: *CancelTracker) void {
        self.cancelled.deinit();
    }

    /// Mark a request as cancelled. The response will be discarded.
    pub fn cancel(self: *CancelTracker, request_id: i32) !void {
        try self.cancelled.put(request_id, {});
    }

    /// Check if a request was cancelled. Removes the ID from the set
    /// (cancel is one-shot: once we've seen the response, the cancel
    /// is consumed).
    pub fn isCancelled(self: *CancelTracker, request_id: i32) bool {
        return self.cancelled.fetchRemove(request_id) != null;
    }

    /// Clear all cancelled requests.
    pub fn clear(self: *CancelTracker) void {
        self.cancelled.clearRetainingCapacity();
    }

    /// Count of pending cancels.
    pub fn count(self: *const CancelTracker) usize {
        return self.cancelled.count();
    }
};

/// Build a `$/cancelRequest` JSON-RPC notification.
/// Returns owned slice (caller frees).
pub fn buildCancelNotification(allocator: std.mem.Allocator, request_id: i32) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","method":"$/cancelRequest","params":{{"id":{d}}}}}
    , .{request_id});
}

test "CancelTracker tracks and consumes cancels" {
    const allocator = std.testing.allocator;
    var tracker = CancelTracker.init(allocator);
    defer tracker.deinit();

    try tracker.cancel(5);
    try tracker.cancel(10);
    try std.testing.expectEqual(@as(usize, 2), tracker.count());

    // isCancelled is one-shot: it removes the entry.
    try std.testing.expect(tracker.isCancelled(5));
    try std.testing.expect(!tracker.isCancelled(5)); // already consumed
    try std.testing.expect(!tracker.isCancelled(999)); // never cancelled

    try std.testing.expectEqual(@as(usize, 1), tracker.count());
}

test "buildCancelNotification produces valid JSON-RPC" {
    const allocator = std.testing.allocator;
    const msg = try buildCancelNotification(allocator, 42);
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"method\":\"$/cancelRequest\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"id\":42") != null);
}

test "CancelTracker clear removes all entries" {
    const allocator = std.testing.allocator;
    var tracker = CancelTracker.init(allocator);
    defer tracker.deinit();

    try tracker.cancel(1);
    try tracker.cancel(2);
    try tracker.cancel(3);
    tracker.clear();
    try std.testing.expectEqual(@as(usize, 0), tracker.count());
}
