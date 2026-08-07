//! Intent taxonomy — finer-grained intent classification than the 6-enum
//! TaskIntent in routing.zig. Maps to the backend's agent-prepare intent
//! labels so the client and backend speak the same vocabulary.
//!
//! Phase B: when the backend returns an intent string, the client maps it
//! to one of these taxonomy values, which then drives capability profile
//! + tool selection + context budget.

const std = @import("std");
const routing = @import("../routing.zig");
const tools = @import("../tools.zig");

/// Fine-grained intent taxonomy. Each value maps to:
///   - a TaskIntent (the coarse routing.zig enum)
///   - a default CapabilityProfile (read_only / propose / propose_and_task)
///   - a default tool set (subset of the 22 native tools)
///   - a recommended max_steps budget
pub const Intent = enum {
    // Read-only intents — no file mutations.
    answer_question,
    explore_codebase,
    code_review,

    // Edit intents — propose changes, review, apply.
    edit_code,
    refactor,
    add_test,
    add_feature,
    add_doc,

    // Debug intents — read + run commands + propose fix.
    debug_failure,
    fix_compile_error,

    // Planning — read-only, produce a plan document.
    plan_change,

    /// Map a taxonomy Intent to the coarse routing.zig TaskIntent.
    pub fn toTaskIntent(self: Intent) routing.TaskIntent {
        return switch (self) {
            .answer_question, .explore_codebase, .code_review, .add_doc => .answer_question,
            .edit_code, .refactor, .add_test, .add_feature => .edit_code,
            .debug_failure, .fix_compile_error => .debug_failure,
            .plan_change => .plan_change,
        };
    }

    /// Default capability profile for this intent.
    pub fn defaultCapability(self: Intent) tools.CapabilityProfile {
        return switch (self) {
            .answer_question, .explore_codebase, .code_review, .plan_change => .read_only,
            .add_test, .add_doc => .propose,
            .edit_code, .refactor, .add_feature, .debug_failure, .fix_compile_error => .propose_and_task,
        };
    }

    /// Recommended max_steps budget for this intent.
    pub fn defaultMaxSteps(self: Intent) u32 {
        return switch (self) {
            .answer_question, .add_doc => 4,
            .explore_codebase, .code_review => 8,
            .plan_change => 6,
            .edit_code, .add_test, .add_feature => 16,
            .refactor => 20, // refactors often span multiple files
            .debug_failure, .fix_compile_error => 24, // debug needs reproduce + fix + validate
        };
    }

    /// Human-readable label (matches backend agent-prepare intent strings).
    pub fn label(self: Intent) []const u8 {
        return switch (self) {
            .answer_question => "answer_question",
            .explore_codebase => "explore_codebase",
            .code_review => "code_review",
            .edit_code => "edit_code",
            .refactor => "refactor",
            .add_test => "add_test",
            .add_feature => "add_feature",
            .add_doc => "add_doc",
            .debug_failure => "debug_failure",
            .fix_compile_error => "fix_compile_error",
            .plan_change => "plan_change",
        };
    }
};

/// Parse an intent string (from backend agent-prepare or client heuristic)
/// into a taxonomy Intent. Returns null for unrecognized strings.
pub fn parseIntent(s: []const u8) ?Intent {
    if (std.mem.eql(u8, s, "answer_question")) return .answer_question;
    if (std.mem.eql(u8, s, "explore_codebase")) return .explore_codebase;
    if (std.mem.eql(u8, s, "code_review")) return .code_review;
    if (std.mem.eql(u8, s, "edit_code")) return .edit_code;
    if (std.mem.eql(u8, s, "refactor")) return .refactor;
    if (std.mem.eql(u8, s, "add_test")) return .add_test;
    if (std.mem.eql(u8, s, "add_feature")) return .add_feature;
    if (std.mem.eql(u8, s, "add_doc")) return .add_doc;
    if (std.mem.eql(u8, s, "debug_failure")) return .debug_failure;
    if (std.mem.eql(u8, s, "fix_compile_error")) return .fix_compile_error;
    if (std.mem.eql(u8, s, "plan_change")) return .plan_change;
    return null;
}

/// Heuristic classifier — mirrors the backend's regex-based classifier.
/// Used when the backend is unreachable or returns used_llm=false.
pub fn heuristicClassify(intent_text: []const u8) Intent {
    const lower_buf: [1024]u8 = undefined;
    var lower = lower_buf;
    const n = @min(intent_text.len, lower.len);
    for (intent_text[0..n], 0..) |c, i| {
        lower[i] = std.ascii.toLower(c);
    }
    const s = lower[0..n];

    if (containsAny(s, &.{ "explain", "what is", "what does", "why", "how does", "describe", "tell me about", "giải thích", "là gì", "tại sao", "làm gì" })) {
        return .answer_question;
    }
    if (containsAny(s, &.{ "review", "audit", "assess", "evaluate", "đánh giá" })) {
        return .code_review;
    }
    if (containsAny(s, &.{ "explore", "understand", "navigate", "tour", "khám phá" })) {
        return .explore_codebase;
    }
    if (containsAny(s, &.{ "compile error", "syntax error", "build fail", "won't compile", "fix compile", "lỗi compile", "lỗi biên dịch" })) {
        return .fix_compile_error;
    }
    if (containsAny(s, &.{ "debug", "fix", "error", "bug", "crash", "fail", "broken", "sửa lỗi", "lỗi", "fix bug" })) {
        return .debug_failure;
    }
    if (containsAny(s, &.{ "test", "spec", "coverage", "thêm test", "viết test" })) {
        return .add_test;
    }
    if (containsAny(s, &.{ "doc", "comment", "readme", "documentation", "tài liệu", "chú thích" })) {
        return .add_doc;
    }
    if (containsAny(s, &.{ "refactor", "rename", "extract", "move", "inline", "simplify", "cleanup", "tái cấu trúc", "đổi tên" })) {
        return .refactor;
    }
    if (containsAny(s, &.{ "add", "create", "implement", "new", "build", "feature", "thêm", "tạo", "implement" })) {
        return .add_feature;
    }
    if (containsAny(s, &.{ "plan", "design", "outline", "strategy", "kế hoạch" })) {
        return .plan_change;
    }
    return .edit_code;
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    }
    return false;
}

// ─── Tests ─────────────────────────────────────────────────────────────

test "parseIntent recognizes all taxonomy labels" {
    try std.testing.expectEqual(@as(?Intent, .answer_question), parseIntent("answer_question"));
    try std.testing.expectEqual(@as(?Intent, .refactor), parseIntent("refactor"));
    try std.testing.expectEqual(@as(?Intent, .fix_compile_error), parseIntent("fix_compile_error"));
}

test "parseIntent returns null for unknown" {
    try std.testing.expectEqual(@as(?Intent, null), parseIntent("unknown_intent"));
    try std.testing.expectEqual(@as(?Intent, null), parseIntent(""));
}

test "toTaskIntent maps to coarse routing enum" {
    try std.testing.expectEqual(routing.TaskIntent.answer_question, Intent.answer_question.toTaskIntent());
    try std.testing.expectEqual(routing.TaskIntent.edit_code, Intent.refactor.toTaskIntent());
    try std.testing.expectEqual(routing.TaskIntent.debug_failure, Intent.fix_compile_error.toTaskIntent());
    try std.testing.expectEqual(routing.TaskIntent.plan_change, Intent.plan_change.toTaskIntent());
}

test "defaultCapability: read-only intents get read_only" {
    try std.testing.expectEqual(tools.CapabilityProfile.read_only, Intent.answer_question.defaultCapability());
    try std.testing.expectEqual(tools.CapabilityProfile.read_only, Intent.code_review.defaultCapability());
    try std.testing.expectEqual(tools.CapabilityProfile.read_only, Intent.plan_change.defaultCapability());
}

test "defaultCapability: edit intents get propose_and_task" {
    try std.testing.expectEqual(tools.CapabilityProfile.propose_and_task, Intent.edit_code.defaultCapability());
    try std.testing.expectEqual(tools.CapabilityProfile.propose_and_task, Intent.refactor.defaultCapability());
    try std.testing.expectEqual(tools.CapabilityProfile.propose_and_task, Intent.debug_failure.defaultCapability());
}

test "defaultMaxSteps: debug gets more steps than answer" {
    try std.testing.expect(Intent.debug_failure.defaultMaxSteps() > Intent.answer_question.defaultMaxSteps());
    try std.testing.expect(Intent.refactor.defaultMaxSteps() >= Intent.edit_code.defaultMaxSteps());
    try std.testing.expectEqual(@as(u32, 4), Intent.answer_question.defaultMaxSteps());
}

test "heuristicClassify: question keywords" {
    try std.testing.expectEqual(Intent.answer_question, heuristicClassify("explain what this function does"));
    try std.testing.expectEqual(Intent.answer_question, heuristicClassify("giải thích hàm này"));
}

test "heuristicClassify: debug keywords" {
    try std.testing.expectEqual(Intent.debug_failure, heuristicClassify("fix the bug in auth"));
    try std.testing.expectEqual(Intent.fix_compile_error, heuristicClassify("fix compile error in main.zig"));
}

test "heuristicClassify: refactor keywords" {
    try std.testing.expectEqual(Intent.refactor, heuristicClassify("rename getUser to fetchUser"));
    try std.testing.expectEqual(Intent.refactor, heuristicClassify("extract helper function"));
}

test "heuristicClassify: defaults to edit_code" {
    try std.testing.expectEqual(Intent.edit_code, heuristicClassify("update the config"));
}

test "label round-trips through parseIntent" {
    const all = [_]Intent{
        .answer_question, .explore_codebase, .code_review, .edit_code,
        .refactor, .add_test, .add_feature, .add_doc,
        .debug_failure, .fix_compile_error, .plan_change,
    };
    for (all) |intent| {
        try std.testing.expectEqual(@as(?Intent, intent), parseIntent(intent.label()));
    }
}
