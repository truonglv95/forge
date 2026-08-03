//! Rate limiter for AI provider calls — prevents hitting API rate limits
//! when users spam prompts or completions.
const std = @import("std");
const c = @cImport({
    @cInclude("sys/time.h");
});

fn nowMs() i64 {
    var tv: c.timeval = undefined;
    _ = c.gettimeofday(&tv, null);
    return @as(i64, tv.tv_sec) * 1000 + @divFloor(@as(i64, tv.tv_usec), 1000);
}

pub const RateLimiter = struct {
    allocator: std.mem.Allocator,
    /// Minimum time between requests in milliseconds.
    min_interval_ms: u64 = 1000, // 1 second between agent prompts
    /// Maximum requests per minute (burst limit).
    max_requests_per_minute: u32 = 30,
    /// Timestamps of recent requests (epoch ms).
    recent_timestamps: std.ArrayList(i64),
    /// Last request timestamp (epoch ms).
    last_request_ms: i64 = 0,

    pub fn init(allocator: std.mem.Allocator) RateLimiter {
        return .{
            .allocator = allocator,
            .recent_timestamps = .empty,
        };
    }

    pub fn deinit(self: *RateLimiter) void {
        self.recent_timestamps.deinit(self.allocator);
    }

    /// Check if a request is allowed. Returns error if rate limited.
    pub fn check(self: *RateLimiter) !void {
        const now = nowMs();

        // Check min interval
        if (self.last_request_ms > 0 and @as(u64, @intCast(now - self.last_request_ms)) < self.min_interval_ms) {
            return error.RateLimited;
        }

        // Prune timestamps older than 60 seconds
        const cutoff = now - 60_000;
        var i: usize = 0;
        while (i < self.recent_timestamps.items.len) {
            if (self.recent_timestamps.items[i] < cutoff) {
                _ = self.recent_timestamps.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        // Check burst limit
        if (self.recent_timestamps.items.len >= self.max_requests_per_minute) {
            return error.RateLimited;
        }

        // Record this request
        try self.recent_timestamps.append(self.allocator, now);
        self.last_request_ms = now;
    }

    /// Get remaining requests in current minute.
    pub fn remaining(self: *const RateLimiter) u32 {
        const now = nowMs();
        const cutoff = now - 60_000;
        var count: u32 = 0;
        for (self.recent_timestamps.items) |ts| {
            if (ts >= cutoff) count += 1;
        }
        if (count >= self.max_requests_per_minute) return 0;
        return self.max_requests_per_minute - count;
    }

    /// Get milliseconds until next request is allowed.
    pub fn timeUntilNext(self: *const RateLimiter) u64 {
        if (self.last_request_ms == 0) return 0;
        const now = nowMs();
        const elapsed: u64 = @intCast(now - self.last_request_ms);
        if (elapsed >= self.min_interval_ms) return 0;
        return self.min_interval_ms - elapsed;
    }
};

test "RateLimiter allows first request" {
    const allocator = std.testing.allocator;
    var limiter = RateLimiter.init(allocator);
    defer limiter.deinit();
    try limiter.check();
}

test "RateLimiter blocks rapid second request" {
    const allocator = std.testing.allocator;
    var limiter = RateLimiter.init(allocator);
    defer limiter.deinit();
    limiter.min_interval_ms = 5000;
    try limiter.check();
    try std.testing.expectError(error.RateLimited, limiter.check());
}

test "RateLimiter remaining count" {
    const allocator = std.testing.allocator;
    var limiter = RateLimiter.init(allocator);
    defer limiter.deinit();
    limiter.max_requests_per_minute = 5;
    limiter.min_interval_ms = 0; // Disable interval for this test
    try limiter.check();
    try limiter.check();
    // remaining should be 3 (5 max - 2 used)
    try std.testing.expectEqual(@as(u32, 3), limiter.remaining());
}
