const std = @import("std");
const kernel = @import("forge-kernel");

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
};

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

    pub fn errorMessage(err: ProviderError) []const u8 {
        return switch (err) {
            error.AuthenticationFailed => "AI provider authentication failed — check API key or Ollama access",
            error.RateLimitExceeded => "AI provider quota exceeded",
            error.ContextLengthExceeded => "Prompt too large for the selected model",
            error.NetworkError => "Network error calling AI provider — is Ollama running on localhost:11434?",
            error.MalformedResponse => "AI provider returned an unexpected response",
            error.ProviderInternalError => "AI provider error",
        };
    }
};
