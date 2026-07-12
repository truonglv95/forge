const std = @import("std");
const context_loader = @import("context_loader.zig");
const tools = @import("tools.zig");
const tool_registry = @import("tools/registry.zig");

/// High-level task classification used to narrow context sources and tool declarations.
pub const TaskIntent = enum {
    answer_question,
    plan_change,
    edit_code,
    debug_failure,
    explore_codebase,
    computer_control,
};

pub const RouteInput = struct {
    mode: tools.Mode = .agent,
    intent: []const u8,
    has_active_file: bool = false,
    has_selection: bool = false,
};

pub const RoutePlan = struct {
    intent: TaskIntent,
    capability_profile: tools.CapabilityProfile,
    context: context_loader.LoadOptions,
};

pub fn intentLabel(intent: TaskIntent) []const u8 {
    return switch (intent) {
        .answer_question => "answer_question",
        .plan_change => "plan_change",
        .edit_code => "edit_code",
        .debug_failure => "debug_failure",
        .explore_codebase => "explore_codebase",
        .computer_control => "computer_control",
    };
}

/// Phrases that clearly signal a read-only question even when they contain a
/// verb that would otherwise look like an edit (e.g. "làm gì" = "does what").
fn isQuestionIntent(intent: []const u8) bool {
    return containsAny(intent, &.{
        "explain",              "what is",           "what are",           "what does",   "why does",     "how does",         "how do",
        "tell me about",        "describe ",         "does what",          "used for",    "meaning of",   "assess",           "evaluate",
        "review overall",       "overall review",    "overall assessment", "need to add", "needs adding", "anything missing", "what is missing",
        "what should be added", "is there anything", "is it ok",           "is this ok",
        "giải thích",
        "là gì",
        "tại sao",
        "làm gì",
        "lam gi",
        "để làm gì",
        "de lam gi",
        "dùng để",
        "dung de",
        "hoạt động",
        "hoat dong",
        "nghĩa là",
        "nghia la",             "giai thich",
        "đánh giá",
        "danh gia",
        "tổng thể",
        "tong the",
        "nhận xét",
        "nhan xet",
        "có cần",
        "co can",
        "cần bổ sung",
        "can bo sung",
        "bổ sung thêm gì",
        "bo sung them gi",
        "có thiếu",
        "co thieu",
        "thiếu gì",
        "thieu gi",
        "ok chưa",
        "ok chua",
        "đã ok chưa",
        "da ok chua",
    });
}

pub fn classify(input: RouteInput) TaskIntent {
    if (input.mode == .plan) return .plan_change;

    if (containsAny(input.intent, &.{ "fix", "bug", "error", "fail", "failing", "broken", "crash", "debug", "regression", "validation failed", "lỗi", "sửa lỗi", "hỏng" }))
        return .debug_failure;

    // Read-only questions take priority so they never get misrouted to edit_code
    // just because they mention a verb like "làm" or "do".
    if (isQuestionIntent(input.intent)) {
        if (input.mode == .ask) return .answer_question;
        return .explore_codebase;
    }

    if (containsAny(input.intent, &.{ "screen", "screenshot", "mouse", "keyboard", "điều khiển", "máy tính", "chuột", "bàn phím" }))
        return .computer_control;

    if (input.mode == .agent and containsAny(input.intent, &.{
        "tiep tuc",
        "tiếp tục",
        "lam tiep",
        "làm tiếp",
        "continue",
        "keep going",
        "go on",
    }))
        return .edit_code;

    if (input.mode == .agent and containsAny(input.intent, &.{
        "implement",  "change", "update", "refactor", "add ", "remove", "modify", "rewrite", "create ", "edit ", "patch", "replace ", "build ", "code ",
        "sửa",
        "sua ",
        "thêm",
        "them ",
        "tạo",
        "tao ",
        "xóa",
        "xoa ",
        "chỉnh",
        "chinh ",
        "cập nhật",
        "cap nhat ",
        "viết",
        "viet ",
        "triển khai",
        "trien khai", "lam ",
        "làm ",
    }))
        return .edit_code;

    if (containsAny(input.intent, &.{ "plan", "design", "architecture", "spec", "roadmap", "approach", "strategy", "proposal for" }))
        return .plan_change;

    if (containsAny(input.intent, &.{
        "search",       "find",    "where", "list", "explore", "locate", "show me", "grep", "scan", "xem",
        "tìm",
        "ở đâu",
        "toi dau",
        "tôi đâu",
        "o dau",        "dau roi",
        "đâu rồi",
        "nam o",
        "nằm ở",
        "cho nao",
        "chỗ nào",
        "mat roi",
        "mất rồi",
        "dang toi dau",
        "đang tới đâu",
        "hien tai",
        "hiện tại",
    }))
        return .explore_codebase;

    if (input.mode == .ask) return .answer_question;

    // Agent mode defaults to edit_code so edit/run tools stay available unless the
    // user clearly asked a read-only explanation question (handled above).
    if (input.mode == .agent) return .edit_code;

    return .explore_codebase;
}

pub fn plan(input: RouteInput, base: context_loader.LoadOptions) RoutePlan {
    return planWithIntent(classify(input), input, base);
}

pub fn planWithIntent(
    intent: TaskIntent,
    input: RouteInput,
    base: context_loader.LoadOptions,
) RoutePlan {
    const capability_profile = capabilityForIntent(input.mode, intent);
    const context = applyContextPolicy(intent, input, base);
    return .{
        .intent = intent,
        .capability_profile = capability_profile,
        .context = context,
    };
}

/// True when heuristic classification is uncertain and an LLM arbiter may help.
/// Returns the recommended default max_tool_steps for a given intent.
/// These values are used when the caller has not explicitly set --max-steps.
///
/// | Intent            | Steps | Rationale                                      |
/// |-------------------|-------|------------------------------------------------|
/// | edit_code         |    16 | Read several files + search + write + verify   |
/// | debug_failure     |    20 | Trace + read + search + fix + test cycle       |
/// | plan_change       |    10 | Mostly read + outline, no writes               |
/// | explore_codebase  |     8 | Pure read, bounded by evidence gathering       |
/// | answer_question   |     6 | Read-only, short answer path                   |
pub fn defaultStepsForIntent(intent: TaskIntent) u32 {
    return switch (intent) {
        .edit_code => 16,
        .debug_failure => 20,
        .plan_change => 10,
        .explore_codebase => 8,
        .answer_question => 6,
        .computer_control => 10,
    };
}

pub fn heuristicNeedsLlm(input: RouteInput, heuristic_intent: TaskIntent) bool {
    if (input.mode == .plan or input.mode == .ask) return false;

    if (isQuestionIntent(input.intent)) return false;
    if (heuristic_intent == .debug_failure) return false;
    if (heuristic_intent == .plan_change) return false;
    if (heuristic_intent == .computer_control) return false;

    if (heuristic_intent == .edit_code and hasClearEditVerb(input.intent)) return false;
    if (heuristic_intent == .explore_codebase and hasClearExploreVerb(input.intent)) return false;

    // Agent default edit_code without a clear edit verb is the main ambiguous case.
    if (heuristic_intent == .edit_code) return true;

    // Very short prompts ("tensor.py", "reshape") are hard to classify by keywords.
    if (wordCount(input.intent) <= 2) return true;

    // Mixed signals: question phrasing plus an edit verb.
    if (isQuestionIntent(input.intent) and hasClearEditVerb(input.intent)) return true;

    return false;
}

fn hasClearEditVerb(intent: []const u8) bool {
    return containsAny(intent, &.{
        "implement",  "change",   "update", "refactor", "add ", "remove", "modify", "rewrite", "create ", "edit ", "patch", "replace ", "build ", "code ",
        "sửa",
        "sua ",
        "thêm",
        "them ",
        "tạo",
        "tao ",
        "xóa",
        "xoa ",
        "chỉnh",
        "chinh ",
        "cập nhật",
        "cap nhat ",
        "viết",
        "viet ",
        "triển khai",
        "trien khai", "tiep tuc",
        "tiếp tục",
        "lam tiep",
        "làm tiếp",
        "continue",
    });
}

fn hasClearExploreVerb(intent: []const u8) bool {
    return containsAny(intent, &.{
        "search",       "find",    "where", "list", "explore", "locate", "show me", "grep", "scan", "xem",
        "tìm",
        "ở đâu",
        "toi dau",
        "tôi đâu",
        "o dau",        "dau roi",
        "đâu rồi",
        "nam o",
        "nằm ở",
        "cho nao",
        "chỗ nào",
        "mat roi",
        "mất rồi",
        "dang toi dau",
        "đang tới đâu",
        "hien tai",
        "hiện tại",
    });
}

fn wordCount(text: []const u8) usize {
    var count: usize = 0;
    var in_word = false;
    for (text) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '/') {
            if (!in_word) {
                count += 1;
                in_word = true;
            }
        } else {
            in_word = false;
        }
    }
    return count;
}

/// Least-privilege capability inferred from the classified intent. Question and
/// exploration intents stay read-only so the agent answers instead of forcing a
/// proposal; only edit/debug/plan intents unlock proposing tools.
pub fn capabilityForIntent(mode: tools.Mode, intent: TaskIntent) tools.CapabilityProfile {
    if (mode == .ask or mode == .plan) return .read_only;
    return switch (intent) {
        .answer_question, .explore_codebase => .read_only,
        .edit_code, .debug_failure, .plan_change, .computer_control => .propose_and_task,
    };
}

pub fn applyContextPolicy(
    intent: TaskIntent,
    input: RouteInput,
    base: context_loader.LoadOptions,
) context_loader.LoadOptions {
    var out = base;
    switch (intent) {
        .answer_question => {
            out.include_git_diff = false;
            out.include_diagnostics = false;
            out.include_web = intentNeedsWeb(input.intent);
            out.include_import_graph = input.has_active_file or input.has_selection;
            out.include_agent_memory = true;
            out.retrieval_max_chunks = 16;
            out.recent_file_limit = 12;
        },
        .plan_change => {
            out.include_git_diff = true;
            out.include_semantic_search = true;
            out.include_web = true;
            out.include_agent_memory = true;
            out.include_import_graph = true;
            out.retrieval_max_chunks = 32;
            out.recent_file_limit = 20;
        },
        .edit_code => {
            out.include_git_diff = true;
            out.include_diagnostics = true;
            out.include_import_graph = true;
            out.include_semantic_search = true;
            out.retrieval_max_chunks = 24;
            out.recent_file_limit = 16;
        },
        .debug_failure => {
            out.include_git_diff = true;
            out.include_diagnostics = true;
            out.include_semantic_search = true;
            out.auto_semantic_search = true;
            out.include_import_graph = input.has_active_file;
            out.retrieval_max_chunks = 24;
            out.recent_file_limit = 16;
        },
        .explore_codebase => {
            out.include_git_diff = false;
            out.include_semantic_search = true;
            out.fused_ranking = true;
            out.include_diagnostics = false;
            out.retrieval_max_chunks = 32;
            out.recent_file_limit = 24;
        },
        .computer_control => {
            out.include_git_diff = false;
            out.include_semantic_search = false;
            out.include_diagnostics = false;
            out.retrieval_max_chunks = 0;
            out.recent_file_limit = 0;
            out.include_agent_memory = true;
        },
    }
    return out;
}

pub fn wireAllowedForIntent(wire_name: []const u8, intent: TaskIntent, intent_text: []const u8) bool {
    if (std.mem.eql(u8, wire_name, "remember")) {
        return intent == .plan_change or containsAny(intent_text, &.{ "remember", "note", "preference", "decision" });
    }
    if (std.mem.eql(u8, wire_name, "fetch_url")) {
        return intentNeedsWeb(intent_text) or intent == .plan_change;
    }
    if (std.mem.eql(u8, wire_name, "run_command")) {
        return intent == .debug_failure or intent == .edit_code or intent == .plan_change;
    }
    if (std.mem.eql(u8, wire_name, "replace_file_content")) {
        return intent == .edit_code or intent == .debug_failure or intent == .plan_change;
    }
    for (observationWires()) |wire| {
        if (std.mem.eql(u8, wire, wire_name)) return true;
    }
    return false;
}

pub fn filterDeclarationsForRoute(
    allocator: std.mem.Allocator,
    declarations_json: []const u8,
    profile: tools.CapabilityProfile,
    intent: TaskIntent,
    intent_text: []const u8,
    suppress_codebase_search: bool,
) ![]u8 {
    const Decl = struct {
        name: []const u8,
        description: []const u8 = "",
        parameters: std.json.Value,
    };
    var parsed = try std.json.parseFromSlice([]const Decl, allocator, declarations_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var allowed: std.ArrayList(Decl) = .empty;
    defer allowed.deinit(allocator);
    for (parsed.value) |decl| {
        if (suppress_codebase_search and std.mem.eql(u8, decl.name, "codebase_search")) continue;
        const native_allowed = tool_registry.allowedNativeTool(decl.name, profile) and
            wireAllowedForIntent(decl.name, intent, intent_text);
        const mcp_allowed = tools.idFromWire(decl.name) == null and
            profile == .propose_and_task and
            mcpAllowedForIntent(intent);
        if (native_allowed or mcp_allowed) try allowed.append(allocator, decl);
    }
    return std.json.Stringify.valueAlloc(allocator, allowed.items, .{});
}

pub fn formatToolsSummary(
    buf: []u8,
    profile: tools.CapabilityProfile,
    intent: TaskIntent,
    intent_text: []const u8,
) []const u8 {
    const native_wires = [_][]const u8{
        "search",
        "list_tree",
        "read_file",
        "codebase_search",
        "remember",
        "fetch_url",
        "run_command",
        "replace_file_content",
    };
    var pos: usize = 0;
    var first = true;
    for (native_wires) |wire| {
        if (!tool_registry.allowedNativeTool(wire, profile)) continue;
        if (!wireAllowedForIntent(wire, intent, intent_text)) continue;
        if (!first) {
            if (pos + 1 >= buf.len) break;
            buf[pos] = ',';
            pos += 1;
        }
        const n = @min(wire.len, buf.len - pos);
        @memcpy(buf[pos..][0..n], wire[0..n]);
        pos += n;
        first = false;
    }
    if (profile == .propose_and_task and mcpAllowedForIntent(intent)) {
        if (!first and pos + 5 < buf.len) {
            @memcpy(buf[pos..][0..4], ",mcp");
            pos += 4;
        } else if (first and pos + 3 < buf.len) {
            @memcpy(buf[pos..][0..3], "mcp");
            pos += 3;
        }
    }
    return buf[0..pos];
}

pub fn formatRoutingSummary(
    buf: []u8,
    input: RouteInput,
    route: RoutePlan,
) []const u8 {
    return std.fmt.bufPrint(buf, "mode={s} task={s} profile={s}", .{
        @tagName(input.mode),
        intentLabel(route.intent),
        @tagName(route.capability_profile),
    }) catch "mode=unknown task=unknown profile=unknown";
}

fn mcpAllowedForIntent(intent: TaskIntent) bool {
    return switch (intent) {
        .plan_change, .edit_code, .debug_failure, .computer_control => true,
        else => false,
    };
}

fn observationWires() []const []const u8 {
    return &.{ "search", "list_tree", "read_file", "codebase_search" };
}

fn intentNeedsWeb(intent: []const u8) bool {
    return containsAny(intent, &.{ "http://", "https://", "docs", "documentation", "website", "url" });
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    var lower_buf: [512]u8 = undefined;
    const lower = toLowerBounded(haystack, &lower_buf);
    for (needles) |needle| {
        if (std.mem.indexOf(u8, lower, needle) != null) return true;
    }
    return false;
}

fn toLowerBounded(text: []const u8, buf: []u8) []const u8 {
    const n = @min(text.len, buf.len);
    for (text[0..n], 0..) |c, i| {
        buf[i] = std.ascii.toLower(c);
    }
    return buf[0..n];
}

test "heuristicNeedsLlm skips clear question intents" {
    const input = RouteInput{ .mode = .agent, .intent = "tensor.py lam gi" };
    const intent = classify(input);
    try std.testing.expect(!heuristicNeedsLlm(input, intent));
}

test "heuristicNeedsLlm flags agent default edit_code" {
    const input = RouteInput{ .mode = .agent, .intent = "chat panel scroll behavior" };
    const intent = classify(input);
    try std.testing.expectEqual(TaskIntent.edit_code, intent);
    try std.testing.expect(heuristicNeedsLlm(input, intent));
}

test "heuristicNeedsLlm skips clear edit verbs" {
    const input = RouteInput{ .mode = .agent, .intent = "refactor tensor.py to add reshape" };
    const intent = classify(input);
    try std.testing.expect(!heuristicNeedsLlm(input, intent));
}

test "heuristicNeedsLlm flags very short prompts" {
    const input = RouteInput{ .mode = .agent, .intent = "tensor.py" };
    const intent = classify(input);
    try std.testing.expect(heuristicNeedsLlm(input, intent));
}

test "planWithIntent respects override intent" {
    const route = planWithIntent(.explore_codebase, .{ .mode = .agent, .intent = "tensor.py" }, .{});
    try std.testing.expectEqual(TaskIntent.explore_codebase, route.intent);
    try std.testing.expectEqual(tools.CapabilityProfile.read_only, route.capability_profile);
}

test "classify maps Vietnamese location questions to explore_codebase" {
    const intent = classify(.{ .mode = .agent, .intent = "tiny llm nay toi dau roi" });
    try std.testing.expectEqual(TaskIntent.explore_codebase, intent);
}

test "agent question intent auto-downgrades to read_only" {
    const route = plan(.{ .mode = .agent, .intent = "tiny llm nay toi dau roi" }, .{});
    try std.testing.expectEqual(TaskIntent.explore_codebase, route.intent);
    try std.testing.expectEqual(tools.CapabilityProfile.read_only, route.capability_profile);
}

test "agent edit intent unlocks propose_and_task" {
    const route = plan(.{ .mode = .agent, .intent = "refactor tensor.py to add reshape" }, .{});
    try std.testing.expectEqual(TaskIntent.edit_code, route.intent);
    try std.testing.expectEqual(tools.CapabilityProfile.propose_and_task, route.capability_profile);
}

test "agent 'lam gi' question is read-only not edit" {
    const route = plan(.{ .mode = .agent, .intent = "tensor.py lam gi" }, .{});
    try std.testing.expectEqual(TaskIntent.explore_codebase, route.intent);
    try std.testing.expectEqual(tools.CapabilityProfile.read_only, route.capability_profile);
}

test "agent 'lam gi' with diacritics is read-only" {
    const route = plan(.{ .mode = .agent, .intent = "hàm reshape làm gì" }, .{});
    try std.testing.expectEqual(tools.CapabilityProfile.read_only, route.capability_profile);
}

test "agent Vietnamese assessment question is read-only" {
    const route = plan(.{ .mode = .agent, .intent = "tinh nang lsp trong project co can bo sung them gi khong" }, .{});
    try std.testing.expectEqual(TaskIntent.explore_codebase, route.intent);
    try std.testing.expectEqual(tools.CapabilityProfile.read_only, route.capability_profile);
}

test "agent Vietnamese ok-chua question is read-only" {
    const route = plan(.{ .mode = .agent, .intent = "hay xem tinh nang lsp trong project da ok chua" }, .{});
    try std.testing.expectEqual(TaskIntent.explore_codebase, route.intent);
    try std.testing.expectEqual(tools.CapabilityProfile.read_only, route.capability_profile);
}

test "agent Vietnamese overall assessment is read-only" {
    const route = plan(.{ .mode = .agent, .intent = "danh gia tong the forge ide" }, .{});
    try std.testing.expectEqual(TaskIntent.explore_codebase, route.intent);
    try std.testing.expectEqual(tools.CapabilityProfile.read_only, route.capability_profile);
}

test "classify uses has_selection for agent edit_code hint" {
    const intent = classify(.{ .mode = .agent, .intent = "simplify this", .has_selection = true });
    try std.testing.expectEqual(TaskIntent.edit_code, intent);
}

test "formatToolsSummary omits edit tools for ask explore intent" {
    var buf: [256]u8 = undefined;
    const summary = formatToolsSummary(&buf, .read_only, .explore_codebase, "find all session helpers");
    try std.testing.expect(std.mem.indexOf(u8, summary, "read_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "replace_file_content") == null);
}

test "formatToolsSummary includes edit tools for agent edit intent" {
    var buf: [256]u8 = undefined;
    const summary = formatToolsSummary(&buf, .propose_and_task, .edit_code, "refactor workflow");
    try std.testing.expect(std.mem.indexOf(u8, summary, "replace_file_content") != null);
}

test "classify maps ask mode to answer_question" {
    const intent = classify(.{ .mode = .ask, .intent = "What does this function do?" });
    try std.testing.expectEqual(TaskIntent.answer_question, intent);
}

test "classify maps agent edit verbs to edit_code" {
    const intent = classify(.{ .mode = .agent, .intent = "Refactor workflow.zig to simplify resume" });
    try std.testing.expectEqual(TaskIntent.edit_code, intent);
}

test "classify defaults agent mode without file to edit_code" {
    const intent = classify(.{ .mode = .agent, .intent = "Update the chat panel scroll behavior" });
    try std.testing.expectEqual(TaskIntent.edit_code, intent);
}

test "classify maps failure language to debug_failure" {
    const intent = classify(.{ .mode = .agent, .intent = "Fix the validation failed error after apply" });
    try std.testing.expectEqual(TaskIntent.debug_failure, intent);
}

test "context policy trims git diff for answer_question" {
    const route = plan(.{ .mode = .ask, .intent = "explain session.zig" }, .{});
    try std.testing.expect(!route.context.include_git_diff);
    try std.testing.expectEqual(TaskIntent.answer_question, route.intent);
}

test "route filters edit tools out of ask declarations" {
    const allocator = std.testing.allocator;
    const filtered = try filterDeclarationsForRoute(
        allocator,
        tool_registry.native_declarations_json,
        .read_only,
        .answer_question,
        "explain this file",
        false,
    );
    defer allocator.free(filtered);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "read_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "replace_file_content") == null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "run_command") == null);
}

test "route keeps edit tools for agent edit_code" {
    const allocator = std.testing.allocator;
    const filtered = try filterDeclarationsForRoute(
        allocator,
        tool_registry.native_declarations_json,
        .propose_and_task,
        .edit_code,
        "implement feature",
        false,
    );
    defer allocator.free(filtered);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "replace_file_content") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "run_command") != null);
}

test "route suppresses codebase_search when retrieval preloaded" {
    const allocator = std.testing.allocator;
    const filtered = try filterDeclarationsForRoute(
        allocator,
        tool_registry.native_declarations_json,
        .propose_and_task,
        .explore_codebase,
        "find auth handler",
        true,
    );
    defer allocator.free(filtered);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "codebase_search") == null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "read_file") != null);
}
