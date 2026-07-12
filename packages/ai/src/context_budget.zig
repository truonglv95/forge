const std = @import("std");
const context_loader = @import("context_loader.zig");
const routing = @import("routing.zig");
const task_ledger = @import("task_ledger.zig");

pub const BudgetTier = enum {
    full,
    balanced,
    minimal,
};

pub const Estimate = struct {
    context_bytes: usize,
    tool_declaration_bytes: usize,
    conversation_bytes: usize,
    reserve_bytes: usize = 16 * 1024,

    pub fn total(self: Estimate) usize {
        return self.context_bytes + self.tool_declaration_bytes + self.conversation_bytes + self.reserve_bytes;
    }
};

pub const TokenBudgetInput = struct {
    context_window_tokens: usize,
    configured_context_bytes: usize,
    conversation_bytes: usize = 0,
    resume_conversation_bytes: usize = 0,
    task_ledger_json: []const u8 = "",
    completion_reserve_tokens: usize = 0,
};

pub const TokenBudgetPlan = struct {
    tier: BudgetTier,
    max_context_bytes: usize,
    context_budget_tokens: usize,
    prompt_budget_tokens: usize,
    history_tokens: usize,
    completion_reserve_tokens: usize,
    safety_reserve_tokens: usize,
    ledger_entries: usize = 0,
    ledger_phase: task_ledger.Phase = .planning,
};

pub fn tierForAttempt(attempt: u8) BudgetTier {
    return switch (attempt) {
        0 => .full,
        1 => .balanced,
        else => .minimal,
    };
}

pub fn estimateTokensFromBytes(bytes: usize) usize {
    if (bytes == 0) return 0;
    return (bytes + 2) / 3;
}

pub fn bytesForPromptTokens(tokens: usize) usize {
    return tokens * 3;
}

pub fn planTokenBudget(allocator: std.mem.Allocator, input: TokenBudgetInput) TokenBudgetPlan {
    const window_tokens = if (input.context_window_tokens == 0) @as(usize, 32_768) else input.context_window_tokens;
    const prompt_budget_tokens = @max(@as(usize, 1024), window_tokens * 7 / 10);
    var stats = task_ledger.Stats{};
    if (input.task_ledger_json.len > 0) {
        stats = task_ledger.statsFromJson(allocator, input.task_ledger_json) catch .{};
    }

    const history_tokens = estimateTokensFromBytes(input.conversation_bytes + input.resume_conversation_bytes);
    const safety_reserve_tokens = @max(@as(usize, 512), window_tokens / 20);
    const completion_reserve_tokens = if (input.completion_reserve_tokens > 0)
        input.completion_reserve_tokens
    else
        completionReserveFor(stats, window_tokens);

    const fixed_tokens = saturatingAdd(history_tokens, saturatingAdd(safety_reserve_tokens, completion_reserve_tokens));
    const available_context_tokens = if (prompt_budget_tokens > fixed_tokens + 256)
        prompt_budget_tokens - fixed_tokens
    else
        @as(usize, 256);
    const max_context_bytes = @min(input.configured_context_bytes, bytesForPromptTokens(available_context_tokens));
    const estimate_value = estimate(max_context_bytes, 0, input.conversation_bytes + input.resume_conversation_bytes);
    var tier = tierForEstimate(window_tokens, estimate_value);
    tier = tierForLedger(tier, stats, .edit_code);
    if (available_context_tokens < 2048) tier = .minimal else if (available_context_tokens < 8192 and tier == .full) tier = .balanced;

    return .{
        .tier = tier,
        .max_context_bytes = max_context_bytes,
        .context_budget_tokens = available_context_tokens,
        .prompt_budget_tokens = prompt_budget_tokens,
        .history_tokens = history_tokens,
        .completion_reserve_tokens = completion_reserve_tokens,
        .safety_reserve_tokens = safety_reserve_tokens,
        .ledger_entries = stats.entries,
        .ledger_phase = stats.phase,
    };
}

fn completionReserveFor(stats: task_ledger.Stats, window_tokens: usize) usize {
    const base = if (window_tokens >= 128_000) @as(usize, 4096) else if (window_tokens >= 32_000) @as(usize, 2048) else @as(usize, 1024);
    if (stats.phase == .repairing or stats.phase == .validating) return base + base / 2;
    if (stats.longTask()) return base + base / 4;
    return base;
}

fn saturatingAdd(a: usize, b: usize) usize {
    return a +| b;
}

pub fn applyTier(options: context_loader.LoadOptions, tier: BudgetTier, intent: routing.TaskIntent) context_loader.LoadOptions {
    var out = options;

    switch (tier) {
        .full => {},
        .balanced => {
            out.max_bytes = @min(out.max_bytes, 2 * 1024 * 1024);
            out.retrieval_max_chunks = @min(out.retrieval_max_chunks, if (intent == .debug_failure) @as(usize, 18) else @as(usize, 16));
            out.recent_file_limit = @min(out.recent_file_limit, 8);
            out.recent_file_preview_bytes = @min(out.recent_file_preview_bytes, 4096);
            out.import_max_files = @min(out.import_max_files, 8);
            out.import_preview_bytes = @min(out.import_preview_bytes, 1024);
            out.web_max_urls = @min(out.web_max_urls, 2);
            out.web_max_bytes = @min(out.web_max_bytes, 12 * 1024);
            if (intent == .answer_question) {
                out.include_git_diff = false;
                out.include_diagnostics = false;
            }
        },
        .minimal => {
            out.max_bytes = @min(out.max_bytes, 512 * 1024);
            out.retrieval_max_chunks = @min(out.retrieval_max_chunks, if (intent == .edit_code) @as(usize, 10) else @as(usize, 8));
            out.recent_file_limit = @min(out.recent_file_limit, 3);
            out.recent_file_preview_bytes = @min(out.recent_file_preview_bytes, 1536);
            out.include_import_graph = false;
            out.import_max_files = 0;
            out.import_preview_bytes = 0;
            out.include_web = false;
            out.web_max_urls = 0;
            out.web_max_bytes = 0;
            out.memory_max_entries = @min(out.memory_max_entries, 4);
            out.memory_max_entry_chars = @min(out.memory_max_entry_chars, 256);
            if (intent == .answer_question or intent == .explore_codebase) {
                out.include_git_diff = false;
                out.include_diagnostics = false;
                out.include_lsp_context = false;
            }
        },
    }

    return out;
}

pub fn tierForLedger(base: BudgetTier, stats: task_ledger.Stats, intent: routing.TaskIntent) BudgetTier {
    if (stats.phase == .blocked) return .minimal;
    if (stats.longTask()) return downgrade(base);
    if (stats.needsFreshEvidence() and (intent == .edit_code or intent == .debug_failure)) return if (base == .minimal) .minimal else .balanced;
    return base;
}

pub fn applyLedger(
    allocator: std.mem.Allocator,
    options: context_loader.LoadOptions,
    base_tier: BudgetTier,
    intent: routing.TaskIntent,
    ledger_json: []const u8,
) context_loader.LoadOptions {
    if (ledger_json.len == 0) return applyTier(options, base_tier, intent);
    const stats = task_ledger.statsFromJson(allocator, ledger_json) catch return applyTier(options, base_tier, intent);
    const tier = tierForLedger(base_tier, stats, intent);
    var out = applyTier(options, tier, intent);
    if (stats.needsFreshEvidence()) {
        out.include_pre_retrieval = true;
        out.retrieval_max_chunks = @max(out.retrieval_max_chunks, if (intent == .debug_failure) @as(usize, 12) else @as(usize, 10));
        out.include_git_diff = true;
        out.include_diagnostics = true;
    }
    if (stats.longTask()) {
        out.recent_file_limit = @min(out.recent_file_limit, 4);
        out.memory_max_entries = @min(out.memory_max_entries, 4);
    }
    if (stats.file_edits > 0) {
        out.include_git_diff = true;
        out.include_diagnostics = true;
        out.recent_file_limit = @min(out.recent_file_limit, 6);
        out.retrieval_max_chunks = @max(out.retrieval_max_chunks, 10);
    }
    return out;
}

fn downgrade(tier: BudgetTier) BudgetTier {
    return switch (tier) {
        .full => .balanced,
        .balanced, .minimal => .minimal,
    };
}

pub fn estimate(builder_bytes: usize, declarations_bytes: usize, conversation_bytes: usize) Estimate {
    return .{
        .context_bytes = builder_bytes,
        .tool_declaration_bytes = declarations_bytes,
        .conversation_bytes = conversation_bytes,
    };
}

/// Rough but conservative conversion for prompt construction. Most code/text
/// prompts average 3-5 bytes per token; using 3 keeps enough headroom for JSON
/// tool wrappers and provider-specific framing.
pub fn safePromptBytesForWindow(context_window_tokens: usize) usize {
    if (context_window_tokens == 0) return 512 * 1024;
    const usable_tokens = context_window_tokens * 7 / 10;
    return usable_tokens * 3;
}

pub fn tierForEstimate(context_window_tokens: usize, estimate_value: Estimate) BudgetTier {
    const safe_bytes = safePromptBytesForWindow(context_window_tokens);
    const total = estimate_value.total();
    if (total <= safe_bytes * 6 / 10) return .full;
    if (total <= safe_bytes) return .balanced;
    return .minimal;
}

test "applyTier shrinks retrieval context progressively" {
    const base = context_loader.LoadOptions{
        .max_bytes = 8 * 1024 * 1024,
        .retrieval_max_chunks = 32,
        .recent_file_limit = 16,
        .include_import_graph = true,
        .include_web = true,
    };

    const balanced = applyTier(base, .balanced, .edit_code);
    try std.testing.expect(balanced.max_bytes < base.max_bytes);
    try std.testing.expect(balanced.retrieval_max_chunks <= 16);
    try std.testing.expect(balanced.include_import_graph);

    const minimal = applyTier(base, .minimal, .explore_codebase);
    try std.testing.expect(minimal.max_bytes <= 512 * 1024);
    try std.testing.expect(minimal.retrieval_max_chunks <= 8);
    try std.testing.expect(!minimal.include_import_graph);
    try std.testing.expect(!minimal.include_web);
}

test "tierForEstimate downgrades when prompt approaches model window" {
    try std.testing.expectEqual(BudgetTier.full, tierForEstimate(128_000, estimate(10_000, 1_000, 1_000)));
    try std.testing.expectEqual(BudgetTier.minimal, tierForEstimate(4_096, estimate(100_000, 10_000, 10_000)));
}

test "planTokenBudget reserves room for large conversation history" {
    const allocator = std.testing.allocator;
    const small = planTokenBudget(allocator, .{
        .context_window_tokens = 16_000,
        .configured_context_bytes = 8 * 1024 * 1024,
        .conversation_bytes = 1_024,
    });
    const large = planTokenBudget(allocator, .{
        .context_window_tokens = 16_000,
        .configured_context_bytes = 8 * 1024 * 1024,
        .conversation_bytes = 24 * 1024,
        .resume_conversation_bytes = 24 * 1024,
    });
    try std.testing.expect(large.max_context_bytes < small.max_context_bytes);
    try std.testing.expect(large.history_tokens > small.history_tokens);
    try std.testing.expect(large.tier != .full);
}

test "planTokenBudget uses ledger pressure for long tasks" {
    const allocator = std.testing.allocator;
    const ledger_json =
        \\{"phase":"repairing","goal":"fix","entries":[
        \\{"kind":"validation","step_index":8,"path":"","text":"zig build failed"},
        \\{"kind":"file_edited","step_index":7,"path":"src/a.zig","text":"Write"},
        \\{"kind":"file_read","step_index":6,"path":"src/a.zig","text":"File"}
        \\]}
    ;
    const plan = planTokenBudget(allocator, .{
        .context_window_tokens = 32_000,
        .configured_context_bytes = 8 * 1024 * 1024,
        .conversation_bytes = 4 * 1024,
        .task_ledger_json = ledger_json,
    });
    try std.testing.expectEqual(task_ledger.Phase.repairing, plan.ledger_phase);
    try std.testing.expect(plan.ledger_entries >= 3);
    try std.testing.expect(plan.completion_reserve_tokens > 2048);
    try std.testing.expect(plan.tier != .full);
}

test "applyLedger keeps focused retrieval during repair" {
    const allocator = std.testing.allocator;
    const base = context_loader.LoadOptions{
        .max_bytes = 8 * 1024 * 1024,
        .retrieval_max_chunks = 4,
        .recent_file_limit = 16,
        .include_git_diff = false,
        .include_diagnostics = false,
    };
    const ledger_json =
        \\{"phase":"repairing","goal":"fix","entries":[
        \\{"kind":"validation","step_index":4,"path":"","text":"zig build failed"}
        \\]}
    ;
    const out = applyLedger(allocator, base, .full, .debug_failure, ledger_json);
    try std.testing.expect(out.max_bytes <= 2 * 1024 * 1024);
    try std.testing.expect(out.retrieval_max_chunks >= 12);
    try std.testing.expect(out.include_git_diff);
    try std.testing.expect(out.include_diagnostics);
}

test "applyLedger prioritizes diff and diagnostics after edits" {
    const allocator = std.testing.allocator;
    const base = context_loader.LoadOptions{
        .max_bytes = 8 * 1024 * 1024,
        .retrieval_max_chunks = 4,
        .recent_file_limit = 16,
        .include_git_diff = false,
        .include_diagnostics = false,
    };
    const ledger_json =
        \\{"phase":"editing","goal":"fix","entries":[
        \\{"kind":"file_edited","step_index":4,"path":"src/a.zig","text":"Write"}
        \\]}
    ;
    const out = applyLedger(allocator, base, .full, .edit_code, ledger_json);
    try std.testing.expect(out.include_git_diff);
    try std.testing.expect(out.include_diagnostics);
    try std.testing.expect(out.recent_file_limit <= 6);
    try std.testing.expect(out.retrieval_max_chunks >= 10);
}
