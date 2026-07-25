//! Context window awareness — per-model context window sizes.
//! Used by adaptive_budget to adjust token budgets based on the
//! actual model's context window (e.g. Gemini 2M, Claude 200K).
const std = @import("std");

pub const ModelCapability = struct {
    /// Model ID (e.g. "gemini-2.5-pro", "claude-sonnet-4").
    model_id: []const u8,
    /// Provider name (e.g. "gemini", "anthropic", "openai").
    provider: []const u8,
    /// Maximum context window in tokens.
    context_window: usize,
    /// Maximum output tokens per request.
    max_output_tokens: usize,
    /// Whether the model supports tool/function calling.
    supports_tools: bool,
    /// Whether the model supports vision/image input.
    supports_vision: bool,
    /// Approximate cost per 1M input tokens (USD).
    cost_per_1m_input: f32,
    /// Approximate cost per 1M output tokens (USD).
    cost_per_1m_output: f32,
};

/// Known model capabilities. Used for context window awareness
/// and cost estimation. Users can override in settings.toml.
pub const known_models = [_]ModelCapability{
    // Gemini
    .{ .model_id = "gemini-2.5-pro", .provider = "gemini", .context_window = 2_097_152, .max_output_tokens = 8192, .supports_tools = true, .supports_vision = true, .cost_per_1m_input = 1.25, .cost_per_1m_output = 5.0 },
    .{ .model_id = "gemini-2.5-flash", .provider = "gemini", .context_window = 1_048_576, .max_output_tokens = 8192, .supports_tools = true, .supports_vision = true, .cost_per_1m_input = 0.075, .cost_per_1m_output = 0.3 },
    .{ .model_id = "gemini-2.0-flash", .provider = "gemini", .context_window = 1_048_576, .max_output_tokens = 8192, .supports_tools = true, .supports_vision = true, .cost_per_1m_input = 0.1, .cost_per_1m_output = 0.4 },
    // Anthropic
    .{ .model_id = "claude-sonnet-4", .provider = "anthropic", .context_window = 200_000, .max_output_tokens = 8192, .supports_tools = true, .supports_vision = true, .cost_per_1m_input = 3.0, .cost_per_1m_output = 15.0 },
    .{ .model_id = "claude-3.5-sonnet", .provider = "anthropic", .context_window = 200_000, .max_output_tokens = 8192, .supports_tools = true, .supports_vision = true, .cost_per_1m_input = 3.0, .cost_per_1m_output = 15.0 },
    .{ .model_id = "claude-3-haiku", .provider = "anthropic", .context_window = 200_000, .max_output_tokens = 4096, .supports_tools = true, .supports_vision = true, .cost_per_1m_input = 0.25, .cost_per_1m_output = 1.25 },
    // OpenAI
    .{ .model_id = "gpt-4o", .provider = "openai", .context_window = 128_000, .max_output_tokens = 16384, .supports_tools = true, .supports_vision = true, .cost_per_1m_input = 2.5, .cost_per_1m_output = 10.0 },
    .{ .model_id = "gpt-4o-mini", .provider = "openai", .context_window = 128_000, .max_output_tokens = 16384, .supports_tools = true, .supports_vision = true, .cost_per_1m_input = 0.15, .cost_per_1m_output = 0.6 },
    // OpenRouter (various)
    .{ .model_id = "anthropic/claude-sonnet-4", .provider = "openrouter", .context_window = 200_000, .max_output_tokens = 8192, .supports_tools = true, .supports_vision = true, .cost_per_1m_input = 3.0, .cost_per_1m_output = 15.0 },
    .{ .model_id = "nvidia/nemotron-3-super-120b-a12b:free", .provider = "openrouter", .context_window = 32_768, .max_output_tokens = 4096, .supports_tools = false, .supports_vision = false, .cost_per_1m_input = 0.0, .cost_per_1m_output = 0.0 },
    // Ollama (local, varies by hardware)
    .{ .model_id = "qwen2.5-coder:7b", .provider = "ollama", .context_window = 32_768, .max_output_tokens = 4096, .supports_tools = true, .supports_vision = false, .cost_per_1m_input = 0.0, .cost_per_1m_output = 0.0 },
    .{ .model_id = "qwen3.5:35b", .provider = "ollama", .context_window = 32_768, .max_output_tokens = 4096, .supports_tools = true, .supports_vision = false, .cost_per_1m_input = 0.0, .cost_per_1m_output = 0.0 },
    .{ .model_id = "nomic-embed-text", .provider = "ollama", .context_window = 8192, .max_output_tokens = 512, .supports_tools = false, .supports_vision = false, .cost_per_1m_input = 0.0, .cost_per_1m_output = 0.0 },
};

/// Default context window when model is not in the known list.
pub const default_context_window: usize = 32_768;

/// Default max output tokens.
pub const default_max_output: usize = 4096;

/// Look up model capabilities by model ID.
pub fn findCapability(model_id: []const u8) ?ModelCapability {
    for (known_models) |model| {
        if (std.mem.eql(u8, model.model_id, model_id)) {
            return model;
        }
    }
    return null;
}

/// Get context window for a model. Returns default if unknown.
pub fn contextWindow(model_id: []const u8) usize {
    if (findCapability(model_id)) |cap| {
        return cap.context_window;
    }
    return default_context_window;
}

/// Get max output tokens for a model.
pub fn maxOutputTokens(model_id: []const u8) usize {
    if (findCapability(model_id)) |cap| {
        return cap.max_output_tokens;
    }
    return default_max_output;
}

/// Check if a model supports tool/function calling.
pub fn supportsTools(model_id: []const u8) bool {
    if (findCapability(model_id)) |cap| {
        return cap.supports_tools;
    }
    return true; // Assume yes by default
}

/// Estimate cost for a request.
pub fn estimateCost(model_id: []const u8, input_tokens: usize, output_tokens: usize) f32 {
    if (findCapability(model_id)) |cap| {
        const input_cost = @as(f32, @floatFromInt(input_tokens)) / 1_000_000.0 * cap.cost_per_1m_input;
        const output_cost = @as(f32, @floatFromInt(output_tokens)) / 1_000_000.0 * cap.cost_per_1m_output;
        return input_cost + output_cost;
    }
    return 0.0; // Unknown model — no cost estimate
}

/// Compute the safe prompt budget (tokens) for a model.
/// This is context_window - max_output_tokens - safety_margin.
pub fn safePromptBudget(model_id: []const u8) usize {
    const window = contextWindow(model_id);
    const output = maxOutputTokens(model_id);
    const safety_margin: usize = 1024; // Reserve 1K tokens for system prompt + formatting
    if (window <= output + safety_margin) return 4096; // Fallback
    return window - output - safety_margin;
}

test "findCapability finds Gemini" {
    const cap = findCapability("gemini-2.5-pro");
    try std.testing.expect(cap != null);
    try std.testing.expectEqual(@as(usize, 2_097_152), cap.?.context_window);
}

test "findCapability returns null for unknown" {
    try std.testing.expect(findCapability("unknown-model") == null);
}

test "contextWindow returns default for unknown" {
    try std.testing.expectEqual(default_context_window, contextWindow("unknown-model"));
}

test "safePromptBudget accounts for output + margin" {
    const budget = safePromptBudget("claude-sonnet-4");
    // 200K - 8K - 1K = 191K (approximately)
    try std.testing.expect(budget > 180_000 and budget < 200_000);
}

test "estimateCost calculates correctly" {
    const cost = estimateCost("gemini-2.5-flash", 100_000, 10_000);
    // 100K/1M * 0.075 + 10K/1M * 0.3 = 0.0075 + 0.003 = 0.0105
    try std.testing.expect(cost > 0.009 and cost < 0.012);
}
