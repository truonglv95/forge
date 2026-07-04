const std = @import("std");
const provider = @import("provider.zig");
const kernel = @import("forge-kernel");
const streaming = @import("streaming.zig");

pub const FakeProvider = struct {
    response: []const u8,
    plan_response: ?[]const u8 = null,
    simulated_usage: provider.TokenUsage,
    meta: provider.ModelMetadata,
    stream_callback: ?*const fn (?*anyopaque, []const u8) void = null,
    stream_context: ?*anyopaque = null,

    pub fn init(
        response: []const u8,
        stream_callback: ?*const fn (?*anyopaque, []const u8) void,
        stream_context: ?*anyopaque,
    ) FakeProvider {
        return initWithPlan(response, null, stream_callback, stream_context);
    }

    pub fn initWithPlan(
        response: []const u8,
        plan_response: ?[]const u8,
        stream_callback: ?*const fn (?*anyopaque, []const u8) void,
        stream_context: ?*anyopaque,
    ) FakeProvider {
        return .{
            .response = response,
            .plan_response = plan_response,
            .simulated_usage = .{ .prompt_tokens = 10, .completion_tokens = 20, .total_tokens = 30 },
            .meta = .{
                .provider_name = "fake",
                .model_name = "fake-model-1",
                .context_window = 4096,
            },
            .stream_callback = stream_callback,
            .stream_context = stream_context,
        };
    }

    pub fn providerInterface(self: *FakeProvider) provider.Provider {
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
        images: []const provider.ImagePart,
        writer: *std.Io.Writer,
        cancel_token: *const kernel.cancellation.CancellationToken,
    ) provider.ProviderError!void {
        _ = allocator;
        _ = images;
        const self: *FakeProvider = @ptrCast(@alignCast(ptr));

        if (cancel_token.isCancelled()) return provider.ProviderError.NetworkError;

        const payload = if (std.mem.indexOf(u8, prompt, "MARKDOWN PLAN MODE") != null)
            self.plan_response orelse self.response
        else
            self.response;

        try streaming.writeChunks(payload, writer, cancel_token, .{
            .on_chunk = self.stream_callback,
            .on_chunk_context = self.stream_context,
        });
    }

    fn metadataImpl(ptr: *const anyopaque) provider.ModelMetadata {
        const self: *const FakeProvider = @ptrCast(@alignCast(ptr));
        return self.meta;
    }

    fn usageImpl(ptr: *const anyopaque) provider.TokenUsage {
        const self: *const FakeProvider = @ptrCast(@alignCast(ptr));
        return self.simulated_usage;
    }
};

test "FakeProvider honours cancellation while streaming" {
    var fake = FakeProvider.init("0123456789012345678901234567890", null, null);
    const p = fake.providerInterface();

    var buffer: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    var w_alloc = std.Io.Writer.Allocating.init(allocator);
    defer w_alloc.deinit();

    var cancel_src = try kernel.cancellation.CancellationTokenSource.init(allocator);
    defer cancel_src.deinit();
    cancel_src.cancel();

    try std.testing.expectError(provider.ProviderError.NetworkError, p.ask(allocator, "hi", &.{}, &w_alloc.writer, &cancel_src.getToken()));
}

test "FakeProvider implements Provider interface correctly" {
    var fake = FakeProvider.init("Hello, world!", null, null);
    const p = fake.providerInterface();

    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    var w_alloc = std.Io.Writer.Allocating.init(allocator);
    defer w_alloc.deinit();

    var cancel_src = try kernel.cancellation.CancellationTokenSource.init(allocator);
    defer cancel_src.deinit();
    const token = cancel_src.getToken();

    try p.ask(allocator, "Say hi", &.{}, &w_alloc.writer, &token);

    const out_items = w_alloc.writer.buffer[0..w_alloc.writer.end];
    try std.testing.expectEqualStrings("Hello, world!", out_items);

    const meta = p.metadata();
    try std.testing.expectEqualStrings("fake", meta.provider_name);
}
