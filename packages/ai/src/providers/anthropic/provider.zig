const std = @import("std");
const core_provider = @import("../../provider.zig");
const provider = @import("../../provider.zig");
const credentials = @import("../../credentials.zig");
const kernel = @import("forge-kernel");
const proposal_normalize = @import("../../proposal_normalize.zig");
const agent_turn = @import("../../agent/turn.zig");
const mcp_registry = @import("../../mcp_registry.zig");

pub const default_base_url = "https://api.anthropic.com";
pub const base_url_env_var = "ANTHROPIC_BASE_URL";
pub const api_version = "2023-06-01";
pub const default_context_window: usize = 200_000;
pub const default_model = "claude-sonnet-4-5";
pub const test_mode_prompt = "test_mode";

/// Anthropic Claude provider using the Messages API.
///
/// API format: POST /v1/messages with x-api-key header and
/// anthropic-version header. Response is a message with content blocks
/// (text, tool_use). Tool use format (Claude-specific):
///   assistant content: [{type: "text", text: "..."}, {type: "tool_use", id, name, input}]
///   user content: [{type: "tool_result", tool_use_id, content}]
pub const AnthropicProvider = struct {
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
            &[_][]const u8{ "ANTHROPIC_API_KEY", "CLAUDE_API_KEY" },
            "forge-anthropic",
            "default",
        ) catch |err| switch (err) {
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

        const ptr = try allocator.create(AnthropicProvider);
        ptr.* = .{
            .allocator = allocator,
            .io = io,
            .creds = creds,
            .base_url = owned_base,
            .model_name = owned_model,
            .meta = .{
                .provider_name = "anthropic",
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
        const self: *AnthropicProvider = @ptrCast(@alignCast(ptr));
        self.creds.deinit();
        self.allocator.free(self.base_url);
        self.allocator.free(self.model_name);
        allocator.destroy(self);
    }

    pub fn providerInterface(self: *AnthropicProvider) provider.Provider {
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
        const self: *AnthropicProvider = @ptrCast(@alignCast(ptr));
        _ = images;

        if (cancel_token.isCancelled()) return provider.ProviderError.Cancelled;

        if (std.mem.eql(u8, prompt, test_mode_prompt)) {
            self.latest_usage = .{ .prompt_tokens = 5, .completion_tokens = 10, .total_tokens = 15 };
            writer.writeAll("{\"schema_version\":1,\"summary\":\"test\",\"workspace_edit\":{\"files\":[]}}") catch return provider.ProviderError.NetworkError;
            return;
        }

        const endpoint = std.fmt.allocPrint(allocator, "{s}/v1/messages", .{self.base_url}) catch return provider.ProviderError.ProviderInternalError;
        defer allocator.free(endpoint);

        const payload = buildMessagesPayload(allocator, self.model_name, prompt) catch return provider.ProviderError.ProviderInternalError;
        defer allocator.free(payload);

        var response_alloc = std.Io.Writer.Allocating.init(allocator);
        defer response_alloc.deinit();

        fetchMessages(self, allocator, endpoint, payload, &response_alloc.writer) catch return provider.ProviderError.NetworkError;

        const response_body = response_alloc.written();
        const text = extractTextFromResponse(allocator, response_body) catch return provider.ProviderError.MalformedResponse;
        defer allocator.free(text);

        if (text.len == 0) return provider.ProviderError.MalformedResponse;

        // Stream the text to caller callback if registered.
        if (self.stream_callback) |callback| callback(self.stream_context, text);

        if (std.mem.startsWith(u8, prompt, "INTENT_CLASSIFIER_MODE") or std.mem.indexOf(u8, prompt, "MARKDOWN PLAN MODE") != null) {
            writer.writeAll(text) catch return provider.ProviderError.NetworkError;
            return;
        }

        // For inline completion prompts (no JSON schema), return raw text.
        if (std.mem.indexOf(u8, prompt, "inline code completion engine") != null) {
            writer.writeAll(text) catch return provider.ProviderError.NetworkError;
            return;
        }

        const normalized = proposal_normalize.normalize(allocator, text) catch return provider.ProviderError.MalformedResponse;
        defer allocator.free(normalized);
        writer.writeAll(normalized) catch return provider.ProviderError.NetworkError;
    }

    fn metadataImpl(ptr: *const anyopaque) provider.ModelMetadata {
        const self: *const AnthropicProvider = @ptrCast(@alignCast(ptr));
        return self.meta;
    }

    fn usageImpl(ptr: *const anyopaque) provider.TokenUsage {
        const self: *const AnthropicProvider = @ptrCast(@alignCast(ptr));
        return self.latest_usage;
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
        _ = mcp;
        _ = tool_declarations_json;
        _ = io;
        const self: *AnthropicProvider = @ptrCast(@alignCast(ptr));

        if (cancel_token) |tok| {
            if (tok.isCancelled()) return provider.ProviderError.Cancelled;
        }

        const endpoint = std.fmt.allocPrint(allocator, "{s}/v1/messages", .{self.base_url}) catch return provider.ProviderError.ProviderInternalError;
        defer allocator.free(endpoint);

        const payload = buildMessagesPayload(allocator, self.model_name, conversation_json) catch return provider.ProviderError.ProviderInternalError;
        defer allocator.free(payload);

        var response_alloc = std.Io.Writer.Allocating.init(allocator);
        defer response_alloc.deinit();

        fetchMessages(self, allocator, endpoint, payload, &response_alloc.writer) catch return provider.ProviderError.NetworkError;

        const response_body = response_alloc.written();
        const text = extractTextFromResponse(allocator, response_body) catch return provider.ProviderError.MalformedResponse;
        defer allocator.free(text);

        return .{ .text = allocator.dupe(u8, text) catch return provider.ProviderError.ProviderInternalError };
    }

    fn toolDeclarationsJsonImpl(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        _: ?*mcp_registry.Registry,
    ) provider.ProviderError![]const u8 {
        return allocator.dupe(u8, "[]") catch return provider.ProviderError.ProviderInternalError;
    }

    fn appendToolUserTextImpl(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        conversation: *std.ArrayList(u8),
        text: []const u8,
    ) provider.ProviderError!void {
        const escaped = jsonEscape(allocator, text) catch return provider.ProviderError.ProviderInternalError;
        defer allocator.free(escaped);
        const msg = std.fmt.allocPrint(allocator, "{{\"role\":\"user\",\"content\":[{{\"type\":\"text\",\"text\":{s}}}]}}", .{escaped}) catch return provider.ProviderError.ProviderInternalError;
        defer allocator.free(msg);
        if (conversation.items.len > 0) conversation.append(allocator, ',') catch return provider.ProviderError.ProviderInternalError;
        conversation.appendSlice(allocator, msg) catch return provider.ProviderError.ProviderInternalError;
    }

    fn appendToolCallImpl(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        conversation: *std.ArrayList(u8),
        call: agent_turn.ToolCall,
    ) provider.ProviderError!void {
        const escaped_name = jsonEscape(allocator, call.name) catch return provider.ProviderError.ProviderInternalError;
        defer allocator.free(escaped_name);
        const msg = std.fmt.allocPrint(allocator, "{{\"role\":\"assistant\",\"content\":[{{\"type\":\"tool_use\",\"id\":\"tool_{d}\",\"name\":{s},\"input\":{s}}}]}}", .{
            conversation.items.len,
            escaped_name,
            call.args_json,
        }) catch return provider.ProviderError.ProviderInternalError;
        defer allocator.free(msg);
        if (conversation.items.len > 0) conversation.append(allocator, ',') catch return provider.ProviderError.ProviderInternalError;
        conversation.appendSlice(allocator, msg) catch return provider.ProviderError.ProviderInternalError;
    }

    fn appendToolResultImpl(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        conversation: *std.ArrayList(u8),
        tool_name: []const u8,
        result: []const u8,
        _: []const core_provider.ImagePart,
    ) provider.ProviderError!void {
        const escaped_result = jsonEscape(allocator, result) catch return provider.ProviderError.ProviderInternalError;
        defer allocator.free(escaped_result);
        const msg = std.fmt.allocPrint(allocator, "{{\"role\":\"user\",\"content\":[{{\"type\":\"tool_result\",\"tool_use_id\":\"{s}\",\"content\":{s}}}]}}", .{
            tool_name,
            escaped_result,
        }) catch return provider.ProviderError.ProviderInternalError;
        defer allocator.free(msg);
        if (conversation.items.len > 0) conversation.append(allocator, ',') catch return provider.ProviderError.ProviderInternalError;
        conversation.appendSlice(allocator, msg) catch return provider.ProviderError.ProviderInternalError;
    }
};

fn resolveBaseUrl(allocator: std.mem.Allocator, environ_map: ?*const std.process.Environ.Map, override: ?[]const u8) ![]u8 {
    if (override) |url| return allocator.dupe(u8, url);
    if (environ_map) |env| {
        if (env.get(base_url_env_var)) |val| return allocator.dupe(u8, val);
    }
    const env_c = std.c.getenv(base_url_env_var);
    if (env_c) |c| {
        const val = std.mem.span(c);
        return allocator.dupe(u8, val);
    }
    return allocator.dupe(u8, default_base_url);
}

fn buildMessagesPayload(allocator: std.mem.Allocator, model: []const u8, prompt: []const u8) ![]u8 {
    const escaped = try jsonEscape(allocator, prompt);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator, "{{\"model\":\"{s}\",\"max_tokens\":4096,\"messages\":[{{\"role\":\"user\",\"content\":[{{\"type\":\"text\",\"text\":{s}}}]}}]}}", .{ model, escaped });
}

fn fetchMessages(
    self: *AnthropicProvider,
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    payload: []const u8,
    response_writer: *std.Io.Writer,
) provider.ProviderError!void {
    var client = std.http.Client{ .allocator = allocator, .io = self.io };
    defer client.deinit();

    const api_key = self.creds.api_key;
    const auth_header = std.fmt.allocPrint(allocator, "x-api-key: {s}\r\nanthropic-version: {s}\r\n", .{ api_key, api_version }) catch return provider.ProviderError.ProviderInternalError;
    defer allocator.free(auth_header);

    var response_alloc = std.Io.Writer.Allocating.init(allocator);
    defer response_alloc.deinit();

    const result = client.fetch(.{
        .location = .{ .url = endpoint },
        .method = .POST,
        .payload = payload,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = auth_header },
        },
        .response_writer = &response_alloc.writer,
    }) catch return provider.ProviderError.NetworkError;

    if (result.status != .ok) {
        return provider.ProviderError.NetworkError;
    }

    const body = response_alloc.written();
    response_writer.writeAll(body) catch return provider.ProviderError.NetworkError;
}

fn extractTextFromResponse(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ParseError;
    defer parsed.deinit();

    const content = parsed.value.object.get("content") orelse return error.ParseError;
    if (content != .array) return error.ParseError;
    if (content.array.items.len == 0) return error.EmptyResponse;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    for (content.array.items) |block| {
        if (block != .object) continue;
        const block_type = block.object.get("type") orelse continue;
        if (block_type != .string) continue;
        if (!std.mem.eql(u8, block_type.string, "text")) continue;
        const text_val = block.object.get("text") orelse continue;
        if (text_val != .string) continue;
        try buf.appendSlice(allocator, text_val.string);
    }

    return buf.toOwnedSlice(allocator);
}

fn jsonEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0...8, 11, 12, 14...31 => {
                var hex_buf: [6]u8 = undefined;
                const hex = std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}", .{c}) catch unreachable;
                try buf.appendSlice(allocator, hex);
            },
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
    return buf.toOwnedSlice(allocator);
}

test "Anthropic provider create requires credentials" {
    const allocator = std.testing.allocator;
    const result = AnthropicProvider.create(allocator, std.testing.io, null, .{
        .model = "claude-sonnet-4-5",
    });
    try std.testing.expectError(error.MissingCredentials, result);
}

test "buildMessagesPayload produces valid JSON" {
    const allocator = std.testing.allocator;
    const payload = try buildMessagesPayload(allocator, "claude-sonnet-4-5", "hello world");
    defer allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"model\":\"claude-sonnet-4-5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"max_tokens\":4096") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "hello world") != null);
}

test "extractTextFromResponse parses text blocks" {
    const allocator = std.testing.allocator;
    const body = "{\"content\":[{\"type\":\"text\",\"text\":\"hello\"},{\"type\":\"text\",\"text\":\" world\"}]}";
    const text = try extractTextFromResponse(allocator, body);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("hello world", text);
}

test "jsonEscape escapes special chars" {
    const allocator = std.testing.allocator;
    const escaped = try jsonEscape(allocator, "hello\n\"world\"");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("\"hello\\n\\\"world\\\"\"", escaped);
}
