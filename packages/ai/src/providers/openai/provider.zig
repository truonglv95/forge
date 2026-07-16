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
const openai_transport = @import("tool_transport.zig");

pub const default_base_url = "https://api.openai.com/v1";
pub const base_url_env_var = "OPENAI_BASE_URL";
pub const default_context_window: usize = 128_000;
pub const test_mode_prompt = "test_mode";

pub const OpenAIProvider = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
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
        const creds = credentials.Credentials.load(
            allocator,
            io,
            environ_map,
            &[_][]const u8{"OPENAI_API_KEY"},
            "forge-openai",
            "default",
        ) catch |err| switch (err) {
            error.NotFound => return error.MissingCredentials,
            else => return err,
        };

        const base_url = try resolveBaseUrl(allocator, environ_map, if (@hasField(@TypeOf(options), "base_url")) (if (@typeInfo(@TypeOf(options.base_url)) == .optional) options.base_url else options.base_url) else null);
        defer allocator.free(base_url);
        const model_name: []const u8 = if (@hasField(@TypeOf(options), "model")) (if (@typeInfo(@TypeOf(options.model)) == .optional) options.model orelse return error.ModelRequired else options.model) else return error.ModelRequired;

        const owned_base = try allocator.dupe(u8, base_url);
        errdefer allocator.free(owned_base);
        const owned_model = try allocator.dupe(u8, model_name);
        errdefer allocator.free(owned_model);

        const ptr = try allocator.create(OpenAIProvider);
        ptr.* = .{
            .allocator = allocator,
            .io = io,
            .creds = creds,
            .base_url = owned_base,
            .model_name = owned_model,
            .meta = .{
                .provider_name = "openai",
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
        const self: *OpenAIProvider = @ptrCast(@alignCast(ptr));
        self.creds.deinit();
        self.allocator.free(self.base_url);
        self.allocator.free(self.model_name);
        allocator.destroy(self);
    }

    pub fn providerInterface(self: *OpenAIProvider) provider.Provider {
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
        const self: *OpenAIProvider = @ptrCast(@alignCast(ptr));
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
        provider: *OpenAIProvider,

        fn onChunk(context: ?*anyopaque, chunk: []const u8) void {
            const bridge: *StreamBridge = @ptrCast(@alignCast(context.?));
            if (bridge.provider.stream_callback) |callback| callback(bridge.provider.stream_context, chunk);
        }
    };

    fn metadataImpl(ptr: *const anyopaque) provider.ModelMetadata {
        const self: *const OpenAIProvider = @ptrCast(@alignCast(ptr));
        return self.meta;
    }

    fn usageImpl(ptr: *const anyopaque) provider.TokenUsage {
        const self: *const OpenAIProvider = @ptrCast(@alignCast(ptr));
        return self.latest_usage;
    }

    fn toolTransportState(self: *OpenAIProvider, io: std.Io, mcp: ?*mcp_registry.Registry) openai_transport.OpenAITransport {
        return .{ .openai = self, .io = io, .mcp = mcp };
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
        const self: *OpenAIProvider = @ptrCast(@alignCast(ptr));
        var transport_state = self.toolTransportState(io, mcp);
        return transport_state.transport().complete(allocator, conversation_json, tool_declarations_json, cancel_token) catch |err| return provider.mapTransportError(err);
    }

    fn toolDeclarationsJsonImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        mcp: ?*mcp_registry.Registry,
    ) provider.ProviderError![]const u8 {
        const self: *OpenAIProvider = @ptrCast(@alignCast(ptr));
        const transport_state = self.toolTransportState(undefined, mcp);
        return transport_state.declarationsJson(allocator) catch return error.ProviderInternalError;
    }

    fn appendToolUserTextImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        conversation: *std.ArrayList(u8),
        text: []const u8,
    ) provider.ProviderError!void {
        const self: *OpenAIProvider = @ptrCast(@alignCast(ptr));
        var transport_state = self.toolTransportState(undefined, null);
        return transport_state.transport().appendUserText(allocator, conversation, text) catch |err| return provider.mapTransportError(err);
    }

    fn appendToolCallImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        conversation: *std.ArrayList(u8),
        call: agent_turn.ToolCall,
    ) provider.ProviderError!void {
        const self: *OpenAIProvider = @ptrCast(@alignCast(ptr));
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
        const self: *OpenAIProvider = @ptrCast(@alignCast(ptr));
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

fn fetchChatInto(
    self: *OpenAIProvider,
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    payload: []const u8,
    cancel_token: ?*const kernel.cancellation.CancellationToken,
    parser: *openai_sse.Parser,
) provider.ProviderError!void {
    if (cancel_token) |token| if (token.isCancelled()) return provider.ProviderError.Cancelled;

    const auth = std.fmt.allocPrint(allocator, "Bearer {s}", .{self.creds.api_key}) catch return provider.ProviderError.ProviderInternalError;
    defer allocator.free(auth);
    const headers = [_]std.http.Header{
        .{ .name = "Authorization", .value = auth },
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
    const endpoint = try buildChatEndpoint(std.testing.allocator, "https://api.openai.com/v1/");
    defer std.testing.allocator.free(endpoint);
    try std.testing.expectEqualStrings("https://api.openai.com/v1/chat/completions", endpoint);
}

test "buildRequestPayload requests json_schema for proposals" {
    const payload = try buildRequestPayload(std.testing.allocator, "gpt-4o", "Output ONLY a raw JSON object WorkspaceEdit");
    defer std.testing.allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "json_schema") != null);
}
