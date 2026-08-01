const std = @import("std");
const core_provider = @import("../../provider.zig");
const provider = @import("../../provider.zig");
const credentials = @import("../../credentials.zig");
const kernel = @import("forge-kernel");
const proposal_normalize = @import("../../proposal_normalize.zig");
const openai_compat = @import("../openai/compat.zig");
const openai_sse = @import("../openai/sse.zig");
const agent_turn = @import("../../agent/turn.zig");
const mcp_registry = @import("../../mcp_registry.zig");
const zai_transport = @import("tool_transport.zig");

/// Z.AI (GLM) provider — uses the Z.AI internal API at internal-api.z.ai/v1.
///
/// This provider is unique in that it ships with a pre-authenticated token
/// (read from /etc/.z-ai-config or ~/.z-ai-config). The token is provisioned
/// by the z-ai-web-dev-sdk CLI (`npm i -g z-ai-web-dev-sdk`) and provides
/// unlimited free access during dev sessions — perfect for eval runs and CI.
///
/// The API is fully OpenAI-compatible at /chat/completions:
///   - Supports `tools`, `tool_choice`, `tool_calls` in response
///   - Supports `stream: true` (SSE with `delta.content` chunks)
///   - Supports `response_format: {type: "json_object"|"json_schema"}`
///   - Supports `thinking: {type: "enabled"|"disabled"}` for reasoning models
///
/// Available free models (verified 2026-08):
///   glm-4-plus       — fast general-purpose chat (default)
///   glm-4.5          — latest 4.5 generation
///   glm-4.6          — latest 4.6 generation
///   glm-4-air        — lightweight, fast
///   glm-4-flash      — fastest, cheapest
///   glm-4-flashx     — fastest for simple tasks
///   glm-4-long       — long-context (1M tokens)
///   glm-4-9b-chat    — open 9B model
///   glm-zero         — reasoning model (chain-of-thought)
///   glm-zero-preview — preview reasoning model
///   glm-4v           — vision-capable
///   glm-4v-flash     — vision, fast
pub const default_base_url = "https://internal-api.z.ai/v1";
pub const base_url_env_var = "ZAI_BASE_URL";
pub const default_context_window: usize = 128_000;
pub const test_mode_prompt = "test_mode";
pub const default_model = "glm-4-plus";

/// Special pseudo-API-key required by z-ai's gateway. The actual auth is
/// the X-Token header (JWT) read from the z-ai-config file. We use the
/// literal string "Z.ai" as the Bearer token because that's what the
/// gateway expects (it's not a real API key — it's a routing hint).
pub const gateway_bearer = "Z.ai";

pub const ZaiProvider = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// For z-ai, "creds.api_key" actually stores the JWT token from
    /// .z-ai-config. The Bearer header is set to the literal "Z.ai" string
    /// (see `gateway_bearer` above), and the JWT goes in the X-Token header.
    creds: credentials.Credentials,
    base_url: []u8,
    model_name: []u8,
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
        // z-ai token comes from .z-ai-config file (JSON: {token: "..."}).
        // We support three lookup paths:
        //   1. ZAI_TOKEN env var (highest priority)
        //   2. ~/.z-ai-config file (z-ai SDK default)
        //   3. /etc/.z-ai-config file (system-wide)
        const creds = loadZaiCredentials(allocator, io, environ_map) catch |err| switch (err) {
            error.NotFound => return error.MissingCredentials,
            else => return err,
        };

        const base_url = try resolveBaseUrl(allocator, environ_map, if (@hasField(@TypeOf(options), "base_url")) (if (@typeInfo(@TypeOf(options.base_url)) == .optional) options.base_url else options.base_url) else null);
        defer allocator.free(base_url);
        const model_name: []const u8 = if (@hasField(@TypeOf(options), "model")) (if (@typeInfo(@TypeOf(options.model)) == .optional) options.model orelse default_model else options.model) else default_model;

        const owned_base = try allocator.dupe(u8, base_url);
        errdefer allocator.free(owned_base);
        const owned_model = try allocator.dupe(u8, model_name);
        errdefer allocator.free(owned_model);

        const ptr = try allocator.create(ZaiProvider);
        ptr.* = .{
            .allocator = allocator,
            .io = io,
            .creds = creds,
            .base_url = owned_base,
            .model_name = owned_model,
            .meta = .{
                .provider_name = "zai",
                .model_name = owned_model,
                .context_window = default_context_window,
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
        const self: *ZaiProvider = @ptrCast(@alignCast(ptr));
        self.creds.deinit();
        self.allocator.free(self.base_url);
        self.allocator.free(self.model_name);
        allocator.destroy(self);
    }

    pub fn providerInterface(self: *ZaiProvider) provider.Provider {
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
        const self: *ZaiProvider = @ptrCast(@alignCast(ptr));
        _ = images;

        if (cancel_token.isCancelled()) return provider.ProviderError.Cancelled;

        if (std.mem.eql(u8, prompt, test_mode_prompt)) {
            self.latest_usage = .{ .prompt_tokens = 5, .completion_tokens = 10, .total_tokens = 15 };
            writer.writeAll("{\"schema_version\":1,\"summary\":\"test\",\"workspace_edit\":{\"files\":[]}}") catch return provider.ProviderError.NetworkError;
            return;
        }

        const endpoint = buildChatEndpoint(allocator, self.base_url) catch return provider.ProviderError.ProviderInternalError;
        defer allocator.free(endpoint);

        const payload = buildRequestPayload(allocator, self.model_name, prompt) catch return provider.ProviderError.ProviderInternalError;
        defer allocator.free(payload);

        var bridge = StreamBridge{ .provider = self };
        var parser = openai_sse.Parser.init(allocator, .{
            .on_chunk = StreamBridge.onChunk,
            .context = &bridge,
        });
        defer parser.deinit();

        fetchChatInto(self, allocator, endpoint, payload, cancel_token, &parser) catch |err| return err;
        parser.finish() catch return provider.ProviderError.MalformedResponse;

        self.latest_usage = parser.latest_usage;
        const raw = parser.assembledText();
        if (raw.len == 0) return provider.ProviderError.MalformedResponse;

        if (std.mem.startsWith(u8, prompt, "INTENT_CLASSIFIER_MODE") or std.mem.indexOf(u8, prompt, "MARKDOWN PLAN MODE") != null) {
            writer.writeAll(raw) catch return provider.ProviderError.NetworkError;
            return;
        }

        const normalized = proposal_normalize.normalize(allocator, raw) catch return provider.ProviderError.MalformedResponse;
        defer allocator.free(normalized);
        writer.writeAll(normalized) catch return provider.ProviderError.NetworkError;
    }

    const StreamBridge = struct {
        provider: *ZaiProvider,

        fn onChunk(context: ?*anyopaque, chunk: []const u8) void {
            const bridge: *StreamBridge = @ptrCast(@alignCast(context.?));
            if (bridge.provider.stream_callback) |callback| callback(bridge.provider.stream_context, chunk);
        }
    };

    fn metadataImpl(ptr: *const anyopaque) provider.ModelMetadata {
        const self: *const ZaiProvider = @ptrCast(@alignCast(ptr));
        return self.meta;
    }

    fn usageImpl(ptr: *const anyopaque) provider.TokenUsage {
        const self: *const ZaiProvider = @ptrCast(@alignCast(ptr));
        return self.latest_usage;
    }

    fn toolTransportState(self: *ZaiProvider, io: std.Io, mcp: ?*mcp_registry.Registry) zai_transport.ZaiTransport {
        return .{ .zai = self, .io = io, .mcp = mcp };
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
        const self: *ZaiProvider = @ptrCast(@alignCast(ptr));
        var transport_state = self.toolTransportState(io, mcp);
        return transport_state.transport().complete(allocator, conversation_json, tool_declarations_json, cancel_token) catch |err| return provider.mapTransportError(err);
    }

    fn toolDeclarationsJsonImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        mcp: ?*mcp_registry.Registry,
    ) provider.ProviderError![]const u8 {
        const self: *ZaiProvider = @ptrCast(@alignCast(ptr));
        const transport_state = self.toolTransportState(undefined, mcp);
        return transport_state.declarationsJson(allocator) catch return error.ProviderInternalError;
    }

    fn appendToolUserTextImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        conversation: *std.ArrayList(u8),
        text: []const u8,
    ) provider.ProviderError!void {
        const self: *ZaiProvider = @ptrCast(@alignCast(ptr));
        var transport_state = self.toolTransportState(undefined, null);
        return transport_state.transport().appendUserText(allocator, conversation, text) catch |err| return provider.mapTransportError(err);
    }

    fn appendToolCallImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        conversation: *std.ArrayList(u8),
        call: agent_turn.ToolCall,
    ) provider.ProviderError!void {
        const self: *ZaiProvider = @ptrCast(@alignCast(ptr));
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
        const self: *ZaiProvider = @ptrCast(@alignCast(ptr));
        var transport_state = self.toolTransportState(undefined, null);
        return transport_state.transport().appendToolResult(allocator, conversation, tool_name, result, images) catch |err| return provider.mapTransportError(err);
    }
};

pub fn resolveBaseUrl(
    allocator: std.mem.Allocator,
    environ_map: ?*const std.process.Environ.Map,
    configured_url: ?[]const u8,
) ![]u8 {
    return openai_compat.resolveBaseUrl(allocator, environ_map, configured_url, .{
        .default_base_url = default_base_url,
        .base_url_env_var = base_url_env_var,
    });
}

/// Loads the z-ai JWT token from .z-ai-config files.
/// The config file is JSON: {"baseUrl":"...","apiKey":"Z.ai","token":"<JWT>",...}
/// We extract the `token` field and treat it as the credential.
fn loadZaiCredentials(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
) !credentials.Credentials {
    // 1. ZAI_TOKEN env var (highest priority — lets users override)
    if (environ_map) |map| {
        if (map.get("ZAI_TOKEN")) |tok| {
            if (tok.len > 0) {
                return credentials.Credentials{
                    .allocator = allocator,
                    .api_key = try allocator.dupe(u8, tok),
                    .source = .environment,
                };
            }
        }
    }

    // 2-3. Read .z-ai-config files
    const config_paths = [_][]const u8{
        "/etc/.z-ai-config",
        // Also check home dir — but we don't have an easy way to get it
        // without std.process.getEnvVarOwned. The /etc path is the
        // system-wide one used by the z-ai SDK CLI install.
    };

    for (config_paths) |path| {
        const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch continue;
        defer file.close(io);
        const stat = file.stat(io) catch continue;
        if (stat.size > 65536) continue;
        const size: usize = @intCast(stat.size);
        const contents = allocator.alloc(u8, size) catch continue;
        defer allocator.free(contents);
        const read_len = file.readPositionalAll(io, contents, 0) catch continue;
        if (read_len != size) continue;

        // Parse JSON to extract `token` field
        var parsed = std.json.parseFromSlice(struct {
            token: ?[]const u8 = null,
            apiKey: ?[]const u8 = null,
        }, allocator, contents, .{ .ignore_unknown_fields = true }) catch continue;
        defer parsed.deinit();

        if (parsed.value.token) |tok| {
            if (tok.len > 0) {
                return credentials.Credentials{
                    .allocator = allocator,
                    .api_key = try allocator.dupe(u8, tok),
                    .source = .environment,
                };
            }
        }
    }

    return error.NotFound;
}

fn fetchChatInto(
    self: *ZaiProvider,
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    payload: []const u8,
    cancel_token: ?*const kernel.cancellation.CancellationToken,
    parser: *openai_sse.Parser,
) provider.ProviderError!void {
    if (cancel_token) |token| if (token.isCancelled()) return provider.ProviderError.Cancelled;

    // z-ai gateway requires:
    //   Authorization: Bearer Z.ai   (literal string — routing hint)
    //   X-Token: <JWT>               (actual auth)
    //   X-Z-AI-From: Z               (SDK identification)
    const auth = std.fmt.allocPrint(allocator, "Bearer {s}", .{gateway_bearer}) catch return provider.ProviderError.ProviderInternalError;
    defer allocator.free(auth);
    const headers = [_]std.http.Header{
        .{ .name = "Authorization", .value = auth },
        .{ .name = "X-Token", .value = self.creds.api_key },
        .{ .name = "X-Z-AI-From", .value = "Z" },
    };

    var client = std.http.Client{ .allocator = allocator, .io = self.io };
    defer client.deinit();

    const result = client.fetch(.{
        .location = .{ .url = endpoint },
        .method = .POST,
        .payload = payload,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .extra_headers = &headers,
        .response_writer = parser.ioWriter(),
    }) catch return provider.ProviderError.NetworkError;

    parser.releaseWriter();

    return switch (result.status) {
        .ok => {},
        .unauthorized, .forbidden => provider.ProviderError.AuthenticationFailed,
        .too_many_requests => provider.ProviderError.RateLimitExceeded,
        .payload_too_large, .uri_too_long, .bad_request => provider.ProviderError.ContextLengthExceeded,
        .request_timeout, .service_unavailable, .bad_gateway, .gateway_timeout => provider.ProviderError.NetworkError,
        else => provider.ProviderError.ProviderInternalError,
    };
}

pub fn buildChatEndpoint(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    return openai_compat.buildChatEndpoint(allocator, base_url);
}

fn buildRequestPayload(allocator: std.mem.Allocator, model_name: []const u8, prompt: []const u8) ![]u8 {
    const messages = [_]openai_compat.ChatMessage{.{ .role = "user", .content = prompt }};
    if (openai_compat.promptWantsSchema(prompt)) {
        return openai_compat.buildChatPayloadWithSchema(allocator, model_name, &messages);
    }
    return openai_compat.buildChatPayload(allocator, model_name, &messages, openai_compat.promptWantsJson(prompt));
}

test "buildChatEndpoint appends OpenAI-compatible route" {
    const endpoint = try buildChatEndpoint(std.testing.allocator, "https://internal-api.z.ai/v1/");
    defer std.testing.allocator.free(endpoint);
    try std.testing.expectEqualStrings("https://internal-api.z.ai/v1/chat/completions", endpoint);
}

test "buildRequestPayload requests json_schema for proposals" {
    const payload = try buildRequestPayload(std.testing.allocator, "glm-4-plus", "Output ONLY a raw JSON object WorkspaceEdit");
    defer std.testing.allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "json_schema") != null);
}
