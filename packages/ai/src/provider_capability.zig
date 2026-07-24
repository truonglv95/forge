//! Provider capability metadata and smart model router.
//!
//! RFC-0016: Expose static capability metadata for built-in providers and
//! models so the agent loop, CLI, and IDE can make informed routing decisions.
//! The metadata is static (manually maintained) because provider APIs don't
//! expose capability introspection; update via PRs when models change.

const std = @import("std");

/// Capability of a provider or model, used for routing and display.
pub const ProviderCapability = struct {
    /// Maximum context window in tokens.
    max_context_tokens: u32,

    /// Provider supports native tool calling (function declarations).
    supports_tools: bool,

    /// Provider supports streaming responses.
    supports_streaming: bool,

    /// Provider supports structured output (JSON schema).
    supports_structured_output: bool,

    /// Provider returns token usage in response.
    returns_usage: bool,

    /// Provider returns finish_reason.
    returns_finish_reason: bool,

    /// Price per 1M input tokens in USD cents (100 = $1).
    price_per_mtok_input: u32,

    /// Price per 1M output tokens in USD cents.
    price_per_mtok_output: u32,

    /// Provider-specific notes (e.g., "requires API key", "local only").
    notes: []const u8 = "",
};

/// Retry policy for a provider.
pub const RetryPolicy = struct {
    max_attempts: u8 = 3,
    base_delay_ms: u32 = 1000,
    max_delay_ms: u32 = 30000,
    jitter: bool = true,
};

/// A model entry in the built-in capability table.
pub const ModelCapability = struct {
    provider: []const u8,
    model_id: []const u8,
    display_name: []const u8,
    capability: ProviderCapability,
    /// Task types this model excels at: "code_edit", "code_review",
    /// "planning", "completion", "embedding", "agentic".
    strengths: []const []const u8,
    /// Context window actually usable (after system prompt + tool defs).
    effective_context_tokens: u32,
};

/// Built-in model capability table. Update via PR when providers add models.
pub const builtin_models = [_]ModelCapability{
    // Gemini
    .{
        .provider = "gemini",
        .model_id = "gemini-2.5-pro",
        .display_name = "Gemini 2.5 Pro",
        .capability = .{
            .max_context_tokens = 2_000_000,
            .supports_tools = true,
            .supports_streaming = true,
            .supports_structured_output = true,
            .returns_usage = true,
            .returns_finish_reason = true,
            .price_per_mtok_input = 125,
            .price_per_mtok_output = 500,
            .notes = "Best for long context, multimodal",
        },
        .strengths = &.{ "code_edit", "planning", "code_review" },
        .effective_context_tokens = 1_800_000,
    },
    .{
        .provider = "gemini",
        .model_id = "gemini-2.5-flash",
        .display_name = "Gemini 2.5 Flash",
        .capability = .{
            .max_context_tokens = 1_000_000,
            .supports_tools = true,
            .supports_streaming = true,
            .supports_structured_output = true,
            .returns_usage = true,
            .returns_finish_reason = true,
            .price_per_mtok_input = 8,
            .price_per_mtok_output = 30,
            .notes = "Fast, cheap, good for inline completion",
        },
        .strengths = &.{ "completion", "code_edit" },
        .effective_context_tokens = 900_000,
    },
    // OpenRouter (multi-model gateway)
    .{
        .provider = "openrouter",
        .model_id = "auto",
        .display_name = "OpenRouter Auto",
        .capability = .{
            .max_context_tokens = 128_000,
            .supports_tools = true,
            .supports_streaming = true,
            .supports_structured_output = true,
            .returns_usage = true,
            .returns_finish_reason = true,
            .price_per_mtok_input = 100,
            .price_per_mtok_output = 300,
            .notes = "Gateway, route to cheapest model",
        },
        .strengths = &.{ "code_edit", "completion" },
        .effective_context_tokens = 120_000,
    },
    // OpenAI-compatible
    .{
        .provider = "openai",
        .model_id = "gpt-4o",
        .display_name = "GPT-4o",
        .capability = .{
            .max_context_tokens = 128_000,
            .supports_tools = true,
            .supports_streaming = true,
            .supports_structured_output = true,
            .returns_usage = true,
            .returns_finish_reason = true,
            .price_per_mtok_input = 250,
            .price_per_mtok_output = 1000,
            .notes = "OpenAI-compatible endpoints",
        },
        .strengths = &.{ "code_edit", "planning", "code_review" },
        .effective_context_tokens = 120_000,
    },
    // NVIDIA NIM
    .{
        .provider = "nvidia",
        .model_id = "meta/llama-3.3-70b-instruct",
        .display_name = "Llama 3.3 70B (NIM)",
        .capability = .{
            .max_context_tokens = 128_000,
            .supports_tools = true,
            .supports_streaming = true,
            .supports_structured_output = false,
            .returns_usage = true,
            .returns_finish_reason = true,
            .price_per_mtok_input = 80,
            .price_per_mtok_output = 160,
            .notes = "NVIDIA NIM endpoints",
        },
        .strengths = &.{ "code_edit", "completion" },
        .effective_context_tokens = 120_000,
    },
    // Ollama (local)
    .{
        .provider = "ollama",
        .model_id = "qwen2.5-coder:14b",
        .display_name = "Qwen 2.5 Coder 14B (local)",
        .capability = .{
            .max_context_tokens = 32_000,
            .supports_tools = true,
            .supports_streaming = true,
            .supports_structured_output = false,
            .returns_usage = false,
            .returns_finish_reason = false,
            .price_per_mtok_input = 0,
            .price_per_mtok_output = 0,
            .notes = "Local, private, slow but free",
        },
        .strengths = &.{ "completion", "code_edit" },
        .effective_context_tokens = 28_000,
    },
    .{
        .provider = "ollama",
        .model_id = "llama3.3:70b",
        .display_name = "Llama 3.3 70B (local)",
        .capability = .{
            .max_context_tokens = 128_000,
            .supports_tools = true,
            .supports_streaming = true,
            .supports_structured_output = false,
            .returns_usage = false,
            .returns_finish_reason = false,
            .price_per_mtok_input = 0,
            .price_per_mtok_output = 0,
            .notes = "Local, powerful but requires 48GB RAM",
        },
        .strengths = &.{ "code_edit", "planning" },
        .effective_context_tokens = 120_000,
    },
    // Fake (for testing)
    .{
        .provider = "fake",
        .model_id = "fake-model-1",
        .display_name = "Fake (deterministic test)",
        .capability = .{
            .max_context_tokens = 4096,
            .supports_tools = true,
            .supports_streaming = true,
            .supports_structured_output = false,
            .returns_usage = true,
            .returns_finish_reason = true,
            .price_per_mtok_input = 0,
            .price_per_mtok_output = 0,
            .notes = "Deterministic test provider",
        },
        .strengths = &.{ "completion", "code_edit" },
        .effective_context_tokens = 4000,
    },
};

/// Routing request: hard requirements + preferences for model selection.
pub const RoutingRequest = struct {
    intent: TaskIntent = .code_edit,
    require_tools: bool = true,
    require_streaming: bool = false,
    require_structured_output: bool = false,
    context_bytes: usize = 0,
    max_price_per_mtok: ?u32 = null,
    prefer_local: bool = false,
    excluded_providers: []const []const u8 = &.{},
    preferred_strengths: []const []const u8 = &.{},
};

/// Task intent enum for routing.
pub const TaskIntent = enum {
    code_edit,
    code_review,
    planning,
    completion,
    embedding,
    agentic,
    explore_codebase,
};

/// Routing decision: chosen model + reason + alternatives.
pub const RoutingDecision = struct {
    provider: []const u8,
    model_id: []const u8,
    display_name: []const u8,
    reason: []const u8,
    capability: ProviderCapability,
};

/// Route a request to the best model based on hard requirements + scoring.
pub fn route(request: RoutingRequest) ?RoutingDecision {
    var best: ?ModelCapability = null;
    var best_score: f32 = -1.0;
    var best_reason: []const u8 = "no match";

    for (builtin_models) |model| {
        // 1. Filter by hard requirements
        if (isExcluded(model.provider, request.excluded_providers)) {
            continue;
        }
        if (request.prefer_local and !std.mem.eql(u8, model.provider, "ollama")) {
            continue;
        }
        if (request.require_tools and !model.capability.supports_tools) {
            continue;
        }
        if (request.require_streaming and !model.capability.supports_streaming) {
            continue;
        }
        if (request.require_structured_output and !model.capability.supports_structured_output) {
            continue;
        }
        // Context bytes → tokens (rough: 4 chars/token)
        if (request.context_bytes > model.effective_context_tokens * 4) {
            continue;
        }
        if (request.max_price_per_mtok) |cap| {
            if (model.capability.price_per_mtok_input > cap) {
                continue;
            }
        }

        // 2. Score by strengths + cost + context fit
        var score: f32 = 0.0;
        const required_strength = strengthForIntent(request.intent);
        for (model.strengths) |s| {
            if (std.mem.eql(u8, s, required_strength)) score += 10.0;
        }
        // Bonus for preferred strengths
        for (request.preferred_strengths) |pref| {
            for (model.strengths) |s| {
                if (std.mem.eql(u8, s, pref)) score += 5.0;
            }
        }
        // Cost (cheaper = higher score; 1 cent = 0.01 score penalty)
        const total_cost = @as(f32, @floatFromInt(model.capability.price_per_mtok_input + model.capability.price_per_mtok_output));
        score -= total_cost / 100.0;
        // Local preference bonus
        if (request.prefer_local and std.mem.eql(u8, model.provider, "ollama")) {
            score += 5.0;
        }
        // Context fit (closer to 50% utilization = better)
        if (request.context_bytes > 0) {
            const context_ratio = @as(f32, @floatFromInt(request.context_bytes)) / @as(f32, @floatFromInt(model.effective_context_tokens * 4));
            if (context_ratio > 0.1 and context_ratio < 0.8) score += 2.0;
        }

        if (score > best_score) {
            best_score = score;
            best = model;
            best_reason = "best score for intent + cost";
        }
    }

    if (best) |m| {
        return .{
            .provider = m.provider,
            .model_id = m.model_id,
            .display_name = m.display_name,
            .reason = best_reason,
            .capability = m.capability,
        };
    }
    return null;
}

fn isExcluded(provider: []const u8, excluded: []const []const u8) bool {
    for (excluded) |e| {
        if (std.mem.eql(u8, provider, e)) return true;
    }
    return false;
}

fn strengthForIntent(intent: TaskIntent) []const u8 {
    return switch (intent) {
        .code_edit => "code_edit",
        .code_review => "code_review",
        .planning => "planning",
        .completion => "completion",
        .embedding => "embedding",
        .agentic => "agentic",
        .explore_codebase => "code_edit",
    };
}

/// Look up a model by provider + model_id.
pub fn findModel(provider: []const u8, model_id: []const u8) ?ModelCapability {
    for (builtin_models) |m| {
        if (std.mem.eql(u8, m.provider, provider) and std.mem.eql(u8, m.model_id, model_id)) {
            return m;
        }
    }
    return null;
}

/// List all models for a given provider (or all if provider is null/empty).
pub fn modelsForProvider(provider: ?[]const u8) []const ModelCapability {
    if (provider == null or provider.?.len == 0) return &builtin_models;
    // Note: returns all; caller must filter. Kept simple for static table.
    return &builtin_models;
}

/// Compute exponential backoff with optional jitter.
pub fn backoffMs(attempt: u8, policy: RetryPolicy) u32 {
    var base: u64 = policy.base_delay_ms;
    var i: u8 = 0;
    while (i < attempt) : (i += 1) {
        base *|= 2;
        if (base > policy.max_delay_ms) {
            base = policy.max_delay_ms;
            break;
        }
    }
    if (policy.jitter) {
        // Simple deterministic jitter based on attempt (avoids crypto.random
        // dependency which is not available in all Zig 0.16 build contexts).
        const jitter_seed: u64 = @as(u64, attempt) *% 0x9E3779B97F4A7C15;
        var prng = std.Random.Xoshiro256.init(jitter_seed);
        const random = prng.random();
        const jitter = random.uintLessThan(u64, base / 2 + 1);
        base = base / 2 + jitter;
    }
    return @intCast(base);
}

test "builtin models table covers all providers" {
    const providers = [_][]const u8{ "gemini", "openrouter", "openai", "nvidia", "ollama", "fake" };
    for (providers) |p| {
        var found = false;
        for (builtin_models) |m| {
            if (std.mem.eql(u8, m.provider, p)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "route filters by tool support" {
    const decision = route(.{
        .intent = .code_edit,
        .require_tools = true,
        .context_bytes = 1000,
    });
    try std.testing.expect(decision != null);
    try std.testing.expect(decision.?.capability.supports_tools);
}

test "route filters by context length" {
    // 2M tokens = ~8M chars; only gemini-2.5-pro has 2M context.
    const decision = route(.{
        .intent = .code_edit,
        .context_bytes = 7_000_000, // ~1.75M tokens
    });
    try std.testing.expect(decision != null);
    try std.testing.expect(std.mem.eql(u8, decision.?.provider, "gemini"));
    try std.testing.expect(std.mem.eql(u8, decision.?.model_id, "gemini-2.5-pro"));
}

test "route prefers local when prefer_local=true" {
    const decision = route(.{
        .intent = .completion,
        .prefer_local = true,
        .context_bytes = 1000,
    });
    try std.testing.expect(decision != null);
    try std.testing.expect(std.mem.eql(u8, decision.?.provider, "ollama"));
}

test "route respects max_price_per_mtok" {
    const decision = route(.{
        .intent = .code_edit,
        .max_price_per_mtok = 10, // very low; only gemini-flash ($0.075) and ollama (free) qualify
        .context_bytes = 1000,
    });
    try std.testing.expect(decision != null);
    // Either gemini-2.5-flash or ollama
    const is_flash = std.mem.eql(u8, decision.?.model_id, "gemini-2.5-flash");
    const is_ollama = std.mem.eql(u8, decision.?.provider, "ollama");
    try std.testing.expect(is_flash or is_ollama);
}

test "findModel returns capability for known model" {
    const m = findModel("gemini", "gemini-2.5-pro");
    try std.testing.expect(m != null);
    try std.testing.expectEqual(@as(u32, 2_000_000), m.?.capability.max_context_tokens);
}

test "findModel returns null for unknown model" {
    const m = findModel("unknown", "no-such-model");
    try std.testing.expect(m == null);
}

test "backoffMs exponential without jitter" {
    const policy = RetryPolicy{ .base_delay_ms = 100, .max_delay_ms = 10000, .jitter = false };
    try std.testing.expectEqual(@as(u32, 100), backoffMs(0, policy));
    try std.testing.expectEqual(@as(u32, 200), backoffMs(1, policy));
    try std.testing.expectEqual(@as(u32, 400), backoffMs(2, policy));
    try std.testing.expectEqual(@as(u32, 800), backoffMs(3, policy));
}

test "backoffMs caps at max_delay_ms" {
    const policy = RetryPolicy{ .base_delay_ms = 1000, .max_delay_ms = 5000, .jitter = false };
    try std.testing.expect(backoffMs(10, policy) <= 5000);
}

test "backoffMs with jitter stays within bounds" {
    const policy = RetryPolicy{ .base_delay_ms = 1000, .max_delay_ms = 10000, .jitter = true };
    const delay = backoffMs(2, policy);
    // base = 4000, jitter range = [2000, 6000)
    try std.testing.expect(delay >= 2000 and delay < 6000);
}
