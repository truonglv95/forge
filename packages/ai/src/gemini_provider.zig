const std = @import("std");
const provider = @import("provider.zig");
const credentials = @import("credentials.zig");
const kernel = @import("forge-kernel");
const retry = @import("retry.zig");
const streaming = @import("streaming.zig");

pub const default_model = "gemini-2.0-flash";
pub const test_mode_prompt = "test_mode";

const endpoint_base = "https://generativelanguage.googleapis.com/v1beta/models/";

const GeminiPart = struct { text: []const u8 };
const GeminiContent = struct { parts: []const GeminiPart };
const GeminiGenerationConfig = struct {
    temperature: f32,
    responseMimeType: []const u8,
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

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        creds: credentials.Credentials,
        model_name: []const u8,
        stream_callback: ?*const fn (?*anyopaque, []const u8) void,
        stream_context: ?*anyopaque,
    ) GeminiProvider {
        return .{
            .allocator = allocator,
            .io = io,
            .creds = creds,
            .model_name = model_name,
            .meta = .{
                .provider_name = "gemini",
                .model_name = model_name,
                .context_window = 1_048_576,
            },
            .latest_usage = .{},
            .stream_callback = stream_callback,
            .stream_context = stream_context,
        };
    }

    pub fn deinit(self: *GeminiProvider) void {
        self.creds.deinit();
    }

    pub fn providerInterface(self: *GeminiProvider) provider.Provider {
        return .{
            .ptr = self,
            .vtable = &.{
                .ask = askImpl,
                .metadata = metadataImpl,
                .usage = usageImpl,
            },
        };
    }

    fn askImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        prompt: []const u8,
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

        const payload = buildRequestPayload(allocator, prompt) catch return provider.ProviderError.ProviderInternalError;
        defer allocator.free(payload);

        const endpoint = buildEndpoint(allocator, self.model_name) catch return provider.ProviderError.ProviderInternalError;
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

        var body = std.Io.Writer.Allocating.init(allocator);
        defer body.deinit();

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

            body.writer.end = 0;

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
                .response_writer = &body.writer,
            }) catch return provider.ProviderError.NetworkError;

            const mapped = mapHttpStatus(result.status);
            if (mapped == .retry and attempt + 1 < policy.max_attempts) continue;
            if (mapped != .ok) return mapped.toProviderError();

            const response_text = body.writer.buffer[0..body.writer.end];
            const normalized = normalizeModelText(allocator, response_text) catch |err| switch (err) {
                error.AuthenticationFailed => return provider.ProviderError.AuthenticationFailed,
                error.RateLimitExceeded => return provider.ProviderError.RateLimitExceeded,
                else => return provider.ProviderError.MalformedResponse,
            };
            defer allocator.free(normalized);
            self.latest_usage = extractUsage(allocator, response_text) catch .{};
            try streaming.writeChunks(normalized, writer, cancel_token, .{
                .on_chunk = self.stream_callback,
                .on_chunk_context = self.stream_context,
            });
            return;
        }
    }

    fn metadataImpl(ptr: *const anyopaque) provider.ModelMetadata {
        const self: *const GeminiProvider = @ptrCast(@alignCast(ptr));
        return self.meta;
    }

    fn usageImpl(ptr: *const anyopaque) provider.TokenUsage {
        const self: *const GeminiProvider = @ptrCast(@alignCast(ptr));
        return self.latest_usage;
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
        .too_many_requests => .retry,
        .request_timeout, .service_unavailable, .bad_gateway, .gateway_timeout, .internal_server_error => .retry,
        .payload_too_large, .uri_too_long => .context_exceeded,
        else => .provider_error,
    };
}

fn buildEndpoint(allocator: std.mem.Allocator, model_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}:generateContent", .{ endpoint_base, model_name });
}

fn buildRequestPayload(allocator: std.mem.Allocator, prompt: []const u8) ![]u8 {
    const part = GeminiPart{ .text = prompt };
    const content = GeminiContent{ .parts = &[_]GeminiPart{part} };

    return try std.json.Stringify.valueAlloc(allocator, GeminiRequestPayload{
        .contents = &[_]GeminiContent{content},
        .generationConfig = .{
            .temperature = 0.2,
            .responseMimeType = "application/json",
        },
    }, .{});
}

const GenerateResponse = struct {
    candidates: ?[]Candidate = null,
    usageMetadata: ?UsageMetadata = null,
    @"error": ?ApiError = null,

    const Candidate = struct {
        content: ?struct {
            parts: ?[]struct {
                text: ?[]const u8 = null,
            } = null,
        } = null,
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

    var creds = credentials.Credentials{
        .allocator = allocator,
        .api_key = dummy_key,
        .source = .environment,
    };
    defer creds.deinit();

    var gemini = GeminiProvider.init(allocator, std.testing.io, creds, default_model, null, null);
    defer gemini.deinit();
    const p = gemini.providerInterface();

    var w_alloc = std.Io.Writer.Allocating.init(allocator);
    defer w_alloc.deinit();

    var cancel_src = try kernel.cancellation.CancellationTokenSource.init(allocator);
    defer cancel_src.deinit();

    try p.ask(allocator, test_mode_prompt, &w_alloc.writer, &cancel_src.getToken());

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
