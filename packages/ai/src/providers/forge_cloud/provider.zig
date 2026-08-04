//! Forge Cloud provider — calls the backend proxy instead of LLM
//! directly. The backend handles:
//!   - JWT verification (user must be logged in)
//!   - System prompt injection (server-side, client never sees it)
//!   - LLM API call (OpenAI-compatible, server-side API key)
//!   - Usage logging
//!   - Conversation history saving
//!
//! The provider needs:
//!   - `proxy_url`: the backend Edge Function URL (e.g. https://project.supabase.co/functions/v1/llm-proxy)
//!   - `access_token`: the user's JWT (from Supabase Auth)
//!   - `model`: the model ID to use
//!
//! The provider implements the same Provider interface as OpenAI/etc.
//! so the agent loop, planner, and inline completion all work without
//! changes — they just call `provider.ask()` which internally hits
//! the backend proxy.

const std = @import("std");
const provider = @import("../../provider.zig");
const kernel = @import("forge-kernel");
const agent_turn = @import("../../agent/turn.zig");
const mcp_registry = @import("../../mcp_registry.zig");

pub const default_context_window: usize = 128_000;

pub const ForgeCloudProvider = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Backend proxy URL, e.g. "https://project.supabase.co/functions/v1/llm-proxy"
    proxy_url: []u8,
    /// User's JWT (from Supabase Auth login).
    access_token: []u8,
    /// Model ID to send to the backend.
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
        _ = environ_map;

        // Extract proxy_url from options or use default.
        const proxy_url: []const u8 = blk: {
            if (@hasField(@TypeOf(options), "base_url")) {
                if (@typeInfo(@TypeOf(options.base_url)) == .optional) {
                    if (options.base_url) |url| break :blk url;
                } else {
                    break :blk options.base_url;
                }
            }
            break :blk "https://forge-cloud.supabase.co/functions/v1/llm-proxy";
        };

        // Extract model name.
        const model_name: []const u8 = if (@hasField(@TypeOf(options), "model"))
            (if (@typeInfo(@TypeOf(options.model)) == .optional) options.model orelse "gpt-4o" else options.model)
        else
            "gpt-4o";

        // Extract access_token — stored in options via a custom field.
        // The workbench passes the JWT through the stream_context or a
        // dedicated field. We check for both.
        const access_token: []const u8 = blk: {
            if (@hasField(@TypeOf(options), "access_token")) {
                if (@typeInfo(@TypeOf(options.access_token)) == .optional) {
                    if (options.access_token) |t| break :blk t;
                } else {
                    break :blk options.access_token;
                }
            }
            break :blk "";
        };

        if (access_token.len == 0) {
            return error.MissingCredentials;
        }

        const owned_proxy = try allocator.dupe(u8, proxy_url);
        errdefer allocator.free(owned_proxy);
        const owned_token = try allocator.dupe(u8, access_token);
        errdefer allocator.free(owned_token);
        const owned_model = try allocator.dupe(u8, model_name);
        errdefer allocator.free(owned_model);

        const ptr = try allocator.create(ForgeCloudProvider);
        ptr.* = .{
            .allocator = allocator,
            .io = io,
            .proxy_url = owned_proxy,
            .access_token = owned_token,
            .model_name = owned_model,
            .meta = .{
                .provider_name = "forge_cloud",
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
        const self: *ForgeCloudProvider = @ptrCast(@alignCast(ptr));
        // Secure-zero the access token before freeing.
        std.crypto.secureZero(u8, self.access_token);
        allocator.free(self.proxy_url);
        allocator.free(self.access_token);
        allocator.free(self.model_name);
        allocator.destroy(self);
    }

    // ─── Provider interface ──────────────────────────────────────────

    fn ask(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        prompt: []const u8,
        images: []const provider.ImagePart,
        writer: *std.Io.Writer,
        cancel_token: *const kernel.cancellation.CancellationToken,
    ) provider.ProviderError!void {
        _ = images;
        const self: *ForgeCloudProvider = @ptrCast(@alignCast(ptr));
        if (cancel_token.isCancelled()) return provider.ProviderError.Cancelled;

        // Build OpenAI-compatible request body:
        // POST {proxy_url}
        // {
        //   "model": "<model_name>",
        //   "messages": [{ "role": "user", "content": "<prompt>" }],
        //   "stream": false,
        //   "request_kind": "chat"
        // }
        const escaped_prompt = jsonEscape(allocator, prompt) catch
            return provider.ProviderError.ProviderInternalError;
        defer allocator.free(escaped_prompt);

        const payload = std.fmt.allocPrint(allocator,
            \\{{"model":"{s}","messages":[{{"role":"user","content":{s}}}],"stream":false,"request_kind":"chat"}}
        , .{
            self.model_name,
            escaped_prompt,
        }) catch return provider.ProviderError.ProviderInternalError;
        defer allocator.free(payload);

        // Endpoint is the proxy_url itself (no /v1/chat/completions suffix).
        // The backend Edge Function handles routing internally.
        const endpoint = self.proxy_url;

        // Build auth header.
        const auth_header = std.fmt.allocPrint(allocator, "Bearer {s}", .{self.access_token}) catch
            return provider.ProviderError.ProviderInternalError;
        defer allocator.free(auth_header);

        const headers = [_]std.http.Header{
            .{ .name = "Authorization", .value = auth_header },
        };

        var response_alloc = std.Io.Writer.Allocating.init(allocator);
        defer response_alloc.deinit();

        var client = std.http.Client{ .allocator = allocator, .io = self.io };
        defer client.deinit();

        const result = client.fetch(.{
            .location = .{ .url = endpoint },
            .method = .POST,
            .payload = payload,
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .extra_headers = &headers,
            .response_writer = &response_alloc.writer,
        }) catch return provider.ProviderError.NetworkError;

        const body = response_alloc.writer.buffer[0..response_alloc.writer.end];

        return switch (result.status) {
            .ok => {
                // Parse backend response:
                // { "text": "...", "model": "...", "usage": { ... } }
                const text = parseBackendResponseText(allocator, body) catch return provider.ProviderError.MalformedResponse;
                defer allocator.free(text);

                writer.writeAll(text) catch return provider.ProviderError.ProviderInternalError;

                if (self.stream_callback) |cb| {
                    if (self.stream_context) |ctx| cb(ctx, text);
                }

                if (parseBackendResponseUsage(body)) |parsed_usage| {
                    self.latest_usage = parsed_usage;
                }
            },
            .unauthorized, .forbidden => provider.ProviderError.AuthenticationFailed,
            .too_many_requests => provider.ProviderError.RateLimitExceeded,
            .payload_too_large, .bad_request => provider.ProviderError.ContextLengthExceeded,
            .request_timeout, .service_unavailable, .bad_gateway, .gateway_timeout => provider.ProviderError.NetworkError,
            else => provider.ProviderError.ProviderInternalError,
        };
    }

    fn metadata(ptr: *const anyopaque) provider.ModelMetadata {
        const self: *const ForgeCloudProvider = @ptrCast(@alignCast(ptr));
        return self.meta;
    }

    fn usage(ptr: *const anyopaque) provider.TokenUsage {
        const self: *const ForgeCloudProvider = @ptrCast(@alignCast(ptr));
        return self.latest_usage;
    }

    fn supportsToolLoop(ptr: *const anyopaque) bool {
        _ = ptr;
        return false; // Tool loop handled by agent loop, not provider.
    }

    fn completeTurn(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        mcp: ?*mcp_registry.Registry,
        conversation_json: []const u8,
        tool_declarations_json: []const u8,
        cancel_token: ?*const kernel.cancellation.CancellationToken,
    ) provider.ProviderError!agent_turn.Completion {
        _ = ptr;
        _ = allocator;
        _ = io;
        _ = mcp;
        _ = conversation_json;
        _ = tool_declarations_json;
        _ = cancel_token;
        // Tool loop is not supported via forge_cloud — the agent loop
        // handles multi-turn tool calls by calling ask() repeatedly.
        return provider.ProviderError.ProviderInternalError;
    }

    fn toolDeclarationsJson(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        mcp: ?*mcp_registry.Registry,
    ) provider.ProviderError![]const u8 {
        _ = ptr;
        _ = allocator;
        _ = mcp;
        return "[]";
    }

    fn appendToolUserText(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        conversation: *std.ArrayList(u8),
        text: []const u8,
    ) provider.ProviderError!void {
        _ = ptr;
        conversation.appendSlice(allocator, text) catch return provider.ProviderError.ProviderInternalError;
    }

    fn appendToolCall(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        conversation: *std.ArrayList(u8),
        call: agent_turn.ToolCall,
    ) provider.ProviderError!void {
        _ = ptr;
        _ = allocator;
        _ = conversation;
        _ = call;
    }

    fn appendToolResult(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        conversation: *std.ArrayList(u8),
        tool_name: []const u8,
        result: []const u8,
        images: []const provider.ImagePart,
    ) provider.ProviderError!void {
        _ = ptr;
        _ = allocator;
        _ = conversation;
        _ = tool_name;
        _ = result;
        _ = images;
    }

    fn providerInterface(self: *ForgeCloudProvider) provider.Provider {
        return .{
            .ptr = self,
            .vtable = &.{
                .ask = ask,
                .metadata = metadata,
                .usage = usage,
                .supports_tool_loop = supportsToolLoop,
                .complete_turn = completeTurn,
                .tool_declarations_json = toolDeclarationsJson,
                .append_tool_user_text = appendToolUserText,
                .append_tool_call = appendToolCall,
                .append_tool_result = appendToolResult,
                .deinit = deinit,
            },
        };
    }
};

// ─── Helpers ──────────────────────────────────────────────────────────

/// Parse the "text" field from a backend LLM proxy response.
/// Expected shape: { "text": "...", "model": "...", "usage": { ... } }
fn parseBackendResponseText(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    const Parsed = struct {
        text: []const u8,
        model: []const u8 = "",
    };
    var parsed = std.json.parseFromSlice(Parsed, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch return error.MalformedResponse;
    defer parsed.deinit();
    if (parsed.value.text.len == 0) return error.MalformedResponse;
    return allocator.dupe(u8, parsed.value.text);
}

/// Parse the "usage" field from a backend LLM proxy response.
fn parseBackendResponseUsage(body: []const u8) ?provider.TokenUsage {
    const Parsed = struct {
        usage: ?struct {
            prompt_tokens: usize = 0,
            completion_tokens: usize = 0,
            total_tokens: usize = 0,
        } = null,
    };
    var parsed = std.json.parseFromSlice(Parsed, std.heap.page_allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();
    const u = parsed.value.usage orelse return null;
    return .{
        .prompt_tokens = u.prompt_tokens,
        .completion_tokens = u.completion_tokens,
        .total_tokens = u.total_tokens,
    };
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
