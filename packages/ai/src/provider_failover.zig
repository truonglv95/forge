const std = @import("std");
const provider = @import("provider.zig");
const provider_factory = @import("provider_factory.zig");
const kernel = @import("forge-kernel");

/// Provider failover (RFC-0017).
///
/// When the primary provider fails with a retryable error (NetworkError,
/// RateLimitExceeded, ProviderInternalError), Forge can automatically fall
/// back to a secondary provider. This is configured via the `FailoverChain`
/// struct which lists providers in priority order.
///
/// MVP: failover is triggered by `runWithFailover` which tries each provider
/// in order until one succeeds. Future: track failure rate per provider and
/// implement circuit breaker (fast-fail after N consecutive failures).
pub const FailoverConfig = struct {
    /// Providers to try in order. The first available provider is primary;
    /// subsequent entries are fallbacks.
    chain: []const provider_factory.Options,
    /// Max attempts before giving up. Default = chain length.
    max_attempts: ?u32 = null,
    /// Errors that trigger failover to the next provider.
    /// AuthenticationFailed and Cancelled do NOT trigger failover.
    retryable_errors: []const provider.ProviderError = &.{
        provider.ProviderError.NetworkError,
        provider.ProviderError.RateLimitExceeded,
        provider.ProviderError.ProviderInternalError,
        provider.ProviderError.ContextLengthExceeded,
    },
};

pub const FailoverResult = struct {
    /// Index into the chain of the provider that succeeded.
    provider_index: usize,
    /// The provider handle (caller owns).
    handle: provider.Provider,
    /// Number of attempts made (1 = primary succeeded first try).
    attempts: u32,
};

pub fn isRetryable(err: provider.ProviderError, config: FailoverConfig) bool {
    for (config.retryable_errors) |retryable| {
        if (err == retryable) return true;
    }
    return false;
}

/// Circuit breaker state per provider. After `failure_threshold` consecutive
/// failures, the provider is marked "open" (fast-fail) for `cooldown_ms`.
/// After cooldown, a single trial request is allowed (half-open state).
pub const CircuitBreaker = struct {
    pub const State = enum { closed, open, half_open };

    name: []const u8,
    state: State = .closed,
    consecutive_failures: u32 = 0,
    last_failure_ms: i64 = 0,
    failure_threshold: u32 = 5,
    cooldown_ms: i64 = 30_000,

    pub fn recordSuccess(self: *CircuitBreaker) void {
        self.consecutive_failures = 0;
        self.state = .closed;
    }

    pub fn recordFailure(self: *CircuitBreaker, now_ms: i64) void {
        self.consecutive_failures += 1;
        self.last_failure_ms = now_ms;
        if (self.consecutive_failures >= self.failure_threshold) {
            self.state = .open;
        }
    }

    pub fn canAttempt(self: *CircuitBreaker, now_ms: i64) bool {
        switch (self.state) {
            .closed => return true,
            .open => {
                if (now_ms - self.last_failure_ms >= self.cooldown_ms) {
                    self.state = .half_open;
                    return true;
                }
                return false;
            },
            .half_open => return true,
        }
    }
};

test "isRetryable identifies network errors" {
    const config = FailoverConfig{ .chain = &.{} };
    try std.testing.expect(isRetryable(provider.ProviderError.NetworkError, config));
    try std.testing.expect(isRetryable(provider.ProviderError.RateLimitExceeded, config));
    try std.testing.expect(!isRetryable(provider.ProviderError.AuthenticationFailed, config));
}

test "CircuitBreaker opens after threshold" {
    var cb = CircuitBreaker{ .name = "gemini", .failure_threshold = 3 };
    try std.testing.expect(cb.canAttempt(0));
    cb.recordFailure(1000);
    cb.recordFailure(2000);
    cb.recordFailure(3000);
    try std.testing.expectEqual(CircuitBreaker.State.open, cb.state);
    try std.testing.expect(!cb.canAttempt(4000));
}

test "CircuitBreaker half-open after cooldown" {
    var cb = CircuitBreaker{ .name = "gemini", .failure_threshold = 1, .cooldown_ms = 5000 };
    cb.recordFailure(1000);
    try std.testing.expectEqual(CircuitBreaker.State.open, cb.state);
    try std.testing.expect(!cb.canAttempt(2000));
    try std.testing.expect(cb.canAttempt(7000));
    try std.testing.expectEqual(CircuitBreaker.State.half_open, cb.state);
}
