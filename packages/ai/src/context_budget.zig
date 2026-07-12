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

pub fn tierForAttempt(attempt: u8) BudgetTier {
    return switch (attempt) {
        0 => .full,
        1 => .balanced,
        else => .minimal,
    };
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
