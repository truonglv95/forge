const std = @import("std");
const provider = @import("../../provider.zig");
const kernel = @import("forge-kernel");
const gemini_provider = @import("../gemini/provider.zig");
const proposal_normalize = @import("../../proposal_normalize.zig");
const ollama_ndjson = @import("ndjson.zig");
const agent_turn = @import("../../agent/turn.zig");
const mcp_registry = @import("../../mcp_registry.zig");
const ollama_transport = @import("tool_transport.zig");

pub const default_host = "http://127.0.0.1:11434";
pub const default_model = "qwen2.5-coder:7b";
pub const host_env_var = "OLLAMA_HOST";
pub const num_ctx_env_var = "FORGE_OLLAMA_NUM_CTX";
pub const default_num_ctx: usize = 131_072;
pub const test_mode_prompt = "test_mode";

const ChatMessage = struct {
    role: []const u8,
    content: []const u8,
};

const ChatRequest = struct {
    model: []const u8,
    messages: []const ChatMessage,
    stream: bool,
    format: ?[]const u8 = null,
    options: OllamaOptions,
};

const OllamaOptions = struct {
    num_ctx: usize,
};

pub const OllamaProvider = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    base_url: []u8,
    model_name: []const u8,
    num_ctx: usize,
    meta: provider.ModelMetadata,
    latest_usage: provider.TokenUsage,
    stream_callback: ?*const fn (?*anyopaque, []const u8) void = null,
    stream_context: ?*anyopaque = null,

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ_map: ?*const std.process.Environ.Map,
        options: anytype,
    ) !provider.Provider {
        const host = try resolveHost(allocator, environ_map, options.base_url);
        defer allocator.free(host);

        const model_name: []const u8 = if (@hasField(@TypeOf(options), "model")) (if (@typeInfo(@TypeOf(options.model)) == .optional) options.model orelse default_model else options.model) else default_model;
        const num_ctx = resolveNumCtx(environ_map);

        const owned_model = try allocator.dupe(u8, model_name);
        errdefer allocator.free(owned_model);
        const owned_base = try allocator.dupe(u8, host);
        errdefer allocator.free(owned_base);

        const ptr = try allocator.create(OllamaProvider);
        ptr.* = .{
            .allocator = allocator,
            .io = io,
            .base_url = owned_base,
            .model_name = owned_model,
            .num_ctx = num_ctx,
            .meta = .{
                .provider_name = "ollama",
                .model_name = owned_model,
                .context_window = num_ctx,
            },
            .latest_usage = .{},
            .stream_callback = if (@hasField(@TypeOf(options), "stream_callback")) options.stream_callback else null,
            .stream_context = if (@hasField(@TypeOf(options), "stream_context")) options.stream_context else null,
        };
        return ptr.providerInterface();
    }

    pub fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *OllamaProvider = @ptrCast(@alignCast(ptr));
        self.allocator.free(self.base_url);
        self.allocator.free(self.model_name);
        allocator.destroy(self);
    }

    pub fn providerInterface(self: *OllamaProvider) provider.Provider {
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
        images: []const provider.ImagePart,
        writer: *std.Io.Writer,
        cancel_token: *const kernel.cancellation.CancellationToken,
    ) provider.ProviderError!void {
        const self: *OllamaProvider = @ptrCast(@alignCast(ptr));
        _ = images;

        if (cancel_token.isCancelled()) return provider.ProviderError.NetworkError;

        if (std.mem.startsWith(u8, prompt, "INTENT_CLASSIFIER_MODE")) {
            const endpoint = buildChatEndpoint(allocator, self.base_url) catch return provider.ProviderError.ProviderInternalError;
            defer allocator.free(endpoint);

            const payload = buildClassifierPayload(allocator, self.model_name, self.num_ctx, prompt) catch return provider.ProviderError.ProviderInternalError;
            defer allocator.free(payload);

            var bridge = StreamBridge{ .provider = self };
            var parser = ollama_ndjson.Parser.init(allocator, .{
                .on_chunk = StreamBridge.onChunk,
                .context = &bridge,
            });
            defer parser.deinit();

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
                .response_writer = parser.ioWriter(),
            }) catch return provider.ProviderError.NetworkError;

            parser.releaseWriter();

            if (result.status != .ok) {
                return switch (result.status) {
                    .unauthorized, .forbidden => provider.ProviderError.AuthenticationFailed,
                    .payload_too_large, .uri_too_long => provider.ProviderError.ContextLengthExceeded,
                    else => provider.ProviderError.ProviderInternalError,
                };
            }

            parser.finish() catch return provider.ProviderError.MalformedResponse;
            if (parser.terminal_error) |_| return provider.ProviderError.MalformedResponse;

            self.latest_usage = parser.latest_usage;
            const text = parser.assembledText();
            if (text.len == 0) return provider.ProviderError.MalformedResponse;
            writer.writeAll(text) catch return provider.ProviderError.NetworkError;
            return;
        }

        if (std.mem.eql(u8, prompt, test_mode_prompt)) {
            self.latest_usage = .{ .prompt_tokens = 5, .completion_tokens = 10, .total_tokens = 15 };
            writer.writeAll("{\"schema_version\":1,\"summary\":\"test\",\"workspace_edit\":{\"files\":[]}}") catch return provider.ProviderError.NetworkError;
            return;
        }

        const endpoint = buildChatEndpoint(allocator, self.base_url) catch return provider.ProviderError.ProviderInternalError;
        defer allocator.free(endpoint);

        const payload = buildRequestPayload(allocator, self.model_name, self.num_ctx, prompt) catch return provider.ProviderError.ProviderInternalError;
        defer allocator.free(payload);

        var bridge = StreamBridge{ .provider = self };
        var parser = ollama_ndjson.Parser.init(allocator, .{
            .on_chunk = StreamBridge.onChunk,
            .context = &bridge,
        });
        defer parser.deinit();

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
            .response_writer = parser.ioWriter(),
        }) catch return provider.ProviderError.NetworkError;

        parser.releaseWriter();

        if (result.status != .ok) {
            return switch (result.status) {
                .unauthorized, .forbidden => provider.ProviderError.AuthenticationFailed,
                .payload_too_large, .uri_too_long => provider.ProviderError.ContextLengthExceeded,
                else => provider.ProviderError.ProviderInternalError,
            };
        }

        parser.finish() catch return provider.ProviderError.MalformedResponse;
        if (parser.terminal_error) |_| return provider.ProviderError.ProviderInternalError;

        self.latest_usage = parser.latest_usage;
        const normalized = proposal_normalize.normalize(allocator, parser.assembledText()) catch return provider.ProviderError.MalformedResponse;
        defer allocator.free(normalized);
        if (normalized.len == 0) return provider.ProviderError.MalformedResponse;
        writer.writeAll(normalized) catch return provider.ProviderError.NetworkError;
    }

    const StreamBridge = struct {
        provider: *OllamaProvider,

        fn onChunk(context: ?*anyopaque, chunk: []const u8) void {
            const bridge: *StreamBridge = @ptrCast(@alignCast(context.?));
            if (bridge.provider.stream_callback) |callback| {
                callback(bridge.provider.stream_context, chunk);
            }
        }
    };

    fn metadataImpl(ptr: *const anyopaque) provider.ModelMetadata {
        const self: *const OllamaProvider = @ptrCast(@alignCast(ptr));
        return self.meta;
    }

    fn usageImpl(ptr: *const anyopaque) provider.TokenUsage {
        const self: *const OllamaProvider = @ptrCast(@alignCast(ptr));
        return self.latest_usage;
    }

    fn toolTransportState(self: *OllamaProvider, io: std.Io, mcp: ?*mcp_registry.Registry) ollama_transport.OllamaTransport {
        return .{ .ollama = self, .io = io, .mcp = mcp };
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
        const self: *OllamaProvider = @ptrCast(@alignCast(ptr));
        var transport_state = self.toolTransportState(io, mcp);
        return transport_state.transport().complete(allocator, conversation_json, tool_declarations_json, cancel_token) catch |err| return provider.mapTransportError(err);
    }

    fn toolDeclarationsJsonImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        mcp: ?*mcp_registry.Registry,
    ) provider.ProviderError![]const u8 {
        const self: *OllamaProvider = @ptrCast(@alignCast(ptr));
        const transport_state = self.toolTransportState(undefined, mcp);
        return transport_state.declarationsJson(allocator) catch return error.ProviderInternalError;
    }

    fn appendToolUserTextImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        conversation: *std.ArrayList(u8),
        text: []const u8,
    ) provider.ProviderError!void {
        const self: *OllamaProvider = @ptrCast(@alignCast(ptr));
        var transport_state = self.toolTransportState(undefined, null);
        return transport_state.transport().appendUserText(allocator, conversation, text) catch |err| return provider.mapTransportError(err);
    }

    fn appendToolCallImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        conversation: *std.ArrayList(u8),
        call: agent_turn.ToolCall,
    ) provider.ProviderError!void {
        const self: *OllamaProvider = @ptrCast(@alignCast(ptr));
        var transport_state = self.toolTransportState(undefined, null);
        return transport_state.transport().appendToolCall(allocator, conversation, call) catch |err| return provider.mapTransportError(err);
    }

    fn appendToolResultImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        conversation: *std.ArrayList(u8),
        tool_name: []const u8,
        result: []const u8,
    ) provider.ProviderError!void {
        const self: *OllamaProvider = @ptrCast(@alignCast(ptr));
        var transport_state = self.toolTransportState(undefined, null);
        return transport_state.transport().appendToolResult(allocator, conversation, tool_name, result) catch |err| return provider.mapTransportError(err);
    }
};

pub fn resolveHost(
    allocator: std.mem.Allocator,
    environ_map: ?*const std.process.Environ.Map,
    configured_url: ?[]const u8,
) ![]u8 {
    if (configured_url) |url| {
        const trimmed = std.mem.trim(u8, url, &std.ascii.whitespace);
        if (trimmed.len > 0) return allocator.dupe(u8, trimmed);
    }
    if (environ_map) |map| {
        if (map.get(host_env_var)) |host| {
            return allocator.dupe(u8, host);
        }
    }
    return allocator.dupe(u8, default_host);
}

pub fn resolveNumCtx(environ_map: ?*const std.process.Environ.Map) usize {
    if (environ_map) |map| {
        if (map.get(num_ctx_env_var)) |raw| {
            return std.fmt.parseInt(usize, std.mem.trim(u8, raw, &std.ascii.whitespace), 10) catch default_num_ctx;
        }
    }
    return default_num_ctx;
}

pub fn isReachable(allocator: std.mem.Allocator, io: std.Io, base_url: []const u8) bool {
    const endpoint = buildTagsEndpoint(allocator, base_url) catch return false;
    defer allocator.free(endpoint);

    var client = std.http.Client{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    var discard_buffer: [512]u8 = undefined;
    var discard = std.Io.Writer.Discarding.init(&discard_buffer);

    const result = client.fetch(.{
        .location = .{ .url = endpoint },
        .method = .GET,
        .response_writer = &discard.writer,
    }) catch return false;

    return result.status == .ok;
}

fn trimTrailingSlash(url: []const u8) []const u8 {
    var end = url.len;
    while (end > 0 and url[end - 1] == '/') end -= 1;
    return url[0..end];
}

fn buildChatEndpoint(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    const trimmed = trimTrailingSlash(base_url);
    return std.fmt.allocPrint(allocator, "{s}/api/chat", .{trimmed});
}

fn buildTagsEndpoint(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    const trimmed = trimTrailingSlash(base_url);
    return std.fmt.allocPrint(allocator, "{s}/api/tags", .{trimmed});
}

fn buildClassifierPayload(allocator: std.mem.Allocator, model_name: []const u8, num_ctx: usize, prompt: []const u8) ![]u8 {
    const messages = [_]ChatMessage{
        .{
            .role = "system",
            .content = "You classify coding-agent user requests. Output only raw JSON with keys intent and confidence. Never use markdown fences or prose.",
        },
        .{ .role = "user", .content = prompt },
    };
    return try std.json.Stringify.valueAlloc(allocator, ChatRequest{
        .model = model_name,
        .messages = &messages,
        .stream = true,
        .format = "json",
        .options = .{ .num_ctx = num_ctx },
    }, .{});
}

fn buildRequestPayload(allocator: std.mem.Allocator, model_name: []const u8, num_ctx: usize, prompt: []const u8) ![]u8 {
    const response_format: ?[]const u8 = if (std.mem.indexOf(u8, prompt, "MARKDOWN PLAN MODE") != null)
        null
    else
        "json";

    var messages: [2]ChatMessage = undefined;
    const message_slice: []const ChatMessage = if (response_format != null) blk: {
        messages[0] = .{ .role = "system", .content = "You are the Forge proposal engine. Output only raw JSON matching WorkspaceEdit schema_version 1. Never use markdown fences or explanatory prose. If no file edits are needed, return workspace_edit.files as []." };
        messages[1] = .{ .role = "user", .content = prompt };
        break :blk messages[0..2];
    } else blk: {
        messages[0] = .{ .role = "user", .content = prompt };
        break :blk messages[0..1];
    };

    return try std.json.Stringify.valueAlloc(allocator, ChatRequest{
        .model = model_name,
        .messages = message_slice,
        .stream = true,
        .format = response_format,
        .options = .{ .num_ctx = num_ctx },
    }, .{});
}

test "OllamaProvider test mode" {
    const allocator = std.testing.allocator;

    var p = try OllamaProvider.create(allocator, std.testing.io, null, .{
        .base_url = default_host,
        .model = default_model,
    });
    defer p.deinit(allocator);

    var w_alloc = std.Io.Writer.Allocating.init(allocator);
    defer w_alloc.deinit();

    var cancel_src = try kernel.cancellation.CancellationTokenSource.init(allocator);
    defer cancel_src.deinit();

    try p.ask(allocator, test_mode_prompt, &.{}, &w_alloc.writer, &cancel_src.getToken());

    const out = w_alloc.writer.buffer[0..w_alloc.writer.end];
    try std.testing.expect(std.mem.indexOf(u8, out, "schema_version") != null);

    const meta = p.metadata();
    try std.testing.expectEqualStrings("ollama", meta.provider_name);
}

test "buildClassifierPayload uses json format" {
    const allocator = std.testing.allocator;
    const payload = try buildClassifierPayload(allocator, default_model, default_num_ctx, "INTENT_CLASSIFIER_MODE\nclassify this");
    defer allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"format\":\"json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"num_ctx\":131072") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "classify coding-agent") != null);
}

test "buildRequestPayload uses json format for proposals" {
    const allocator = std.testing.allocator;
    const payload = try buildRequestPayload(allocator, default_model, default_num_ctx, "Respond with JSON");
    defer allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"format\":\"json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"num_ctx\":131072") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"role\":\"system\"") != null);
}

test "buildRequestPayload omits json format for markdown plans" {
    const allocator = std.testing.allocator;
    const payload = try buildRequestPayload(allocator, default_model, default_num_ctx, "MARKDOWN PLAN MODE\nWrite a plan");
    defer allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"format\":null") != null);
}

test "OllamaProvider live chat when server is running" {
    const allocator = std.testing.allocator;
    if (!liveTestsEnabled()) return error.SkipZigTest;
    if (!isReachable(allocator, std.testing.io, default_host)) return error.SkipZigTest;

    var p = try OllamaProvider.create(allocator, std.testing.io, null, .{
        .base_url = default_host,
        .model = default_model,
    });
    defer p.deinit(allocator);

    var w_alloc = std.Io.Writer.Allocating.init(allocator);
    defer w_alloc.deinit();

    var cancel_src = try kernel.cancellation.CancellationTokenSource.init(allocator);
    defer cancel_src.deinit();

    try p.ask(allocator, "Reply with exactly one word: hello", &.{}, &w_alloc.writer, &cancel_src.getToken());

    const out = w_alloc.writer.buffer[0..w_alloc.writer.end];
    try std.testing.expect(out.len > 0);
    try std.testing.expect(std.ascii.findIgnoreCase(out, "hello") != null);
}

test "OllamaProvider planner-sized json prompt" {
    const allocator = std.testing.allocator;
    if (!liveTestsEnabled()) return error.SkipZigTest;
    if (!isReachable(allocator, std.testing.io, default_host)) return error.SkipZigTest;

    const planner = @import("../../planner.zig");
    const context = @import("../../context.zig");

    var p = try OllamaProvider.create(allocator, std.testing.io, null, .{
        .base_url = default_host,
        .model = default_model,
    });
    defer p.deinit(allocator);

    var ctx = context.ContextBuilder.init(allocator, 4096);
    defer ctx.deinit();
    try ctx.addBlock(.intent, "user intent", "Add a hello comment to sample.txt");

    var plan_inst = planner.Planner.init(allocator, p, &ctx, &.{}, &.{});
    var w_alloc = std.Io.Writer.Allocating.init(allocator);
    defer w_alloc.deinit();

    var cancel_src = try kernel.cancellation.CancellationTokenSource.init(allocator);
    defer cancel_src.deinit();

    try plan_inst.plan(&w_alloc.writer, &cancel_src.getToken());
    try std.testing.expect(w_alloc.writer.end > 0);
}

/// Live model trials are executed by scripts/eval*.sh, never by the
/// deterministic unit-test graph.
fn liveTestsEnabled() bool {
    return false;
}
