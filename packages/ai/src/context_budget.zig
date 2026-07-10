const std = @import("std");
const context_loader = @import("context_loader.zig");
const routing = @import("routing.zig");

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
