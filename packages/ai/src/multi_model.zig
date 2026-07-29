//! Multi-Model Orchestration — routes requests to the best model based
//! on intent, with fallback chains and parallel execution support.
//!
//! This enables the agent to use different models for different tasks:
//! - Reasoning/explanation → Gemini (large context, good reasoning)
//! - Code editing → Claude (excellent code generation)
//! - Fast lookup/search → Ollama local (low latency)
//! - Fallback → any available provider

const std = @import("std");
const provider = @import("provider.zig");

pub const ModelRole = enum {
    reasoning, // Explain, analyze, plan
    code_edit, // Write/edit code
    fast_lookup, // Quick queries, search
    review, // Code review, validation
    embedding, // Vector embeddings
};

pub const ModelEntry = struct {
    role: ModelRole,
    provider_name: []const u8,
    model_id: []const u8,
    priority: u8, // Lower = higher priority
};

/// Default model routing table. Users can override in settings.toml
/// under [ai.model_routing].
pub const default_routing = [_]ModelEntry{
    .{ .role = .reasoning, .provider_name = "gemini", .model_id = "gemini-2.5-pro", .priority = 0 },
    .{ .role = .reasoning, .provider_name = "openrouter", .model_id = "anthropic/claude-sonnet-4", .priority = 1 },
    .{ .role = .code_edit, .provider_name = "openrouter", .model_id = "anthropic/claude-sonnet-4", .priority = 0 },
    .{ .role = .code_edit, .provider_name = "gemini", .model_id = "gemini-2.5-pro", .priority = 1 },
    .{ .role = .fast_lookup, .provider_name = "ollama", .model_id = "qwen2.5-coder:7b", .priority = 0 },
    .{ .role = .fast_lookup, .provider_name = "gemini", .model_id = "gemini-2.0-flash", .priority = 1 },
    .{ .role = .review, .provider_name = "openrouter", .model_id = "anthropic/claude-sonnet-4", .priority = 0 },
    .{ .role = .review, .provider_name = "gemini", .model_id = "gemini-2.5-pro", .priority = 1 },
    .{ .role = .embedding, .provider_name = "ollama", .model_id = "nomic-embed-text", .priority = 0 },
    .{ .role = .embedding, .provider_name = "gemini", .model_id = "text-embedding-004", .priority = 1 },
};

/// Router selects the best model for a given role, with fallback.
pub const ModelRouter = struct {
    allocator: std.mem.Allocator,
    routing: []const ModelEntry,
    /// Available providers (populated from config). Key = provider name.
    available: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) ModelRouter {
        return .{
            .allocator = allocator,
            .routing = &default_routing,
            .available = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *ModelRouter) void {
        self.available.deinit();
    }

    /// Mark a provider as available (has credentials / is reachable).
    pub fn markAvailable(self: *ModelRouter, provider_name: []const u8) !void {
        try self.available.put(provider_name, {});
    }

    /// Select the best model for a role. Returns null if no model available.
    /// Tries models in priority order, skipping unavailable providers.
    pub fn selectModel(self: *const ModelRouter, role: ModelRole) ?ModelEntry {
        var best: ?ModelEntry = null;
        var best_priority: u8 = 255;

        for (self.routing) |entry| {
            if (entry.role != role) continue;
            if (!self.available.contains(entry.provider_name)) continue;
            if (entry.priority < best_priority) {
                best = entry;
                best_priority = entry.priority;
            }
        }

        // If no model for this role, fall back to any available model.
        if (best == null) {
            for (self.routing) |entry| {
                if (!self.available.contains(entry.provider_name)) continue;
                if (entry.priority < best_priority) {
                    best = entry;
                    best_priority = entry.priority;
                }
            }
        }

        return best;
    }

    /// Get fallback chain for a role — all available models in priority order.
    pub fn fallbackChain(self: *ModelRouter, role: ModelRole, allocator: std.mem.Allocator) ![]ModelEntry {
        var list: std.ArrayList(ModelEntry) = .empty;
        errdefer list.deinit(allocator);

        for (self.routing) |entry| {
            if (entry.role != role) continue;
            if (!self.available.contains(entry.provider_name)) continue;
            try list.append(allocator, entry);
        }

        // Sort by priority
        std.sort.block(ModelEntry, list.items, {}, struct {
            fn less(_: void, a: ModelEntry, b: ModelEntry) bool {
                return a.priority < b.priority;
            }
        }.less);

        return list.toOwnedSlice(allocator);
    }

    /// Classify intent to determine the best model role.
    /// Uses simple keyword matching — production would use the intent classifier.
    pub fn classifyIntent(prompt: []const u8) ModelRole {
        // Code editing signals
        if (std.mem.indexOf(u8, prompt, "edit") != null or
            std.mem.indexOf(u8, prompt, "write") != null or
            std.mem.indexOf(u8, prompt, "implement") != null or
            std.mem.indexOf(u8, prompt, "fix") != null or
            std.mem.indexOf(u8, prompt, "refactor") != null)
        {
            return .code_edit;
        }

        // Review signals
        if (std.mem.indexOf(u8, prompt, "review") != null or
            std.mem.indexOf(u8, prompt, "check") != null or
            std.mem.indexOf(u8, prompt, "validate") != null or
            std.mem.indexOf(u8, prompt, "test") != null)
        {
            return .review;
        }

        // Fast lookup signals
        if (std.mem.indexOf(u8, prompt, "find") != null or
            std.mem.indexOf(u8, prompt, "search") != null or
            std.mem.indexOf(u8, prompt, "where") != null or
            prompt.len < 50)
        {
            return .fast_lookup;
        }

        // Default: reasoning
        return .reasoning;
    }
};

/// Execution result from a model — used for fallback decisions.
pub const ExecutionResult = struct {
    success: bool,
    response: []const u8,
    error_msg: ?[]const u8 = null,
    model_used: ?ModelEntry = null,
    latency_ms: u64 = 0,
};

test "ModelRouter selects available model" {
    var router = ModelRouter.init(std.testing.allocator);
    defer router.deinit();
    try router.markAvailable("ollama");
    try router.markAvailable("gemini");

    const model = router.selectModel(.reasoning);
    try std.testing.expect(model != null);
    try std.testing.expectEqualStrings("gemini", model.?.provider_name);
}

test "ModelRouter falls back when primary unavailable" {
    var router = ModelRouter.init(std.testing.allocator);
    defer router.deinit();
    // Only ollama available — gemini not marked
    try router.markAvailable("ollama");

    const model = router.selectModel(.reasoning);
    try std.testing.expect(model != null);
    // Should fall back to ollama since gemini is unavailable
    try std.testing.expectEqualStrings("ollama", model.?.provider_name);
}

test "classifyIntent detects code editing" {
    try std.testing.expectEqual(ModelRole.code_edit, ModelRouter.classifyIntent("edit the main function"));
    try std.testing.expectEqual(ModelRole.code_edit, ModelRouter.classifyIntent("implement user authentication"));
    try std.testing.expectEqual(ModelRole.review, ModelRouter.classifyIntent("review this code"));
    try std.testing.expectEqual(ModelRole.fast_lookup, ModelRouter.classifyIntent("find all TODOs"));
    try std.testing.expectEqual(ModelRole.fast_lookup, ModelRouter.classifyIntent("explain how the rendering pipeline works"));
}
