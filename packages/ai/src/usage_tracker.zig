const std = @import("std");
const provider = @import("provider.zig");

/// Cumulative token usage tracker (RFC-0018).
///
/// Providers currently only report `latest_usage` (the last request's tokens).
/// This module accumulates usage across all requests in a session so the
/// caller can report total tokens consumed and estimate cost.
///
/// Cost estimation uses a simple per-1K-token pricing table. Prices are
/// approximate and should be updated from provider docs periodically.
pub const UsageTracker = struct {
    allocator: std.mem.Allocator,
    total: provider.TokenUsage = .{},
    /// Per-request log for detailed analysis. Capped at 256 entries.
    entries: std.ArrayList(Entry) = .empty,
    /// Pricing table: provider_name → price per 1K tokens (USD).
    /// Updated 2026-07. Source: official provider pricing pages.
    pricing: PricingTable = .{},

    pub const Entry = struct {
        provider_name: []const u8,
        model_name: []const u8,
        prompt_tokens: u64,
        completion_tokens: u64,
        timestamp_ms: i64,
    };

    pub fn init(allocator: std.mem.Allocator) UsageTracker {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *UsageTracker) void {
        for (self.entries.items) |e| {
            self.allocator.free(e.provider_name);
            self.allocator.free(e.model_name);
        }
        self.entries.deinit(self.allocator);
    }

    /// Record a single provider call's token usage.
    pub fn record(
        self: *UsageTracker,
        provider_name: []const u8,
        model_name: []const u8,
        usage: provider.TokenUsage,
        timestamp_ms: i64,
    ) !void {
        self.total.prompt_tokens += usage.prompt_tokens;
        self.total.completion_tokens += usage.completion_tokens;
        self.total.total_tokens += usage.total_tokens;

        // Cap entries at 256 to bound memory.
        if (self.entries.items.len >= 256) {
            const oldest = self.entries.orderedRemove(0);
            self.allocator.free(oldest.provider_name);
            self.allocator.free(oldest.model_name);
        }

        try self.entries.append(self.allocator, .{
            .provider_name = try self.allocator.dupe(u8, provider_name),
            .model_name = try self.allocator.dupe(u8, model_name),
            .prompt_tokens = usage.prompt_tokens,
            .completion_tokens = usage.completion_tokens,
            .timestamp_ms = timestamp_ms,
        });
    }

    /// Estimate total cost in USD based on the pricing table.
    pub fn estimatedCostUsd(self: *const UsageTracker, provider_name: []const u8, model_name: []const u8) f64 {
        const price = self.pricing.lookup(provider_name, model_name);
        const prompt_cost = @as(f64, @floatFromInt(self.total.prompt_tokens)) / 1000.0 * price.input_per_1k;
        const completion_cost = @as(f64, @floatFromInt(self.total.completion_tokens)) / 1000.0 * price.output_per_1k;
        return prompt_cost + completion_cost;
    }
};

pub const PricePer1K = struct {
    input_per_1k: f64,
    output_per_1k: f64,
};

pub const PricingTable = struct {
    /// Approximate pricing as of 2026-07. Update from provider docs.
    /// Format: "provider/model_prefix" → price.
    /// Model matching is prefix-based: "gemini/gemini-2.0-flash" matches
    /// any model starting with "gemini-2.0-flash".
    fn lookup(self: PricingTable, provider_name: []const u8, model_name: []const u8) PricePer1K {
        _ = self;
        // Gemini
        if (std.mem.eql(u8, provider_name, "gemini")) {
            if (std.mem.startsWith(u8, model_name, "gemini-2.0-flash")) return .{ .input_per_1k = 0.10, .output_per_1k = 0.40 };
            if (std.mem.startsWith(u8, model_name, "gemini-1.5-flash")) return .{ .input_per_1k = 0.075, .output_per_1k = 0.30 };
            if (std.mem.startsWith(u8, model_name, "gemini-1.5-pro")) return .{ .input_per_1k = 1.25, .output_per_1k = 5.00 };
            return .{ .input_per_1k = 0.50, .output_per_1k = 1.50 }; // default gemini
        }
        // OpenAI
        if (std.mem.eql(u8, provider_name, "openai")) {
            if (std.mem.startsWith(u8, model_name, "gpt-4o-mini")) return .{ .input_per_1k = 0.150, .output_per_1k = 0.600 };
            if (std.mem.startsWith(u8, model_name, "gpt-4o")) return .{ .input_per_1k = 2.50, .output_per_1k = 10.00 };
            if (std.mem.startsWith(u8, model_name, "gpt-4-turbo")) return .{ .input_per_1k = 10.00, .output_per_1k = 30.00 };
            return .{ .input_per_1k = 1.00, .output_per_1k = 3.00 }; // default openai
        }
        // OpenRouter (varies by model; use conservative default)
        if (std.mem.eql(u8, provider_name, "openrouter")) {
            return .{ .input_per_1k = 1.00, .output_per_1k = 3.00 };
        }
        // NVIDIA (varies)
        if (std.mem.eql(u8, provider_name, "nvidia")) {
            return .{ .input_per_1k = 0.50, .output_per_1k = 1.50 };
        }
        // Ollama (local, free)
        if (std.mem.eql(u8, provider_name, "ollama")) {
            return .{ .input_per_1k = 0.0, .output_per_1k = 0.0 };
        }
        // Fake (testing)
        return .{ .input_per_1k = 0.0, .output_per_1k = 0.0 };
    }
};

test "UsageTracker accumulates tokens" {
    const allocator = std.testing.allocator;
    var tracker = UsageTracker.init(allocator);
    defer tracker.deinit();

    try tracker.record("gemini", "gemini-2.0-flash", .{ .prompt_tokens = 100, .completion_tokens = 50, .total_tokens = 150 }, 1000);
    try tracker.record("gemini", "gemini-2.0-flash", .{ .prompt_tokens = 200, .completion_tokens = 100, .total_tokens = 300 }, 2000);

    try std.testing.expectEqual(@as(u64, 300), tracker.total.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 150), tracker.total.completion_tokens);
    try std.testing.expectEqual(@as(u64, 450), tracker.total.total_tokens);
    try std.testing.expectEqual(@as(usize, 2), tracker.entries.items.len);
}

test "estimatedCostUsd calculates gemini flash price" {
    const allocator = std.testing.allocator;
    var tracker = UsageTracker.init(allocator);
    defer tracker.deinit();

    try tracker.record("gemini", "gemini-2.0-flash", .{ .prompt_tokens = 1000, .completion_tokens = 500, .total_tokens = 1500 }, 0);

    // Input: 1000/1000 * 0.10 = 0.10
    // Output: 500/1000 * 0.40 = 0.20
    // Total: 0.30
    const cost = tracker.estimatedCostUsd("gemini", "gemini-2.0-flash");
    try std.testing.expectApproxEqAbs(@as(f64, 0.30), cost, 0.001);
}

test "estimatedCostUsd returns 0 for ollama" {
    const allocator = std.testing.allocator;
    var tracker = UsageTracker.init(allocator);
    defer tracker.deinit();

    try tracker.record("ollama", "qwen2.5:35b", .{ .prompt_tokens = 10000, .completion_tokens = 5000, .total_tokens = 15000 }, 0);

    const cost = tracker.estimatedCostUsd("ollama", "qwen2.5:35b");
    try std.testing.expectEqual(@as(f64, 0.0), cost);
}
