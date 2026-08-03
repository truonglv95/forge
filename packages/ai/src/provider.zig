const std = @import("std");
const kernel = @import("forge-kernel");
const agent_turn = @import("agent/turn.zig");
const mcp_registry = @import("mcp_registry.zig");

pub const TokenUsage = struct {
    prompt_tokens: usize = 0,
    completion_tokens: usize = 0,
    total_tokens: usize = 0,
};

pub const FinishReason = enum {
    stop,
    length,
    content_filter,
    tool_calls,
    unknown,
};

pub const ModelMetadata = struct {
    provider_name: []const u8,
    model_name: []const u8,
    context_window: usize,
};

pub const ProviderCapabilities = struct {
    streaming: bool = true,
    tool_calls: bool = false,
    json_mode: bool = true,
    thinking: bool = false,
    embeddings: bool = false,
    images: bool = false,
};

pub const ImagePart = struct {
    mime_type: []const u8,
    data_base64: []const u8,
};

pub const ProviderError = error{
    AuthenticationFailed,
    RateLimitExceeded,
    ContextLengthExceeded,
    ProviderInternalError,
    NetworkError,
    MalformedResponse,
    Cancelled,
};

/// Stubs for providers that do not support native tool loops (e.g. fake).
pub const tool_loop_stubs = struct {
    pub fn supports(_: *const anyopaque) bool {
        return false;
    }

    pub fn completeTurn(
        _: *anyopaque,
        _: std.mem.Allocator,
        _: std.Io,
        _: ?*mcp_registry.Registry,
        _: []const u8,
        _: []const u8,
        _: ?*const kernel.cancellation.CancellationToken,
    ) ProviderError!agent_turn.Completion {
        return error.ProviderInternalError;
    }

    pub fn toolDeclarationsJson(
        _: *anyopaque,
        _: std.mem.Allocator,
        _: ?*mcp_registry.Registry,
    ) ProviderError![]const u8 {
        return error.ProviderInternalError;
    }

    pub fn appendToolUserText(
        _: *anyopaque,
        _: std.mem.Allocator,
        _: *std.ArrayList(u8),
        _: []const u8,
    ) ProviderError!void {
        return error.ProviderInternalError;
    }

    pub fn appendToolCall(
        _: *anyopaque,
        _: std.mem.Allocator,
        _: *std.ArrayList(u8),
        _: agent_turn.ToolCall,
    ) ProviderError!void {
        return error.ProviderInternalError;
    }

    pub fn appendToolResult(
        _: *anyopaque,
        _: std.mem.Allocator,
        _: *std.ArrayList(u8),
        _: []const u8,
        _: []const u8,
        _: []const ImagePart,
    ) ProviderError!void {
        return error.ProviderInternalError;
    }
};

pub fn mapTransportError(err: agent_turn.TransportError) ProviderError {
    return switch (err) {
        error.Cancelled => error.Cancelled,
        error.AuthenticationFailed => error.AuthenticationFailed,
        error.RateLimitExceeded => error.RateLimitExceeded,
        error.ContextLengthExceeded => error.ContextLengthExceeded,
        error.NetworkError => error.NetworkError,
        error.MalformedResponse => error.MalformedResponse,
        error.ProviderFailed => error.ProviderInternalError,
        error.OutOfMemory => error.ProviderInternalError,
    };
}

fn mapProviderToTransportError(err: ProviderError) agent_turn.TransportError {
    return switch (err) {
        error.Cancelled => error.Cancelled,
        error.AuthenticationFailed => error.AuthenticationFailed,
        error.RateLimitExceeded => error.RateLimitExceeded,
        error.ContextLengthExceeded => error.ContextLengthExceeded,
        error.NetworkError => error.NetworkError,
        error.MalformedResponse => error.MalformedResponse,
        else => error.ProviderFailed,
    };
}

/// Provider interface vtable.
pub const Provider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        ask: *const fn (
            *anyopaque,
            allocator: std.mem.Allocator,
            prompt: []const u8,
            images: []const ImagePart,
            writer: *std.Io.Writer,
            cancel_token: *const kernel.cancellation.CancellationToken,
        ) ProviderError!void,
        metadata: *const fn (*const anyopaque) ModelMetadata,
        usage: *const fn (*const anyopaque) TokenUsage,
        supports_tool_loop: *const fn (*const anyopaque) bool,
        complete_turn: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            io: std.Io,
            mcp: ?*mcp_registry.Registry,
            conversation_json: []const u8,
            tool_declarations_json: []const u8,
            cancel_token: ?*const kernel.cancellation.CancellationToken,
        ) ProviderError!agent_turn.Completion,
        tool_declarations_json: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            mcp: ?*mcp_registry.Registry,
        ) ProviderError![]const u8,
        append_tool_user_text: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            conversation: *std.ArrayList(u8),
            text: []const u8,
        ) ProviderError!void,
        append_tool_call: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            conversation: *std.ArrayList(u8),
            call: agent_turn.ToolCall,
        ) ProviderError!void,
        append_tool_result: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            conversation: *std.ArrayList(u8),
            tool_name: []const u8,
            result: []const u8,
            images: []const ImagePart,
        ) ProviderError!void,
        deinit: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
    };

    pub const ToolLoopBinding = struct {
        provider: Provider,
        io: std.Io,
        mcp: ?*mcp_registry.Registry,
        cancel_token: ?*const kernel.cancellation.CancellationToken,

        pub fn transport(self: *ToolLoopBinding) agent_turn.Transport {
            return .{
                .ptr = self,
                .complete_turn = bindingCompleteTurn,
                .append_user_text = bindingAppendUserText,
                .append_tool_call = bindingAppendToolCall,
                .append_tool_result = bindingAppendToolResult,
            };
        }

        fn bindingCompleteTurn(
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            conversation_json: []const u8,
            tool_declarations_json: []const u8,
            cancel_token: ?*const kernel.cancellation.CancellationToken,
        ) agent_turn.TransportError!agent_turn.Completion {
            const self: *ToolLoopBinding = @ptrCast(@alignCast(ptr));
            return self.provider.completeTurn(
                allocator,
                self.io,
                self.mcp,
                conversation_json,
                tool_declarations_json,
                cancel_token orelse self.cancel_token,
            ) catch |err| return mapProviderToTransportError(err);
        }

        fn bindingAppendUserText(
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            conversation: *std.ArrayList(u8),
            text: []const u8,
        ) agent_turn.TransportError!void {
            const self: *ToolLoopBinding = @ptrCast(@alignCast(ptr));
            return self.provider.appendToolUserText(allocator, conversation, text) catch |err| return mapProviderToTransportError(err);
        }

        fn bindingAppendToolCall(
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            conversation: *std.ArrayList(u8),
            call: agent_turn.ToolCall,
        ) agent_turn.TransportError!void {
            const self: *ToolLoopBinding = @ptrCast(@alignCast(ptr));
            return self.provider.appendToolCall(allocator, conversation, call) catch |err| return mapProviderToTransportError(err);
        }

        fn bindingAppendToolResult(
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            conversation: *std.ArrayList(u8),
            tool_name: []const u8,
            result: []const u8,
            images: []const ImagePart,
        ) agent_turn.TransportError!void {
            const self: *ToolLoopBinding = @ptrCast(@alignCast(ptr));
            return self.provider.appendToolResult(allocator, conversation, tool_name, result, images) catch |err| return mapProviderToTransportError(err);
        }
    };

    pub fn ask(
        self: Provider,
        allocator: std.mem.Allocator,
        prompt: []const u8,
        images: []const ImagePart,
        writer: *std.Io.Writer,
        cancel_token: *const kernel.cancellation.CancellationToken,
    ) ProviderError!void {
        return self.vtable.ask(self.ptr, allocator, prompt, images, writer, cancel_token);
    }

    pub fn metadata(self: Provider) ModelMetadata {
        return self.vtable.metadata(self.ptr);
    }

    pub fn usage(self: Provider) TokenUsage {
        return self.vtable.usage(self.ptr);
    }

    pub fn supportsToolLoop(self: Provider) bool {
        return self.vtable.supports_tool_loop(self.ptr);
    }

    pub fn capabilities(self: Provider) ProviderCapabilities {
        const meta = self.metadata();
        return .{
            .tool_calls = self.supportsToolLoop(),
            .thinking = std.mem.eql(u8, meta.provider_name, "gemini"),
            .embeddings = std.mem.eql(u8, meta.provider_name, "gemini") or
                std.mem.eql(u8, meta.provider_name, "ollama"),
        };
    }

    pub fn completeTurn(
        self: Provider,
        allocator: std.mem.Allocator,
        io: std.Io,
        mcp: ?*mcp_registry.Registry,
        conversation_json: []const u8,
        tool_declarations_json: []const u8,
        cancel_token: ?*const kernel.cancellation.CancellationToken,
    ) ProviderError!agent_turn.Completion {
        return self.vtable.complete_turn(
            self.ptr,
            allocator,
            io,
            mcp,
            conversation_json,
            tool_declarations_json,
            cancel_token,
        );
    }

    pub fn toolDeclarationsJson(
        self: Provider,
        allocator: std.mem.Allocator,
        mcp: ?*mcp_registry.Registry,
    ) ProviderError![]const u8 {
        return self.vtable.tool_declarations_json(self.ptr, allocator, mcp);
    }

    pub fn appendToolUserText(
        self: Provider,
        allocator: std.mem.Allocator,
        conversation: *std.ArrayList(u8),
        text: []const u8,
    ) ProviderError!void {
        return self.vtable.append_tool_user_text(self.ptr, allocator, conversation, text);
    }

    pub fn appendToolCall(
        self: Provider,
        allocator: std.mem.Allocator,
        conversation: *std.ArrayList(u8),
        call: agent_turn.ToolCall,
    ) ProviderError!void {
        return self.vtable.append_tool_call(self.ptr, allocator, conversation, call);
    }

    pub fn appendToolResult(
        self: Provider,
        allocator: std.mem.Allocator,
        conversation: *std.ArrayList(u8),
        tool_name: []const u8,
        result: []const u8,
        images: []const ImagePart,
    ) ProviderError!void {
        return self.vtable.append_tool_result(self.ptr, allocator, conversation, tool_name, result, images);
    }

    pub fn deinit(self: Provider, allocator: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }

    pub fn toolLoopBinding(
        self: Provider,
        io: std.Io,
        mcp: ?*mcp_registry.Registry,
        cancel_token: ?*const kernel.cancellation.CancellationToken,
    ) ToolLoopBinding {
        return .{ .provider = self, .io = io, .mcp = mcp, .cancel_token = cancel_token };
    }

    pub fn errorMessage(err: ProviderError) []const u8 {
        return switch (err) {
            error.AuthenticationFailed => "AI provider authentication failed — check API key or Ollama access",
            error.RateLimitExceeded => "AI provider quota exceeded",
            error.ContextLengthExceeded => "Prompt too large for the selected model",
            error.NetworkError => "Network error calling AI provider — is Ollama running on localhost:11434?",
            error.MalformedResponse => "AI provider returned an unexpected response",
            error.ProviderInternalError => "AI provider error",
            error.Cancelled => "AI request cancelled",
        };
    }
};
