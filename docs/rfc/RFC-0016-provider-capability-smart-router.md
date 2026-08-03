# RFC-0016: Provider Capability Metadata & Smart Router

> **Trạng thái:** Proposed
> **Tác giả:** truonglv95 <anhtruonglavm2@gmail.com>
> **Ngày:** 2026-07-24
> **Liên kết:** [AI Workflow Evaluation](../evaluation/AI_WORKFLOW_EVALUATION.md) ·
> [AI Flow Improvements](../plan/FORGE_AI_FLOW_IMPROVEMENTS.md)

## 1. Tóm tắt

Thêm provider capability metadata (max_context, supports_tools, supports_streaming,
supports_structured_output, returns_usage, price) để agent loop và smart router
có thể quyết định provider/model phù hợp theo task. Thêm Anthropic Claude
provider. Cải thiện retry với jitter.

## 2. Động lực

Hiện tại:
- 6 providers (fake, gemini, ollama, openrouter, openai, nvidia) nhưng agent
  không biết capability từng provider.
- Không có Anthropic Claude provider — gap lớn vs Cursor/Kiro (Claude 3.5/4
  Sonnet là model mạnh cho coding).
- Retry không có jitter — thundering herd risk.
- Model selection manual (`--model gemini-2.0-flash`) — không auto-route theo
  task.

AI Flow Improvements (AI-FLOW-014) đã nêu nhưng chưa implement.

## 3. Thiết kế

### 3.1. Provider capability struct

```zig
// packages/ai/src/provider.zig (extend)

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

    /// Default retry policy.
    retry_policy: RetryPolicy,

    /// Provider-specific notes (e.g., "requires API key", "local only").
    notes: []const u8 = "",
};

pub const RetryPolicy = struct {
    max_attempts: u8 = 3,
    base_delay_ms: u32 = 1000,
    max_delay_ms: u32 = 30000,
    jitter: bool = true,
    retryable_errors: []const ProviderError = &.{
        .RateLimitExceeded,
        .NetworkError,
        .ContextLengthExceeded,
    },
};

pub const ModelCapability = struct {
    provider: []const u8,
    model_id: []const u8,
    display_name: []const u8,
    capability: ProviderCapability,
    /// Task types this model excels at: "code_edit", "code_review",
    /// "planning", "completion", "embedding".
    strengths: []const []const u8,
    /// Context window actually usable (after system prompt + tool defs).
    effective_context_tokens: u32,
};
```

### 3.2. Built-in capability table

```zig
// packages/ai/src/provider_factory.zig (extend)

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
            .price_per_mtok_input = 125,    // $1.25
            .price_per_mtok_output = 500,   // $5.00
            .retry_policy = .{ .max_attempts = 3, .base_delay_ms = 1000 },
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
            .price_per_mtok_input = 8,      // $0.075
            .price_per_mtok_output = 30,    // $0.30
            .retry_policy = .{ .max_attempts = 3, .base_delay_ms = 500 },
            .notes = "Fast, cheap, good for inline completion",
        },
        .strengths = &.{ "completion", "code_edit" },
        .effective_context_tokens = 900_000,
    },

    // Anthropic Claude (NEW)
    .{
        .provider = "anthropic",
        .model_id = "claude-sonnet-4-5",
        .display_name = "Claude Sonnet 4.5",
        .capability = .{
            .max_context_tokens = 200_000,
            .supports_tools = true,
            .supports_streaming = true,
            .supports_structured_output = false,
            .returns_usage = true,
            .returns_finish_reason = true,
            .price_per_mtok_input = 300,    // $3.00
            .price_per_mtok_output = 1500,  // $15.00
            .retry_policy = .{ .max_attempts = 3, .base_delay_ms = 1000 },
            .notes = "Best for agentic coding, tool use",
        },
        .strengths = &.{ "code_edit", "planning", "code_review", "agentic" },
        .effective_context_tokens = 180_000,
    },
    .{
        .provider = "anthropic",
        .model_id = "claude-haiku-4",
        .display_name = "Claude Haiku 4",
        .capability = .{
            .max_context_tokens = 200_000,
            .supports_tools = true,
            .supports_streaming = true,
            .supports_structured_output = false,
            .returns_usage = true,
            .returns_finish_reason = true,
            .price_per_mtok_input = 100,    // $1.00
            .price_per_mtok_output = 500,   // $5.00
            .retry_policy = .{ .max_attempts = 3, .base_delay_ms = 500 },
            .notes = "Fast, good for inline completion",
        },
        .strengths = &.{ "completion", "code_edit" },
        .effective_context_tokens = 180_000,
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
            .price_per_mtok_input = 100,    // varies
            .price_per_mtok_output = 300,
            .retry_policy = .{ .max_attempts = 3, .base_delay_ms = 1000 },
            .notes = "Gateway, route to cheapest model",
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
            .price_per_mtok_input = 0,      // free, local
            .price_per_mtok_output = 0,
            .retry_policy = .{ .max_attempts = 2, .base_delay_ms = 500 },
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
            .retry_policy = .{ .max_attempts = 2, .base_delay_ms = 500 },
            .notes = "Local, powerful but requires 48GB RAM",
        },
        .strengths = &.{ "code_edit", "planning" },
        .effective_context_tokens = 120_000,
    },
};
```

### 3.3. Smart router

```zig
// packages/ai/src/route_resolver.zig (extend)

pub const RoutingRequest = struct {
    intent: routing.TaskIntent,
    capability_profile: tools.CapabilityProfile,
    surface: run_record.Surface,
    context_bytes: usize,
    require_tools: bool = true,
    require_streaming: bool = false,
    max_price_per_mtok: ?u32 = null,    // budget cap
    prefer_local: bool = false,
    excluded_providers: []const []const u8 = &.{},
};

pub const RoutingDecision = struct {
    provider: []const u8,
    model_id: []const u8,
    reason: []const u8,
    alternatives: []const ModelCapability,
};

pub fn route(request: RoutingRequest) RoutingDecision {
    var candidates = std.ArrayList(ModelCapability).empty;
    defer candidates.deinit(allocator);

    // 1. Filter by hard requirements
    for (builtin_models) |model| {
        if (contains(excluded_providers, model.provider)) continue;
        if (request.prefer_local and !std.mem.eql(u8, model.provider, "ollama")) continue;
        if (request.require_tools and !model.capability.supports_tools) continue;
        if (request.require_streaming and !model.capability.supports_streaming) continue;
        if (request.context_bytes > model.effective_context_tokens * 4) continue;  // 4 chars/token
        if (request.max_price_per_mtok) |cap| {
            if (model.capability.price_per_mtok_input > cap) continue;
        }
        candidates.append(allocator, model) catch continue;
    }

    if (candidates.items.len == 0) return .{
        .provider = "fake",
        .model_id = "fallback",
        .reason = "no eligible providers, using fake fallback",
        .alternatives = &.{},
    };

    // 2. Score by strengths match + cost
    var best = candidates.items[0];
    var best_score: f32 = -1;
    for (candidates.items) |model| {
        var score: f32 = 0;
        // Strengths match
        const required_strength = strengthForIntent(request.intent);
        for (model.strengths) |s| {
            if (std.mem.eql(u8, s, required_strength)) score += 10;
        }
        // Cost (cheaper = higher score)
        const cost = @as(f32, @floatFromInt(model.capability.price_per_mtok_input + model.capability.price_per_mtok_output));
        score -= cost / 100;  // 1 cent = 0.01 score
        // Local preference
        if (request.prefer_local and std.mem.eql(u8, model.provider, "ollama")) score += 5;
        // Effective context fit (closer = better, avoid over-provisioning)
        const context_ratio = @as(f32, @floatFromInt(request.context_bytes)) / @as(f32, @floatFromInt(model.effective_context_tokens * 4));
        if (context_ratio > 0.1 and context_ratio < 0.8) score += 2;

        if (score > best_score) {
            best_score = score;
            best = model;
        }
    }

    return .{
        .provider = best.provider,
        .model_id = best.model_id,
        .reason = "best score for intent + cost",
        .alternatives = candidates.items,
    };
}
```

### 3.4. CLI: `forge providers`

```bash
# List providers with capability
forge providers list
forge providers list --json

# List models
forge models list
forge models list --provider gemini
forge models list --json

# Query capability
forge models capability gemini/gemini-2.5-pro --json

# Test routing
forge models route --intent code_edit --context-bytes 50000 --json
```

Output (human):
```text
Provider     Model                        Context    Tools  Stream  Price (I/O)      Notes
gemini       gemini-2.5-pro               2,000,000  ✓      ✓       $1.25/$5.00      Best for long context
gemini       gemini-2.5-flash             1,000,000  ✓      ✓       $0.08/$0.30      Fast, cheap, inline
anthropic    claude-sonnet-4-5              200,000  ✓      ✓       $3.00/$15.00     Best for agentic
anthropic    claude-haiku-4                 200,000  ✓      ✓       $1.00/$5.00      Fast, inline
openrouter   auto                           128,000  ✓      ✓       varies           Gateway
ollama       qwen2.5-coder:14b               32,000  ✓      ✓       free             Local, private
ollama       llama3.3:70b                   128,000  ✓      ✓       free             Local, powerful
```

### 3.5. Anthropic Claude provider

```text
packages/ai/src/providers/anthropic/
├── provider.zig          # ClaudeMessages API client
├── tool_transport.zig    # Tool use adapter (Claude format)
├── sse.zig               # SSE streaming
└── embedder.zig          # Stub (Claude không có embeddings)
```

#### 3.5.1. API format

```http
POST https://api.anthropic.com/v1/messages
x-api-key: <key>
anthropic-version: 2023-06-01
content-type: application/json

{
  "model": "claude-sonnet-4-5",
  "max_tokens": 8192,
  "system": "...",
  "messages": [
    {"role": "user", "content": "..."}
  ],
  "tools": [...],
  "stream": true
}
```

#### 3.5.2. Tool use format (Claude-specific)

Claude dùng `tool_use` content block thay vì `tool_calls`:
```json
{
  "role": "assistant",
  "content": [
    {"type": "text", "text": "I'll read the file first."},
    {"type": "tool_use", "id": "toolu_abc", "name": "read_file", "input": {"path": "src/main.zig"}}
  ]
}
```

Tool result:
```json
{
  "role": "user",
  "content": [
    {"type": "tool_result", "tool_use_id": "toolu_abc", "content": "file contents..."}
  ]
}
```

#### 3.5.3. Credentials

```bash
# macOS keychain
forge credentials set anthropic --key ANTHROPIC_API_KEY
# Or env
export ANTHROPIC_API_KEY=sk-ant-...
```

### 3.6. Retry với jitter

```zig
// packages/ai/src/retry.zig (extend)

pub fn backoffMs(attempt: u8, policy: RetryPolicy) u32 {
    var base: u64 = policy.base_delay_ms;
    for (0..attempt) |_| {
        base *|= 2;
        if (base > policy.max_delay_ms) {
            base = policy.max_delay_ms;
            break;
        }
    }
    if (policy.jitter) {
        const rng = std.crypto.random;
        const jitter = rng.uintLessThan(u64, base / 2);
        base = base / 2 + jitter;
    }
    return @intCast(base);
}

// Usage:
// const delay = backoffMs(attempt, policy);
// std.time.sleep(@as(u64, delay) * std.time.ns_per_ms);
```

### 3.7. Configuration

```toml
# forge.toml
[ai.provider]
default = "auto"                     # auto-route hoặc explicit provider
fallback = "ollama"                   # if default fails

[ai.provider.anthropic]
api_key_env = "ANTHROPIC_API_KEY"     # env var name
base_url = "https://api.anthropic.com"
default_model = "claude-sonnet-4-5"
timeout_ms = 60000

[ai.provider.routing]
prefer_local = false                  # prefer ollama when possible
max_price_per_mtok = null             # no budget cap by default
excluded_providers = []
require_tools = true                  # never route to non-tool provider
require_streaming = false             # don't require streaming
```

## 4. Testing

### 4.1. Unit tests

```zig
test "provider capability table covers all providers" { ... }
test "smart router filters by context length" { ... }
test "smart router filters by tool support" { ... }
test "smart router prefers local when prefer_local=true" { ... }
test "smart router respects excluded_providers" { ... }
test "smart router respects max_price_per_mtok" { ... }
test "backoffMs exponential with jitter" { ... }
test "backoffMs caps at max_delay_ms" { ... }
test "anthropic provider parses tool_use content" { ... }
test "anthropic provider formats tool_result" { ... }
```

### 4.2. Integration tests

```bash
# Fake anthropic provider
forge ask "test" --provider anthropic --model claude-sonnet-4-5 --json
# (Requires ANTHROPIC_API_KEY or mock server)

# Routing
forge models route --intent code_edit --context-bytes 50000 --json
# Expect: gemini-2.5-flash or claude-haiku-4 (cheapest capable)

forge models route --intent code_edit --context-bytes 1500000 --json
# Expect: gemini-2.5-pro (only one with enough context)

forge models route --intent code_edit --prefer-local --json
# Expect: ollama/qwen2.5-coder:14b
```

### 4.3. Eval

```bash
forge eval ai-flow --corpus fixtures/eval/provider_routing.json --providers gemini,anthropic,ollama
# Compare same task across providers, measure:
# - success rate
# - p50/p95 latency
# - token cost
# - tool call sequence quality
```

## 5. Rollout plan

1. **Week 1:** Provider capability struct + builtin_models table + `forge
   providers list` + `forge models list`.
2. **Week 1-2:** Smart router + `forge models route` + integrate vào
   `route_resolver.zig`.
3. **Week 2-3:** Anthropic Claude provider (provider.zig + tool_transport +
   SSE).
4. **Week 3:** Retry với jitter + failover polish.
5. **Week 4:** Provider comparison eval + dogfood.

## 6. Risks

| Rủi ro | Giảm |
|---|---|
| Capability table outdated (model updates) | Manual verify + community PR + override via `forge.toml` |
| Anthropic API changes | Pin anthropic-version header, monitor changelog |
| Smart router picks wrong model | User can override với `--provider` / `--model` |
| Pricing inaccurate | Display "varies" cho gateway, actual cost từ usage response |
| Latency from capability lookup | Cache table in memory, no IO |

## 7. Alternatives considered

- **Hardcoded provider in agent loop:** ❌ Không flexible, không scale.
- **External routing service (LiteLLM):** ❌ Thêm dependency, không native Zig.
- **No Anthropic provider:** ❌ Gap lớn vs Cursor/Kiro.
- **Manual model selection only:** ❌ Bad UX, agent should know.

## 8. Open questions

- [ ] Có nên support OpenAI Responses API (new format)?
      → Phase 2.
- [ ] Có nên support Azure OpenAI?
      → Phase 2,.enterprise.
- [ ] Có nên support self-hosted vLLM?
      → Phase 2, via OpenAI compat.
- [ ] Capability table từ community marketplace?
      → Phase 2.

## 9. Exit gate

- [ ] `forge providers list --json` returns 6+ providers với capability
- [ ] `forge models list --json` returns 10+ models với capability
- [ ] `forge models route` returns best model cho routing request
- [ ] Anthropic Claude provider works với tool use
- [ ] Smart router auto-routes trong `forge ask` khi `--provider auto`
- [ ] Retry với jitter tested với mock rate limit
- [ ] Provider comparison eval pass với 3+ providers
- [ ] `forge.toml [ai.provider.*]` config hoạt động
