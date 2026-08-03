const std = @import("std");
const core_provider = @import("../../provider.zig");
const provider = @import("../../provider.zig");
const credentials = @import("../../credentials.zig");
const kernel = @import("forge-kernel");
const retry = @import("../../retry.zig");
const gemini_sse = @import("sse.zig");
const agent_turn = @import("../../agent/turn.zig");
const mcp_registry = @import("../../mcp_registry.zig");
const gemini_transport = @import("tool_transport.zig");

// default_model removed
pub const test_mode_prompt = "test_mode";

const endpoint_base = "https://generativelanguage.googleapis.com/v1beta/models/";

const GeminiPart = struct {
    text: ?[]const u8 = null,
    inlineData: ?struct {
        mimeType: []const u8,
        data: []const u8,
    } = null,
};
const GeminiContent = struct { parts: []const GeminiPart };
const GeminiThinkingConfig = struct {
    includeThoughts: bool = true,
};
const GeminiGenerationConfig = struct {
    temperature: f32,
    responseMimeType: []const u8,
    thinkingConfig: GeminiThinkingConfig,
};
const GeminiRequestPayload = struct {
    contents: []const GeminiContent,
    generationConfig: GeminiGenerationConfig,
};

pub const GeminiProvider = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    creds: credentials.Credentials,
    model_name: []const u8,
    meta: provider.ModelMetadata,
    latest_usage: provider.TokenUsage,
    stream_callback: ?*const fn (?*anyopaque, []const u8) void = null,
    stream_context: ?*anyopaque = null,
    thinking_callback: ?*const fn (?*anyopaque, []const u8) void = null,
    thinking_context: ?*anyopaque = null,

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ_map: ?*const std.process.Environ.Map,
        options: anytype,
    ) !provider.Provider {
        const creds = credentials.Credentials.load(
            allocator,
            io,
            environ_map,
            &[_][]const u8{ "GEMINI_API_KEY", "GOOGLE_API_KEY" },
            "forge-gemini",
            "default",
        ) catch |err| switch (err) {
            error.NotFound => return error.MissingCredentials,
            else => return err,
        };

        const ptr = try allocator.create(GeminiProvider);
        ptr.* = .{
            .allocator = allocator,
            .io = io,
            .creds = creds,
            .model_name = if (@hasField(@TypeOf(options), "model")) (if (@typeInfo(@TypeOf(options.model)) == .optional) options.model orelse return error.ModelRequired else options.model) else return error.ModelRequired,
            .meta = .{
                .provider_name = "gemini",
                .model_name = if (@hasField(@TypeOf(options), "model")) (if (@typeInfo(@TypeOf(options.model)) == .optional) options.model orelse return error.ModelRequired else options.model) else return error.ModelRequired,
                .context_window = 1_048_576,
            },
            .latest_usage = .{},
            .stream_callback = if (@hasField(@TypeOf(options), "stream_callback")) options.stream_callback else null,
            .stream_context = if (@hasField(@TypeOf(options), "stream_context")) options.stream_context else null,
            .thinking_callback = if (@hasField(@TypeOf(options), "thinking_callback")) options.thinking_callback else null,
            .thinking_context = if (@hasField(@TypeOf(options), "thinking_context")) options.thinking_context else null,
        };
        return ptr.providerInterface();
    }

    pub fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *GeminiProvider = @ptrCast(@alignCast(ptr));
        self.creds.deinit();
        allocator.destroy(self);
    }

    pub fn providerInterface(self: *GeminiProvider) provider.Provider {
        return .{
            .ptr = self,
            .vtable = &.{
                .ask = askImpl,
                .metadata = metadataImpl,
                .usage = usageImpl,
                .supports_tool_loop = supportsToolLoopImpl,
                .complete_turn = completeTurnImpl,
                .tool_declarations_json = toolDeclarationsJsonImpl,
                .append_tool_user_text = appendToolUserTextImpl,
                .append_tool_call = appendToolCallImpl,
                .append_tool_result = appendToolResultImpl,
                .deinit = deinit,
            },
        };
    }

    fn askImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        prompt: []const u8,
        images: []const core_provider.ImagePart,
        writer: *std.Io.Writer,
        cancel_token: *const kernel.cancellation.CancellationToken,
    ) provider.ProviderError!void {
        const self: *GeminiProvider = @ptrCast(@alignCast(ptr));

        if (cancel_token.isCancelled()) return provider.ProviderError.NetworkError;

        if (std.mem.eql(u8, prompt, test_mode_prompt)) {
            self.latest_usage = .{ .prompt_tokens = 5, .completion_tokens = 10, .total_tokens = 15 };
            writer.writeAll("{\"schema_version\":1,\"summary\":\"test\",\"workspace_edit\":{\"files\":[]}}") catch return provider.ProviderError.NetworkError;
            return;
        }

        const payload = buildRequestPayload(allocator, prompt, images) catch return provider.ProviderError.ProviderInternalError;
        defer allocator.free(payload);

        const endpoint = buildStreamEndpoint(allocator, self.model_name) catch return provider.ProviderError.ProviderInternalError;
        defer allocator.free(endpoint);

        const api_headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "x-goog-api-key", .value = self.creds.api_key },
        };

        const policy = retry.RetryPolicy{
            .max_attempts = 3,
            .base_delay_ms = 500,
            .max_delay_ms = 4000,
        };
        var prng = std.Random.DefaultPrng.init(@intCast(std.Io.Timestamp.now(self.io, .real).toMilliseconds()));

        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            if (cancel_token.isCancelled()) return provider.ProviderError.NetworkError;

            if (attempt > 0) {
                const delay_ms = retry.nextDelay(policy, attempt, &prng);
                if (delay_ms > 0) {
                    var waited: u32 = 0;
                    while (waited < delay_ms) {
                        if (cancel_token.isCancelled()) return provider.ProviderError.NetworkError;
                        const slice: u32 = @min(50, delay_ms - waited);
                        std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(@intCast(slice)), .real) catch {};
                        waited += slice;
                    }
                }
            }

            var bridge = SseBridge{ .provider = self };
            var sse_parser = gemini_sse.Parser.init(allocator, .{
                .on_chunk = SseBridge.onChunk,
                .context = &bridge,
            });
            defer sse_parser.deinit();

            var client = std.http.Client{
                .allocator = allocator,
                .io = self.io,
            };
            defer client.deinit();

            const result = client.fetch(.{
                .location = .{ .url = endpoint },
                .method = .POST,
                .payload = payload,
                .headers = .{
                    .content_type = .{ .override = "application/json" },
                },
                .extra_headers = &api_headers,
                .response_writer = sse_parser.ioWriter(),
            }) catch return provider.ProviderError.NetworkError;

            sse_parser.releaseWriter();

            const mapped = mapHttpStatus(result.status);
            if (mapped == .retry and attempt + 1 < policy.max_attempts) continue;
            if (mapped != .ok) return mapped.toProviderError();

            const parsed = parseStreamResult(self, allocator, &sse_parser, writer) catch |err| switch (err) {
                error.AuthenticationFailed => return provider.ProviderError.AuthenticationFailed,
                error.RateLimitExceeded => return provider.ProviderError.RateLimitExceeded,
                error.MalformedResponse => {
                    std.log.err("parseStreamResult returned MalformedResponse. Assembled text length: {d}", .{sse_parser.assembled.items.len});
                    return provider.ProviderError.MalformedResponse;
                },
            };
            defer allocator.free(parsed);
            if (parsed.len == 0) {
                std.log.err("Parsed response length is 0. Raw assembled text: {s}", .{sse_parser.assembled.items});
                return provider.ProviderError.MalformedResponse;
            }
            return;
        }
    }

    fn parseStreamResult(
        self: *GeminiProvider,
        allocator: std.mem.Allocator,
        sse_parser: *gemini_sse.Parser,
        writer: *std.Io.Writer,
    ) gemini_sse.ParseError![]u8 {
        try sse_parser.finish();
        if (sse_parser.terminal_error) |err| return switch (err) {
            error.AuthenticationFailed => error.AuthenticationFailed,
            error.RateLimitExceeded => error.RateLimitExceeded,
            else => error.MalformedResponse,
        };

        self.latest_usage = sse_parser.latest_usage;
        const normalized = stripMarkdownFence(allocator, sse_parser.assembledText()) catch return error.MalformedResponse;
        writer.writeAll(normalized) catch return error.MalformedResponse;
        return normalized;
    }

    const SseBridge = struct {
        provider: *GeminiProvider,

        fn onChunk(context: ?*anyopaque, kind: gemini_sse.ChunkKind, chunk: []const u8) void {
            const bridge: *SseBridge = @ptrCast(@alignCast(context.?));
            switch (kind) {
                .thought => if (bridge.provider.thinking_callback) |callback| {
                    callback(bridge.provider.thinking_context, chunk);
                },
                .text => if (bridge.provider.stream_callback) |callback| {
                    callback(bridge.provider.stream_context, chunk);
                },
            }
        }
    };

    fn metadataImpl(ptr: *const anyopaque) provider.ModelMetadata {
        const self: *const GeminiProvider = @ptrCast(@alignCast(ptr));
        return self.meta;
    }

    fn usageImpl(ptr: *const anyopaque) provider.TokenUsage {
        const self: *const GeminiProvider = @ptrCast(@alignCast(ptr));
        return self.latest_usage;
    }

    fn toolTransportState(self: *GeminiProvider, io: std.Io, mcp: ?*mcp_registry.Registry) gemini_transport.GeminiTransport {
        return .{ .gemini = self, .io = io, .mcp = mcp };
    }

    fn supportsToolLoopImpl(_: *const anyopaque) bool {
        return true;
    }

    fn completeTurnImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        mcp: ?*mcp_registry.Registry,
        conversation_json: []const u8,
        tool_declarations_json: []const u8,
        cancel_token: ?*const kernel.cancellation.CancellationToken,
    ) provider.ProviderError!agent_turn.Completion {
        const self: *GeminiProvider = @ptrCast(@alignCast(ptr));
        var transport_state = self.toolTransportState(io, mcp);
        return transport_state.transport().complete(allocator, conversation_json, tool_declarations_json, cancel_token) catch |err| return provider.mapTransportError(err);
    }

    fn toolDeclarationsJsonImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        mcp: ?*mcp_registry.Registry,
    ) provider.ProviderError![]const u8 {
        const self: *GeminiProvider = @ptrCast(@alignCast(ptr));
        const transport_state = self.toolTransportState(undefined, mcp);
        return transport_state.declarationsJson(allocator) catch return error.ProviderInternalError;
    }

    fn appendToolUserTextImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        conversation: *std.ArrayList(u8),
        text: []const u8,
    ) provider.ProviderError!void {
        const self: *GeminiProvider = @ptrCast(@alignCast(ptr));
        var transport_state = self.toolTransportState(undefined, null);
        return transport_state.transport().appendUserText(allocator, conversation, text) catch |err| return provider.mapTransportError(err);
    }

    fn appendToolCallImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        conversation: *std.ArrayList(u8),
        call: agent_turn.ToolCall,
    ) provider.ProviderError!void {
        const self: *GeminiProvider = @ptrCast(@alignCast(ptr));
        var transport_state = self.toolTransportState(undefined, null);
        return transport_state.transport().appendToolCall(allocator, conversation, call) catch |err| return provider.mapTransportError(err);
    }

    fn appendToolResultImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        conversation: *std.ArrayList(u8),
        tool_name: []const u8,
        result: []const u8,
        images: []const core_provider.ImagePart,
    ) provider.ProviderError!void {
        const self: *GeminiProvider = @ptrCast(@alignCast(ptr));
        var transport_state = self.toolTransportState(undefined, null);
        return transport_state.transport().appendToolResult(allocator, conversation, tool_name, result, images) catch |err| return provider.mapTransportError(err);
    }
};

const StatusAction = enum {
    ok,
    retry,
    auth_failed,
    rate_limited,
    context_exceeded,
    provider_error,
    malformed,

    fn toProviderError(self: StatusAction) provider.ProviderError {
        return switch (self) {
            .ok => unreachable,
            .retry => provider.ProviderError.NetworkError,
            .auth_failed => provider.ProviderError.AuthenticationFailed,
            .rate_limited => provider.ProviderError.RateLimitExceeded,
            .context_exceeded => provider.ProviderError.ContextLengthExceeded,
            .provider_error => provider.ProviderError.ProviderInternalError,
            .malformed => provider.ProviderError.MalformedResponse,
        };
    }
};

fn mapHttpStatus(status: std.http.Status) StatusAction {
    return switch (status) {
        .ok => .ok,
        .unauthorized, .forbidden => .auth_failed,
        .too_many_requests => .rate_limited,
        .request_timeout, .service_unavailable, .bad_gateway, .gateway_timeout, .internal_server_error => .retry,
        .payload_too_large, .uri_too_long => .context_exceeded,
        else => .provider_error,
    };
}

fn buildStreamEndpoint(allocator: std.mem.Allocator, model_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}:streamGenerateContent?alt=sse", .{ endpoint_base, model_name });
}

fn buildEndpoint(allocator: std.mem.Allocator, model_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}:generateContent", .{ endpoint_base, model_name });
}

fn buildRequestPayload(allocator: std.mem.Allocator, prompt: []const u8, images: []const provider.ImagePart) ![]u8 {
    const response_mime = if (std.mem.indexOf(u8, prompt, "MARKDOWN PLAN MODE") != null)
        "text/plain"
    else
        "application/json";

    var parts: std.ArrayList(GeminiPart) = .empty;
    defer parts.deinit(allocator);

    for (images) |image| {
        try parts.append(allocator, .{
            .inlineData = .{
                .mimeType = image.mime_type,
                .data = image.data_base64,
            },
        });
    }
    try parts.append(allocator, .{ .text = prompt });

    const owned_parts = try parts.toOwnedSlice(allocator);
    defer allocator.free(owned_parts);

    const content = GeminiContent{ .parts = owned_parts };

    return try std.json.Stringify.valueAlloc(allocator, GeminiRequestPayload{
        .contents = &[_]GeminiContent{content},
        .generationConfig = .{
            .temperature = 0.2,
            .responseMimeType = response_mime,
            .thinkingConfig = .{ .includeThoughts = true },
        },
    }, .{});
}

const GenerateResponse = struct {
    candidates: ?[]Candidate = null,
    usageMetadata: ?UsageMetadata = null,
    @"error": ?ApiError = null,

    const Candidate = struct {
        content: ?struct {
            parts: ?[]Part = null,
        } = null,
    };

    const Part = struct {
        text: ?[]const u8 = null,
        thought: ?bool = null,
    };

    const UsageMetadata = struct {
        promptTokenCount: ?i64 = null,
        candidatesTokenCount: ?i64 = null,
        totalTokenCount: ?i64 = null,
    };

    const ApiError = struct {
        code: ?i64 = null,
        message: ?[]const u8 = null,
        status: ?[]const u8 = null,
    };
};

pub fn normalizeModelText(allocator: std.mem.Allocator, response_body: []const u8) (error{ AuthenticationFailed, RateLimitExceeded, MalformedResponse }![]u8) {
    var parsed = std.json.parseFromSlice(GenerateResponse, allocator, response_body, .{
        .ignore_unknown_fields = true,
    }) catch return error.MalformedResponse;
    defer parsed.deinit();

    if (parsed.value.@"error") |api_err| {
        if (api_err.status) |status| {
            if (std.mem.eql(u8, status, "UNAUTHENTICATED")) return error.AuthenticationFailed;
            if (std.mem.eql(u8, status, "RESOURCE_EXHAUSTED")) return error.RateLimitExceeded;
        }
        return error.MalformedResponse;
    }

    const candidates = parsed.value.candidates orelse return error.MalformedResponse;
    if (candidates.len == 0) return error.MalformedResponse;

    const content = candidates[0].content orelse return error.MalformedResponse;
    const parts = content.parts orelse return error.MalformedResponse;
    if (parts.len == 0) return error.MalformedResponse;
    const text = parts[0].text orelse return error.MalformedResponse;

    return stripMarkdownFence(allocator, text) catch return error.MalformedResponse;
}

pub fn extractUsage(allocator: std.mem.Allocator, response_body: []const u8) !provider.TokenUsage {
    var parsed = try std.json.parseFromSlice(GenerateResponse, allocator, response_body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const usage = parsed.value.usageMetadata orelse return .{};
    return .{
        .prompt_tokens = if (usage.promptTokenCount) |v| @intCast(v) else 0,
        .completion_tokens = if (usage.candidatesTokenCount) |v| @intCast(v) else 0,
        .total_tokens = if (usage.totalTokenCount) |v| @intCast(v) else 0,
    };
}

pub fn stripMarkdownFence(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "```")) return try allocator.dupe(u8, trimmed);

    const line_end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return try allocator.dupe(u8, trimmed);
    trimmed = std.mem.trim(u8, trimmed[line_end + 1 ..], " \t\r\n");

    if (std.mem.endsWith(u8, trimmed, "```")) {
        const fence = std.mem.lastIndexOf(u8, trimmed, "```") orelse return try allocator.dupe(u8, trimmed);
        trimmed = std.mem.trim(u8, trimmed[0..fence], " \t\r\n");
    }

    return try allocator.dupe(u8, trimmed);
}

test "GeminiProvider test mode" {
    const allocator = std.testing.allocator;

    const dummy_key = try allocator.alloc(u8, 4);
    std.mem.copyForwards(u8, dummy_key, "test");

    const creds = credentials.Credentials{
        .allocator = allocator,
        .api_key = dummy_key,
        .source = .environment,
    };

    // GeminiProvider takes ownership of credentials.
    const ptr = try allocator.create(GeminiProvider);
    ptr.* = GeminiProvider{
        .allocator = allocator,
        .io = std.testing.io,
        .creds = creds,
        .model_name = "test-model",
        .meta = .{
            .provider_name = "gemini",
            .model_name = "test-model",
            .context_window = 1_048_576,
        },
        .latest_usage = .{},
        .stream_callback = null,
        .stream_context = null,
        .thinking_callback = null,
        .thinking_context = null,
    };
    var p = ptr.providerInterface();
    defer p.deinit(allocator);

    var w_alloc = std.Io.Writer.Allocating.init(allocator);
    defer w_alloc.deinit();

    var cancel_src = try kernel.cancellation.CancellationTokenSource.init(allocator);
    defer cancel_src.deinit();

    try p.ask(allocator, test_mode_prompt, &.{}, &w_alloc.writer, &cancel_src.getToken());

    const out = w_alloc.writer.buffer[0..w_alloc.writer.end];
    try std.testing.expect(std.mem.indexOf(u8, out, "schema_version") != null);

    const meta = p.metadata();
    try std.testing.expectEqualStrings("gemini", meta.provider_name);
}

test "normalizeModelText parses Gemini JSON envelope" {
    const allocator = std.testing.allocator;
    const fixture =
        \\{"candidates":[{"content":{"parts":[{"text":"{\"schema_version\":1}"}]}}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":20,"totalTokenCount":30}}
    ;

    const text = try normalizeModelText(allocator, fixture);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("{\"schema_version\":1}", text);

    const usage = try extractUsage(allocator, fixture);
    try std.testing.expectEqual(@as(usize, 10), usage.prompt_tokens);
    try std.testing.expectEqual(@as(usize, 20), usage.completion_tokens);
}

test "stripMarkdownFence removes code fences" {
    const allocator = std.testing.allocator;
    const fenced =
        \\```json
        \\{"ok":true}
        \\```
    ;
    const text = try stripMarkdownFence(allocator, fenced);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("{\"ok\":true}", text);
}
