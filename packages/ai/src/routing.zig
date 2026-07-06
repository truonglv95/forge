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
    };
}

pub fn classify(input: RouteInput) TaskIntent {
    if (input.mode == .plan) return .plan_change;

    if (containsAny(input.intent, &.{ "fix", "bug", "error", "fail", "failing", "broken", "crash", "debug", "regression", "validation failed" }))
        return .debug_failure;

    if (input.mode == .agent and containsAny(input.intent, &.{ "implement", "change", "update", "refactor", "add ", "remove", "modify", "rewrite", "create ", "edit ", "patch", "replace " }))
        return .edit_code;

    if (containsAny(input.intent, &.{ "plan", "design", "architecture", "spec", "roadmap", "approach", "strategy", "proposal for" }))
        return .plan_change;

    if (containsAny(input.intent, &.{ "search", "find", "where", "list", "explore", "locate", "show me", "grep", "scan" }))
        return .explore_codebase;

    if (input.mode == .ask) return .answer_question;
    if (input.mode == .agent and (input.has_active_file or input.has_selection)) return .edit_code;
    return .explore_codebase;
}

pub fn plan(input: RouteInput, base: context_loader.LoadOptions) RoutePlan {
    const intent = classify(input);
    const capability_profile = tools.profileForMode(input.mode);
    const context = applyContextPolicy(intent, input, base);
    return .{
        .intent = intent,
        .capability_profile = capability_profile,
        .context = context,
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
            out.retrieval_max_chunks = 8;
            out.recent_file_limit = 4;
        },
        .plan_change => {
            out.include_git_diff = true;
            out.include_semantic_search = true;
            out.include_web = true;
            out.include_agent_memory = true;
            out.include_import_graph = true;
            out.retrieval_max_chunks = 16;
        },
        .edit_code => {
            out.include_git_diff = true;
            out.include_diagnostics = true;
            out.include_import_graph = true;
            out.include_semantic_search = true;
            out.retrieval_max_chunks = 12;
        },
        .debug_failure => {
            out.include_git_diff = true;
            out.include_diagnostics = true;
            out.include_semantic_search = false;
            out.auto_semantic_search = false;
            out.include_import_graph = input.has_active_file;
            out.retrieval_max_chunks = 10;
        },
        .explore_codebase => {
            out.include_git_diff = false;
            out.include_semantic_search = true;
            out.fused_ranking = true;
            out.include_diagnostics = false;
            out.retrieval_max_chunks = 16;
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
        return intent == .debug_failure or intent == .edit_code;
    }
    if (std.mem.eql(u8, wire_name, "replace_file_content")) {
        return intent == .edit_code or intent == .debug_failure;
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
        .plan_change, .edit_code, .debug_failure => true,
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
    );
    defer allocator.free(filtered);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "replace_file_content") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "run_command") != null);
}
