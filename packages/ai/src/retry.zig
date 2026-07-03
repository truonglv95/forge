const std = @import("std");
const kernel = @import("forge-kernel");

pub const RetryPolicy = struct {
    max_attempts: u32 = 3,
    base_delay_ms: u64 = 1000,
    max_delay_ms: u64 = 10000,
};

/// Calculates the next backoff delay using exponential backoff with full jitter.
pub fn nextDelay(policy: RetryPolicy, attempt: u32, prng: *std.Random.DefaultPrng) u64 {
    if (attempt == 0) return 0;

    const exp_delay = policy.base_delay_ms * (@as(u64, 1) << @intCast(std.math.min(attempt, 31)));
    const capped_delay = std.math.min(exp_delay, policy.max_delay_ms);

    return prng.random().intRangeAtMost(u64, 0, capped_delay);
}

test "nextDelay respects max_delay_ms" {
    const policy = RetryPolicy{ .base_delay_ms = 100, .max_delay_ms = 500 };
    var prng = std.Random.DefaultPrng.init(42);

    const delay = nextDelay(policy, 10, &prng);
    try std.testing.expect(delay <= 500);
}
