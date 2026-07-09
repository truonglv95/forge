const std = @import("std");
const kernel = @import("forge-kernel");
const provider = @import("provider.zig");
const routing = @import("routing.zig");

/// Prefix recognized by providers to route a lightweight JSON classify call.
pub const prompt_marker = "INTENT_CLASSIFIER_MODE";

pub const Options = struct {
    enabled: bool = true,
    confidence_threshold: f32 = 0.7,
};

pub const ResolveResult = struct {
    intent: routing.TaskIntent,
    used_llm: bool,
};

pub fn resolveIntent(
    allocator: std.mem.Allocator,
    input: routing.RouteInput,
    llm: provider.Provider,
    cancel_token: ?*const kernel.cancellation.CancellationToken,
    options: Options,
) ResolveResult {
    const heuristic = routing.classify(input);
    if (!options.enabled) return .{ .intent = heuristic, .used_llm = false };
    if (!routing.heuristicNeedsLlm(input, heuristic)) return .{ .intent = heuristic, .used_llm = false };
    if (cancel_token) |token| {
        if (token.isCancelled()) return .{ .intent = heuristic, .used_llm = false };
    }

    const llm_intent = classifyWithLlm(allocator, llm, input, cancel_token) catch {
        return .{ .intent = heuristic, .used_llm = false };
    };
    if (llm_intent.confidence < options.confidence_threshold) {
        return .{ .intent = heuristic, .used_llm = false };
    }
    return .{ .intent = llm_intent.intent, .used_llm = true };
}

const LlmParse = struct {
    intent: routing.TaskIntent,
    confidence: f32,
};

fn classifyWithLlm(
    allocator: std.mem.Allocator,
    llm: provider.Provider,
    input: routing.RouteInput,
    cancel_token: ?*const kernel.cancellation.CancellationToken,
) !LlmParse {
    const prompt = try buildPrompt(allocator, input);
    defer allocator.free(prompt);

    var cancel_src = kernel.cancellation.CancellationTokenSource.init(allocator) catch return error.OutOfMemory;
    defer cancel_src.deinit();
    const token = cancel_token orelse &cancel_src.getToken();

    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();

    try llm.ask(allocator, prompt, &.{}, &writer.writer, token);

    const raw = writer.writer.buffer[0..writer.writer.end];
    return parseClassifierJson(allocator, raw);
}

fn buildPrompt(allocator: std.mem.Allocator, input: routing.RouteInput) ![]u8 {
    const mode_label = switch (input.mode) {
        .ask => "ask",
        .plan => "plan",
        .agent => "agent",
    };
    return std.fmt.allocPrint(allocator,
        \\{s}
        \\Classify this coding-agent user request. Return ONLY JSON with keys intent and confidence.
        \\
        \\Mode: {s}
        \\intent must be one of:
        \\- answer_question: explain, what/why/how, Vietnamese "là gì/làm gì/giải thích"
        \\- explore_codebase: find/search/locate/where/status, Vietnamese "tìm/ở đâu/đâu rồi/xem"
        \\- edit_code: implement/refactor/add/change/create/update/write/build, Vietnamese "viết/viet/tạo/tao/thêm/them/tiếp tục/tiep tuc"
        \\- debug_failure: fix bug/error/crash/failing
        \\- plan_change: plan/design/architecture/spec
        \\
        \\confidence: 0.0 to 1.0
        \\In agent mode, requests to write/build/implement/continue coding are edit_code, not explore_codebase.
        \\When unsure between explore and edit in agent mode, prefer edit_code if the user wants new code.
        \\
        \\User request: {s}
    , .{ prompt_marker, mode_label, input.intent });
}

fn parseClassifierJson(allocator: std.mem.Allocator, text: []const u8) !LlmParse {
    const candidate = extractFirstJsonObject(allocator, text) orelse text;
    defer if (candidate.ptr != text.ptr) allocator.free(candidate);

    const JsonOut = struct {
        intent: []const u8,
        confidence: ?f64 = null,
    };

    var parsed = std.json.parseFromSlice(JsonOut, allocator, candidate, .{ .ignore_unknown_fields = true }) catch return error.MalformedResponse;
    defer parsed.deinit();

    const intent = parseIntentLabel(parsed.value.intent) orelse return error.MalformedResponse;
    const confidence: f32 = if (parsed.value.confidence) |c| @floatCast(@min(@max(c, 0.0), 1.0)) else 0.85;
    return .{ .intent = intent, .confidence = confidence };
}

fn extractFirstJsonObject(allocator: std.mem.Allocator, text: []const u8) ?[]u8 {
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    const start = std.mem.indexOfScalar(u8, trimmed, '{') orelse return null;

    var depth: i32 = 0;
    var in_string = false;
    var escape = false;

    for (trimmed[start..], 0..) |byte, offset| {
        if (in_string) {
            if (escape) {
                escape = false;
            } else switch (byte) {
                '\\' => escape = true,
                '"' => in_string = false,
                else => {},
            }
            continue;
        }

        switch (byte) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) {
                    const slice = trimmed[start .. start + offset + 1];
                    return allocator.dupe(u8, slice) catch null;
                }
            },
            else => {},
        }
    }

    return null;
}

fn parseIntentLabel(label: []const u8) ?routing.TaskIntent {
    if (std.mem.eql(u8, label, "answer_question")) return .answer_question;
    if (std.mem.eql(u8, label, "explore_codebase")) return .explore_codebase;
    if (std.mem.eql(u8, label, "edit_code")) return .edit_code;
    if (std.mem.eql(u8, label, "debug_failure")) return .debug_failure;
    if (std.mem.eql(u8, label, "plan_change")) return .plan_change;
    return null;
}

test "parseClassifierJson accepts classifier payload" {
    const allocator = std.testing.allocator;
    const parsed = try parseClassifierJson(allocator, "{\"intent\":\"explore_codebase\",\"confidence\":0.92}");
    try std.testing.expectEqual(routing.TaskIntent.explore_codebase, parsed.intent);
    try std.testing.expect(parsed.confidence > 0.9);
}

test "resolveIntent skips llm for clear vietnamese edit" {
    const allocator = std.testing.allocator;
    var fake = @import("fake_provider.zig").FakeProvider.init("{\"intent\":\"explore_codebase\",\"confidence\":0.99}", null, null);
    const llm = fake.providerInterface();

    const result = resolveIntent(
        allocator,
        .{ .mode = .agent, .intent = "tiep tuc viet 1 pytorch mini" },
        llm,
        null,
        .{},
    );
    try std.testing.expect(!result.used_llm);
    try std.testing.expectEqual(routing.TaskIntent.edit_code, result.intent);
}

test "resolveIntent skips llm for clear question" {
    const allocator = std.testing.allocator;
    var fake = @import("fake_provider.zig").FakeProvider.init("{\"intent\":\"edit_code\",\"confidence\":0.99}", null, null);
    const llm = fake.providerInterface();

    const result = resolveIntent(
        allocator,
        .{ .mode = .agent, .intent = "tensor.py lam gi" },
        llm,
        null,
        .{},
    );
    try std.testing.expect(!result.used_llm);
    try std.testing.expectEqual(routing.TaskIntent.explore_codebase, result.intent);
}

test "resolveIntent uses llm for ambiguous agent default" {
    const allocator = std.testing.allocator;
    var fake = @import("fake_provider.zig").FakeProvider.init(
        "{\"intent\":\"explore_codebase\",\"confidence\":0.91}",
        null,
        null,
    );
    const llm = fake.providerInterface();

    const result = resolveIntent(
        allocator,
        .{ .mode = .agent, .intent = "tensor.py" },
        llm,
        null,
        .{},
    );
    try std.testing.expect(result.used_llm);
    try std.testing.expectEqual(routing.TaskIntent.explore_codebase, result.intent);
}

test "resolveIntent falls back when llm confidence is low" {
    const allocator = std.testing.allocator;
    var fake = @import("fake_provider.zig").FakeProvider.init(
        "{\"intent\":\"edit_code\",\"confidence\":0.2}",
        null,
        null,
    );
    const llm = fake.providerInterface();

    const input = routing.RouteInput{ .mode = .agent, .intent = "tensor.py" };
    const heuristic = routing.classify(input);
    const result = resolveIntent(allocator, input, llm, null, .{});
    try std.testing.expect(!result.used_llm);
    try std.testing.expectEqual(heuristic, result.intent);
}
