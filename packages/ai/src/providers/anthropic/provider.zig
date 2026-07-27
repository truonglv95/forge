const std = @import("std");
const core_provider = @import("../../provider.zig");
const provider = @import("../../provider.zig");
const credentials = @import("../../credentials.zig");
const kernel = @import("forge-kernel");
const proposal_normalize = @import("../../proposal_normalize.zig");
const agent_turn = @import("../../agent/turn.zig");
const mcp_registry = @import("../../mcp_registry.zig");
const tool_registry = @import("../../tools/registry.zig");
const tool_args = @import("../../tools/args.zig");
const retry = @import("../../retry.zig");

pub const default_base_url = "https://api.anthropic.com";
pub const base_url_env_var = "ANTHROPIC_BASE_URL";
pub const api_version = "2023-06-01";
pub const default_context_window: usize = 200_000;
pub const default_model = "claude-sonnet-4-5";
pub const test_mode_prompt = "test_mode";
pub const max_tokens_default: u32 = 4096;

/// Anthropic Claude provider using the Messages API.
///
/// Tool use format (Claude-specific, see https://docs.anthropic.com/en/docs/build-with-claude/tool-use):
///   assistant content: [{type: "text", text: "..."}, {type: "tool_use", id, name, input}]
///   user content:      [{type: "tool_result", tool_use_id, content}]
///
/// Conversation JSON is stored as a JSON array of message objects. Each message
/// has `role` and `content` (array of content blocks). The wire format we send
/// to the API is the same as the conversation_json — no wrapping required.
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
    /// Tracks the tool_use_id of the most recently emitted tool_use block,
    /// so that the next appendToolResult can reference it correctly.
    /// Anthropic requires tool_result.tool_use_id to match a prior tool_use.id.
    /// The agent loop passes the tool *name* (not id) to appendToolResult, so
    /// we use this field as a fallback to round-trip the id.
    last_tool_use_id: ?[]u8 = null,

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
        if (self.last_tool_use_id) |id| self.allocator.free(id);
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

        const escaped_prompt = jsonEscape(allocator, prompt) catch return provider.ProviderError.ProviderInternalError;
        defer allocator.free(escaped_prompt);
        const payload = std.fmt.allocPrint(allocator,
            \\{{"model":"{s}","max_tokens":{d},"messages":[{{"role":"user","content":[{{"type":"text","text":{s}}}]}}]}}
        , .{ self.model_name, max_tokens_default, escaped_prompt }) catch return provider.ProviderError.ProviderInternalError;
        defer allocator.free(payload);

        var response_alloc = std.Io.Writer.Allocating.init(allocator);
        defer response_alloc.deinit();

        fetchMessages(self, allocator, endpoint, payload, &response_alloc.writer) catch return provider.ProviderError.NetworkError;

        const response_body = response_alloc.written();
        if (extractUsage(response_body)) |usage| {
            self.latest_usage = usage;
        }
        const text = extractTextFromResponse(allocator, response_body) catch return provider.ProviderError.MalformedResponse;
        defer allocator.free(text);

        if (text.len == 0) return provider.ProviderError.MalformedResponse;

        if (self.stream_callback) |callback| callback(self.stream_context, text);

        if (std.mem.startsWith(u8, prompt, "INTENT_CLASSIFIER_MODE") or std.mem.indexOf(u8, prompt, "MARKDOWN PLAN MODE") != null) {
            writer.writeAll(text) catch return provider.ProviderError.NetworkError;
            return;
        }

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

    /// Complete one model turn given the conversation state.
    /// conversation_json is a JSON array of messages, each with role+content[]
    /// (Anthropic Messages API format). We send it directly to the API.
    /// tool_declarations_json is a Gemini-style functionDeclarations JSON
    /// array; we convert it to Anthropic's tools schema before sending.
    fn completeTurnImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        mcp: ?*mcp_registry.Registry,
        conversation_json: []const u8,
        tool_declarations_json: []const u8,
        cancel_token: ?*const kernel.cancellation.CancellationToken,
    ) provider.ProviderError!agent_turn.Completion {
        _ = io;
        _ = mcp;
        const self: *AnthropicProvider = @ptrCast(@alignCast(ptr));

        if (cancel_token) |tok| {
            if (tok.isCancelled()) return provider.ProviderError.Cancelled;
        }

        const endpoint = std.fmt.allocPrint(allocator, "{s}/v1/messages", .{self.base_url}) catch return provider.ProviderError.ProviderInternalError;
        defer allocator.free(endpoint);

        const anthropic_tools = if (tool_declarations_json.len > 0 and !std.mem.eql(u8, tool_declarations_json, "[]"))
            convertDeclarationsToAnthropic(allocator, tool_declarations_json) catch return provider.ProviderError.ProviderInternalError
        else
            allocator.dupe(u8, "") catch return provider.ProviderError.ProviderInternalError;
        defer allocator.free(anthropic_tools);

        const payload = buildToolLoopPayload(allocator, self.model_name, conversation_json, anthropic_tools) catch return provider.ProviderError.ProviderInternalError;
        defer allocator.free(payload);

        const policy = retry.RetryPolicy{
            .max_attempts = 3,
            .base_delay_ms = 500,
            .max_delay_ms = 4000,
        };
        var prng = std.Random.DefaultPrng.init(@intCast(std.Io.Timestamp.now(self.io, .real).toMilliseconds()));

        var response_body: []const u8 = "";
        var response_alloc: std.Io.Writer.Allocating = std.Io.Writer.Allocating.init(allocator);
        defer response_alloc.deinit();

        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            if (cancel_token) |tok| {
                if (tok.isCancelled()) return provider.ProviderError.Cancelled;
            }

            if (attempt > 0) {
                const delay_ms = retry.nextDelay(policy, attempt, &prng);
                if (delay_ms > 0) {
                    var waited: u32 = 0;
                    while (waited < delay_ms) {
                        if (cancel_token) |tok| {
                            if (tok.isCancelled()) return provider.ProviderError.Cancelled;
                        }
                        const slice: u32 = @min(50, delay_ms - waited);
                        std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(@intCast(slice)), .real) catch {};
                        waited += slice;
                    }
                }
            }

            response_alloc.deinit();
            response_alloc = std.Io.Writer.Allocating.init(allocator);

            fetchMessages(self, allocator, endpoint, payload, &response_alloc.writer) catch |err| switch (err) {
                provider.ProviderError.NetworkError, provider.ProviderError.RateLimitExceeded => {
                    if (attempt + 1 < policy.max_attempts) continue;
                    return provider.ProviderError.NetworkError;
                },
                else => return provider.ProviderError.NetworkError,
            };

            response_body = response_alloc.written();
            break;
        }

        if (extractUsage(response_body)) |usage| {
            self.latest_usage = usage;
        }

        const completion_with_id = parseCompletionResponseWithId(allocator, response_body) catch |err| switch (err) {
            error.MalformedResponse => return provider.ProviderError.MalformedResponse,
            error.OutOfMemory => return provider.ProviderError.ProviderInternalError,
        };

        if (completion_with_id.tool_use_id) |id| {
            if (self.last_tool_use_id) |old| self.allocator.free(old);
            self.last_tool_use_id = self.allocator.dupe(u8, id) catch null;
        }

        return completion_with_id.completion;
    }

    /// Build Anthropic-style tools JSON array (with input_schema) from
    /// Gemini-style functionDeclarations JSON array (with parameters).
    fn toolDeclarationsJsonImpl(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        mcp: ?*mcp_registry.Registry,
    ) provider.ProviderError![]const u8 {
        const native = tool_registry.native_declarations_json;
        if (mcp) |reg| {
            const combined = reg.buildDeclarationsJson(allocator) catch return provider.ProviderError.ProviderInternalError;
            return combined;
        }
        return allocator.dupe(u8, native) catch return provider.ProviderError.ProviderInternalError;
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
        const tool_id = std.fmt.allocPrint(allocator, "toolu_{d}", .{conversation.items.len}) catch return provider.ProviderError.ProviderInternalError;
        defer allocator.free(tool_id);
        const msg = std.fmt.allocPrint(allocator, "{{\"role\":\"assistant\",\"content\":[{{\"type\":\"tool_use\",\"id\":\"{s}\",\"name\":{s},\"input\":{s}}}]}}", .{
            tool_id,
            escaped_name,
            if (call.args_json.len > 0) call.args_json else "{}",
        }) catch return provider.ProviderError.ProviderInternalError;
        defer allocator.free(msg);
        if (conversation.items.len > 0) conversation.append(allocator, ',') catch return provider.ProviderError.ProviderInternalError;
        conversation.appendSlice(allocator, msg) catch return provider.ProviderError.ProviderInternalError;
    }

    fn appendToolResultImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        conversation: *std.ArrayList(u8),
        tool_name: []const u8,
        result: []const u8,
        _: []const core_provider.ImagePart,
    ) provider.ProviderError!void {
        const self: *AnthropicProvider = @ptrCast(@alignCast(ptr));
        const escaped_result = jsonEscape(allocator, result) catch return provider.ProviderError.ProviderInternalError;
        defer allocator.free(escaped_result);

        var owned_tool_id: ?[]u8 = null;
        defer if (owned_tool_id) |id| allocator.free(id);
        const tool_id: []const u8 = blk: {
            if (self.last_tool_use_id) |id| break :blk id;
            if (std.mem.startsWith(u8, tool_name, "toolu_")) break :blk tool_name;
            owned_tool_id = std.fmt.allocPrint(allocator, "toolu_fallback_{d}", .{conversation.items.len}) catch return provider.ProviderError.ProviderInternalError;
            break :blk owned_tool_id.?;
        };

        const msg = std.fmt.allocPrint(allocator, "{{\"role\":\"user\",\"content\":[{{\"type\":\"tool_result\",\"tool_use_id\":\"{s}\",\"content\":{s}}}]}}", .{
            tool_id,
            escaped_result,
        }) catch return provider.ProviderError.ProviderInternalError;
        defer allocator.free(msg);
        if (conversation.items.len > 0) conversation.append(allocator, ',') catch return provider.ProviderError.ProviderInternalError;
        conversation.appendSlice(allocator, msg) catch return provider.ProviderError.ProviderInternalError;

        if (self.last_tool_use_id) |id| {
            self.allocator.free(id);
            self.last_tool_use_id = null;
        }
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

fn buildToolLoopPayload(allocator: std.mem.Allocator, model: []const u8, conversation_json: []const u8, tools_json: []const u8) ![]u8 {
    const conv = if (std.mem.eql(u8, conversation_json, "[]") or conversation_json.len == 0)
        "[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"(empty)\"}]}]"
    else
        conversation_json;

    if (tools_json.len > 0 and !std.mem.eql(u8, tools_json, "[]")) {
        return std.fmt.allocPrint(allocator,
            \\{{"model":"{s}","max_tokens":{d},"messages":{s},"tools":{s}}}
        , .{ model, max_tokens_default, conv, tools_json });
    }
    return std.fmt.allocPrint(allocator,
        \\{{"model":"{s}","max_tokens":{d},"messages":{s}}}
    , .{ model, max_tokens_default, conv });
}

fn convertDeclarationsToAnthropic(allocator: std.mem.Allocator, declarations_json: []const u8) ![]u8 {
    const Decl = struct {
        name: []const u8,
        description: []const u8 = "",
        parameters: std.json.Value,
    };
    var parsed = std.json.parseFromSlice([]const Decl, allocator, declarations_json, .{
        .ignore_unknown_fields = true,
    }) catch return error.MalformedResponse;
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    for (parsed.value, 0..) |decl, i| {
        if (i > 0) try out.append(allocator, ',');
        const params_json = try std.json.Stringify.valueAlloc(allocator, decl.parameters, .{});
        defer allocator.free(params_json);
        const escaped_desc = try jsonEscape(allocator, decl.description);
        defer allocator.free(escaped_desc);
        const piece = try std.fmt.allocPrint(allocator,
            \\{{"name":"{s}","description":{s},"input_schema":{s}}}
        , .{ decl.name, escaped_desc, params_json });
        defer allocator.free(piece);
        try out.appendSlice(allocator, piece);
    }
    try out.append(allocator, ']');
    return try out.toOwnedSlice(allocator);
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
        return switch (result.status) {
            .unauthorized, .forbidden => provider.ProviderError.AuthenticationFailed,
            .too_many_requests => provider.ProviderError.RateLimitExceeded,
            .payload_too_large => provider.ProviderError.ContextLengthExceeded,
            .request_timeout, .service_unavailable, .bad_gateway, .gateway_timeout, .internal_server_error => provider.ProviderError.NetworkError,
            else => provider.ProviderError.NetworkError,
        };
    }

    const body = response_alloc.written();
    response_writer.writeAll(body) catch return provider.ProviderError.NetworkError;
}

const ParsedCompletion = struct {
    completion: agent_turn.Completion,
    tool_use_id: ?[]const u8 = null,
};

fn parseCompletionResponseWithId(allocator: std.mem.Allocator, body: []const u8) !ParsedCompletion {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.MalformedResponse;
    defer parsed.deinit();

    if (parsed.value != .object) return error.MalformedResponse;

    if (parsed.value.object.get("error")) |err_val| {
        if (err_val == .object) {
            if (err_val.object.get("type")) |type_val| {
                if (type_val == .string) {
                    if (std.mem.eql(u8, type_val.string, "overloaded_error")) return error.MalformedResponse;
                }
            }
        }
        return error.MalformedResponse;
    }

    const content = parsed.value.object.get("content") orelse return error.MalformedResponse;
    if (content != .array) return error.MalformedResponse;
    if (content.array.items.len == 0) return error.MalformedResponse;

    for (content.array.items) |block| {
        if (block != .object) continue;
        const block_type = block.object.get("type") orelse continue;
        if (block_type != .string) continue;
        if (!std.mem.eql(u8, block_type.string, "tool_use")) continue;

        const name_val = block.object.get("name") orelse continue;
        if (name_val != .string) continue;
        const input_val = block.object.get("input") orelse std.json.Value{ .object = .{} };
        const id_val = block.object.get("id");

        const args_json = try std.json.Stringify.valueAlloc(allocator, input_val, .{});
        errdefer allocator.free(args_json);

        const tool_use_id: ?[]const u8 = if (id_val) |v| (if (v == .string) try allocator.dupe(u8, v.string) else null) else null;

        return .{
            .completion = .{ .tool_call = .{
                .name = try allocator.dupe(u8, name_val.string),
                .args_json = args_json,
            } },
            .tool_use_id = tool_use_id,
        };
    }

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

    if (buf.items.len == 0) return error.MalformedResponse;
    return .{ .completion = .{ .text = try buf.toOwnedSlice(allocator) } };
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

fn extractUsage(body: []const u8) ?provider.TokenUsage {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const usage_val = parsed.value.object.get("usage") orelse return null;
    if (usage_val != .object) return null;

    var usage: provider.TokenUsage = .{};
    if (usage_val.object.get("input_tokens")) |v| {
        if (v == .integer) usage.prompt_tokens = @intCast(v.integer);
    }
    if (usage_val.object.get("output_tokens")) |v| {
        if (v == .integer) usage.completion_tokens = @intCast(v.integer);
    }
    usage.total_tokens = usage.prompt_tokens + usage.completion_tokens;
    return usage;
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

// =============================================================================
// Tests
// =============================================================================

test "Anthropic provider create requires credentials" {
    const allocator = std.testing.allocator;
    const result = AnthropicProvider.create(allocator, std.testing.io, null, .{
        .model = "claude-sonnet-4-5",
    });
    try std.testing.expectError(error.MissingCredentials, result);
}

test "buildToolLoopPayload with tools" {
    const allocator = std.testing.allocator;
    const conv = "[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}]";
    const tools = "[{\"name\":\"search\",\"description\":\"grep\",\"input_schema\":{\"type\":\"object\"}}]";
    const payload = try buildToolLoopPayload(allocator, "claude-sonnet-4-5", conv, tools);
    defer allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"model\":\"claude-sonnet-4-5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"max_tokens\":4096") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"messages\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"tools\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"input_schema\"") != null);
}

test "buildToolLoopPayload without tools" {
    const allocator = std.testing.allocator;
    const conv = "[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}]";
    const payload = try buildToolLoopPayload(allocator, "claude-sonnet-4-5", conv, "");
    defer allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"tools\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"messages\":") != null);
}

test "buildToolLoopPayload empty conversation injects placeholder" {
    const allocator = std.testing.allocator;
    const payload = try buildToolLoopPayload(allocator, "claude-sonnet-4-5", "[]", "");
    defer allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "(empty)") != null);
}

test "convertDeclarationsToAnthropic converts parameters to input_schema" {
    const allocator = std.testing.allocator;
    const gemini_decls =
        \\[{"name":"search","description":"grep workspace","parameters":{"type":"object","properties":{"pattern":{"type":"string"}}}}]
    ;
    const anthropic_tools = try convertDeclarationsToAnthropic(allocator, gemini_decls);
    defer allocator.free(anthropic_tools);
    try std.testing.expect(std.mem.indexOf(u8, anthropic_tools, "\"input_schema\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, anthropic_tools, "\"parameters\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, anthropic_tools, "\"name\":\"search\"") != null);
}

test "parseCompletionResponseWithId extracts tool_call and id" {
    const allocator = std.testing.allocator;
    const body =
        \\{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":"Let me search."},{"type":"tool_use","id":"toolu_abc","name":"search","input":{"pattern":"foo"}}],"stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":20}}
    ;
    var result = try parseCompletionResponseWithId(allocator, body);
    defer {
        if (result.tool_use_id) |id| allocator.free(id);
        result.completion.deinit(allocator);
    }
    try std.testing.expect(result.completion == .tool_call);
    try std.testing.expectEqualStrings("search", result.completion.tool_call.name);
    try std.testing.expect(std.mem.indexOf(u8, result.completion.tool_call.args_json, "foo") != null);
    try std.testing.expectEqualStrings("toolu_abc", result.tool_use_id.?);
}

test "parseCompletionResponseWithId extracts text when no tool_use" {
    const allocator = std.testing.allocator;
    const body =
        \\{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":"Hello "},{"type":"text","text":"world"}],"stop_reason":"end_turn","usage":{"input_tokens":5,"output_tokens":10}}
    ;
    var result = try parseCompletionResponseWithId(allocator, body);
    defer result.completion.deinit(allocator);
    try std.testing.expect(result.completion == .text);
    try std.testing.expectEqualStrings("Hello world", result.completion.text);
    try std.testing.expect(result.tool_use_id == null);
}

test "parseCompletionResponseWithId returns malformed on empty content array" {
    const allocator = std.testing.allocator;
    const body =
        \\{"id":"msg_1","type":"message","role":"assistant","content":[]}
    ;
    try std.testing.expectError(error.MalformedResponse, parseCompletionResponseWithId(allocator, body));
}

test "parseCompletionResponseWithId returns malformed on error response" {
    const allocator = std.testing.allocator;
    const body =
        \\{"type":"error","error":{"type":"overloaded_error","message":"server overloaded"}}
    ;
    try std.testing.expectError(error.MalformedResponse, parseCompletionResponseWithId(allocator, body));
}

test "extractTextFromResponse parses text blocks" {
    const allocator = std.testing.allocator;
    const body = "{\"content\":[{\"type\":\"text\",\"text\":\"hello\"},{\"type\":\"text\",\"text\":\" world\"}]}";
    const text = try extractTextFromResponse(allocator, body);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("hello world", text);
}

test "extractUsage parses input and output tokens" {
    const body =
        \\{"id":"msg_1","usage":{"input_tokens":42,"output_tokens":13}}
    ;
    const usage = extractUsage(body).?;
    try std.testing.expectEqual(@as(usize, 42), usage.prompt_tokens);
    try std.testing.expectEqual(@as(usize, 13), usage.completion_tokens);
    try std.testing.expectEqual(@as(usize, 55), usage.total_tokens);
}

test "jsonEscape escapes special chars" {
    const allocator = std.testing.allocator;
    const escaped = try jsonEscape(allocator, "hello\n\"world\"");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("\"hello\\n\\\"world\\\"\"", escaped);
}

test "appendToolUserTextImpl appends valid message" {
    const allocator = std.testing.allocator;
    var conversation: std.ArrayList(u8) = .empty;
    defer conversation.deinit(allocator);
    try AnthropicProvider.appendToolUserTextImpl(undefined, allocator, &conversation, "hello");
    try std.testing.expect(std.mem.indexOf(u8, conversation.items, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, conversation.items, "\"type\":\"text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, conversation.items, "hello") != null);
}

test "appendToolCallImpl appends assistant tool_use block" {
    const allocator = std.testing.allocator;
    var conversation: std.ArrayList(u8) = .empty;
    defer conversation.deinit(allocator);
    const call = agent_turn.ToolCall{
        .name = "search",
        .args_json = "{\"pattern\":\"foo\"}",
    };
    try AnthropicProvider.appendToolCallImpl(undefined, allocator, &conversation, call);
    try std.testing.expect(std.mem.indexOf(u8, conversation.items, "\"role\":\"assistant\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, conversation.items, "\"type\":\"tool_use\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, conversation.items, "toolu_") != null);
    try std.testing.expect(std.mem.indexOf(u8, conversation.items, "\"input\":{\"pattern\":\"foo\"}") != null);
}

test "appendToolResultImpl appends user tool_result block with last_tool_use_id" {
    const allocator = std.testing.allocator;
    var provider_state = AnthropicProvider{
        .allocator = allocator,
        .io = std.testing.io,
        .creds = .{
            .allocator = allocator,
            .api_key = try allocator.dupe(u8, "test"),
            .source = .environment,
        },
        .base_url = try allocator.dupe(u8, "https://api.anthropic.com"),
        .model_name = try allocator.dupe(u8, "claude-sonnet-4-5"),
        .meta = .{
            .provider_name = "anthropic",
            .model_name = "claude-sonnet-4-5",
            .context_window = 200_000,
        },
        .latest_usage = .{},
        .last_tool_use_id = try allocator.dupe(u8, "toolu_abc"),
    };
    defer {
        provider_state.creds.deinit();
        allocator.free(provider_state.base_url);
        allocator.free(provider_state.model_name);
        if (provider_state.last_tool_use_id) |id| allocator.free(id);
    }
    var conversation: std.ArrayList(u8) = .empty;
    defer conversation.deinit(allocator);
    try AnthropicProvider.appendToolResultImpl(@ptrCast(&provider_state), allocator, &conversation, "search", "found 3 matches", &.{});
    try std.testing.expect(std.mem.indexOf(u8, conversation.items, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, conversation.items, "\"type\":\"tool_result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, conversation.items, "\"tool_use_id\":\"toolu_abc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, conversation.items, "found 3 matches") != null);
    try std.testing.expect(provider_state.last_tool_use_id == null);
}

test "toolDeclarationsJsonImpl returns native declarations when no MCP" {
    const allocator = std.testing.allocator;
    const decls = try AnthropicProvider.toolDeclarationsJsonImpl(undefined, allocator, null);
    defer allocator.free(decls);
    try std.testing.expect(std.mem.indexOf(u8, decls, "read_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, decls, "search") != null);
}
