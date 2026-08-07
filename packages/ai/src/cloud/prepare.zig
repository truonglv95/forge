//! Forge Cloud agent-prepare client — calls POST /functions/v1/agent-prepare
//! to get a multi-step plan + tool suggestions before the main LLM call.
//!
//! Phase A lab: validate whether backend-driven intent enrichment +
//! planning improves agent success rate vs the client's native heuristic.
//!
//! When the backend is unreachable or returns used_llm=false, the caller
//! falls back to its native routing.zig heuristic (graceful degradation).

const std = @import("std");
const cloud_config = @import("config.zig");

pub const PrepareError = error{
    NetworkError,
    AuthenticationFailed,
    NotConfigured,
    MalformedResponse,
    OutOfMemory,
    QuotaExceeded,
    Timeout,
};

/// A single step in the agent's plan returned by the backend.
pub const PlanStep = struct {
    allocator: std.mem.Allocator,
    step: u32,
    goal: []u8,
    suggested_tools: [][]u8,
    context_needed: [][]u8,

    pub fn deinit(self: *PlanStep) void {
        self.allocator.free(self.goal);
        for (self.suggested_tools) |t| self.allocator.free(t);
        self.allocator.free(self.suggested_tools);
        for (self.context_needed) |c| self.allocator.free(c);
        self.allocator.free(self.context_needed);
        self.* = undefined;
    }
};

/// Response from the agent-prepare endpoint.
pub const PrepareResponse = struct {
    allocator: std.mem.Allocator,
    intent: []u8,
    confidence: f32,
    plan: []PlanStep,
    suggested_tools: [][]u8,
    used_llm: bool,
    latency_ms: u64,

    pub fn deinit(self: *PrepareResponse) void {
        self.allocator.free(self.intent);
        for (self.plan) |*s| s.deinit();
        self.allocator.free(self.plan);
        for (self.suggested_tools) |t| self.allocator.free(t);
        self.allocator.free(self.suggested_tools);
        self.* = undefined;
    }
};

/// Request body sent to /functions/v1/agent-prepare.
pub const PrepareRequest = struct {
    intent: []const u8,
    active_file: ?[]const u8 = null,
    workspace_files: []const []const u8 = &.{},
    client_intent_guess: ?[]const u8 = null,
};

/// Call the agent-prepare endpoint.
///
/// `access_token` is the user's JWT (from `forge cloud login`). May be
/// empty — the backend returns heuristic-only results when unauthenticated.
pub fn prepare(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: cloud_config.CloudConfig,
    access_token: []const u8,
    request: PrepareRequest,
) PrepareError!PrepareResponse {
    if (!cloud_config.isConfigured(config)) return PrepareError.NotConfigured;

    const url = try config.agentPrepareUrl(allocator);
    defer allocator.free(url);

    // Build JSON request body.
    const escaped_intent = jsonEscape(allocator, request.intent) catch
        return PrepareError.OutOfMemory;
    defer allocator.free(escaped_intent);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    body.appendSlice(allocator, "{\"intent\":") catch return PrepareError.OutOfMemory;
    body.appendSlice(allocator, escaped_intent) catch return PrepareError.OutOfMemory;

    if (request.active_file) |af| {
        const escaped_af = jsonEscape(allocator, af) catch return PrepareError.OutOfMemory;
        defer allocator.free(escaped_af);
        body.appendSlice(allocator, ",\"active_file\":") catch return PrepareError.OutOfMemory;
        body.appendSlice(allocator, escaped_af) catch return PrepareError.OutOfMemory;
    }

    if (request.client_intent_guess) |g| {
        const escaped_g = jsonEscape(allocator, g) catch return PrepareError.OutOfMemory;
        defer allocator.free(escaped_g);
        body.appendSlice(allocator, ",\"client_intent_guess\":") catch return PrepareError.OutOfMemory;
        body.appendSlice(allocator, escaped_g) catch return PrepareError.OutOfMemory;
    }

    if (request.workspace_files.len > 0) {
        body.appendSlice(allocator, ",\"workspace_files\":[") catch return PrepareError.OutOfMemory;
        for (request.workspace_files, 0..) |wf, i| {
            if (i > 0) body.appendSlice(allocator, ",") catch return PrepareError.OutOfMemory;
            const escaped_wf = jsonEscape(allocator, wf) catch return PrepareError.OutOfMemory;
            defer allocator.free(escaped_wf);
            body.appendSlice(allocator, escaped_wf) catch return PrepareError.OutOfMemory;
        }
        body.appendSlice(allocator, "]") catch return PrepareError.OutOfMemory;
    }

    body.appendSlice(allocator, "}") catch return PrepareError.OutOfMemory;

    // Build headers. Auth is optional — empty token = heuristic-only.
    var auth_header_buf: [256]u8 = undefined;
    const auth_header = if (access_token.len > 0)
        std.fmt.bufPrint(&auth_header_buf, "Bearer {s}", .{access_token}) catch return PrepareError.OutOfMemory
    else
        "";
    const apikey_header = if (config.anon_key.len > 0) config.anon_key else "";

    var headers_buf: [2]std.http.Header = undefined;
    var headers_len: usize = 0;
    if (auth_header.len > 0) {
        headers_buf[headers_len] = .{ .name = "Authorization", .value = auth_header };
        headers_len += 1;
    }
    if (apikey_header.len > 0) {
        headers_buf[headers_len] = .{ .name = "apikey", .value = apikey_header };
        headers_len += 1;
    }

    var response_alloc = std.Io.Writer.Allocating.init(allocator);
    defer response_alloc.deinit();

    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body.items,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .extra_headers = headers_buf[0..headers_len],
        .response_writer = &response_alloc.writer,
    }) catch return PrepareError.NetworkError;

    const resp_body = response_alloc.writer.buffer[0..response_alloc.writer.end];

    return switch (result.status) {
        .ok => parsePrepareResponse(allocator, resp_body),
        .unauthorized, .forbidden => PrepareError.AuthenticationFailed,
        .too_many_requests => PrepareError.QuotaExceeded,
        .request_timeout => PrepareError.Timeout,
        else => PrepareError.NetworkError,
    };
}

fn parsePrepareResponse(allocator: std.mem.Allocator, body: []const u8) PrepareError!PrepareResponse {
    if (body.len == 0) return PrepareError.MalformedResponse;

    const Parsed = struct {
        intent: []const u8,
        confidence: f64 = 0,
        plan: []struct {
            step: u32 = 0,
            goal: []const u8 = "",
            suggested_tools: [][]const u8 = &.{},
            context_needed: [][]const u8 = &.{},
        } = &.{},
        suggested_tools: [][]const u8 = &.{},
        used_llm: bool = false,
        latency_ms: u64 = 0,
    };

    var parsed = std.json.parseFromSlice(Parsed, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch return PrepareError.MalformedResponse;
    defer parsed.deinit();

    const v = parsed.value;

    // Own the intent string.
    const owned_intent = allocator.dupe(u8, v.intent) catch return PrepareError.OutOfMemory;
    errdefer allocator.free(owned_intent);

    // Own the plan steps.
    const plan = allocator.alloc(PlanStep, v.plan.len) catch return PrepareError.OutOfMemory;
    var plan_written: usize = 0;
    errdefer {
        for (plan[0..plan_written]) |*s| s.deinit();
        allocator.free(plan);
    }
    for (v.plan) |s| {
        const owned_goal = allocator.dupe(u8, s.goal) catch return PrepareError.OutOfMemory;
        const owned_tools = dupeStringSlice(allocator, s.suggested_tools) catch {
            allocator.free(owned_goal);
            return PrepareError.OutOfMemory;
        };
        const owned_ctx = dupeStringSlice(allocator, s.context_needed) catch {
            for (owned_tools) |t| allocator.free(t);
            allocator.free(owned_tools);
            allocator.free(owned_goal);
            return PrepareError.OutOfMemory;
        };
        plan[plan_written] = .{
            .allocator = allocator,
            .step = s.step,
            .goal = owned_goal,
            .suggested_tools = owned_tools,
            .context_needed = owned_ctx,
        };
        plan_written += 1;
    }

    // Own the top-level suggested_tools.
    const owned_suggested = dupeStringSlice(allocator, v.suggested_tools) catch return PrepareError.OutOfMemory;
    errdefer {
        for (owned_suggested) |t| allocator.free(t);
        allocator.free(owned_suggested);
    }

    return PrepareResponse{
        .allocator = allocator,
        .intent = owned_intent,
        .confidence = @floatCast(v.confidence),
        .plan = plan,
        .suggested_tools = owned_suggested,
        .used_llm = v.used_llm,
        .latency_ms = v.latency_ms,
    };
}

fn dupeStringSlice(allocator: std.mem.Allocator, src: [][]const u8) ![][]u8 {
    const out = try allocator.alloc([]u8, src.len);
    var written: usize = 0;
    errdefer {
        for (out[0..written]) |s| allocator.free(s);
        allocator.free(out);
    }
    for (src) |s| {
        out[written] = try allocator.dupe(u8, s);
        written += 1;
    }
    return out;
}

/// Escape a string for JSON (wraps in quotes, escapes special chars).
fn jsonEscape(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '"');
    for (text) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\\u{x:0>4}", .{c}));
                } else {
                    try out.append(allocator, c);
                }
            },
        }
    }
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

// ─── Tests ─────────────────────────────────────────────────────────────

test "parsePrepareResponse parses valid response" {
    const body =
        \\{"intent":"refactor","confidence":0.9,"plan":[{"step":1,"goal":"Read file","suggested_tools":["read_file"],"context_needed":["src/main.ts"]}],"suggested_tools":["read_file","search","multi_edit"],"used_llm":true,"latency_ms":850}
    ;
    var resp = try parsePrepareResponse(std.testing.allocator, body);
    defer resp.deinit();

    try std.testing.expectEqualStrings("refactor", resp.intent);
    try std.testing.expectEqual(@as(f32, 0.9), resp.confidence);
    try std.testing.expectEqual(@as(usize, 1), resp.plan.len);
    try std.testing.expectEqual(@as(u32, 1), resp.plan[0].step);
    try std.testing.expectEqualStrings("Read file", resp.plan[0].goal);
    try std.testing.expectEqual(@as(usize, 1), resp.plan[0].suggested_tools.len);
    try std.testing.expectEqualStrings("read_file", resp.plan[0].suggested_tools[0]);
    try std.testing.expect(resp.used_llm);
    try std.testing.expectEqual(@as(u64, 850), resp.latency_ms);
}

test "parsePrepareResponse handles empty plan" {
    const body =
        \\{"intent":"answer_question","confidence":0.75,"plan":[],"suggested_tools":["read_file"],"used_llm":false,"latency_ms":0}
    ;
    var resp = try parsePrepareResponse(std.testing.allocator, body);
    defer resp.deinit();
    try std.testing.expectEqual(@as(usize, 0), resp.plan.len);
    try std.testing.expect(!resp.used_llm);
}

test "parsePrepareResponse rejects empty body" {
    try std.testing.expectError(PrepareError.MalformedResponse, parsePrepareResponse(std.testing.allocator, ""));
}

test "parsePrepareResponse rejects malformed JSON" {
    try std.testing.expectError(PrepareError.MalformedResponse, parsePrepareResponse(std.testing.allocator, "not json"));
}

test "jsonEscape escapes special characters" {
    const escaped = try jsonEscape(std.testing.allocator, "hello\n\"world\"");
    defer std.testing.allocator.free(escaped);
    try std.testing.expectEqualStrings("\"hello\\n\\\"world\\\"\"", escaped);
}
