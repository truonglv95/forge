const std = @import("std");
const provider = @import("provider.zig");
const kernel = @import("forge-kernel");
const streaming = @import("streaming.zig");

pub const FakeProvider = struct {
    response: []const u8,
    simulated_usage: provider.TokenUsage,
    meta: provider.ModelMetadata,

    pub fn init(response: []const u8) FakeProvider {
        return .{
            .response = response,
            .simulated_usage = .{ .prompt_tokens = 10, .completion_tokens = 20, .total_tokens = 30 },
            .meta = .{
                .provider_name = "fake",
                .model_name = "fake-model-1",
                .context_window = 4096,
            },
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

    fn askImpl(ptr: *anyopaque, allocator: std.mem.Allocator, prompt: []const u8, writer: *std.Io.Writer, cancel_token: *const kernel.cancellation.CancellationToken) provider.ProviderError!void {
        _ = allocator;
        _ = prompt;
        const self: *FakeProvider = @ptrCast(@alignCast(ptr));

        if (cancel_token.isCancelled()) return provider.ProviderError.NetworkError;

        try streaming.writeChunks(self.response, writer, cancel_token, .{});
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
    var fake = FakeProvider.init("0123456789012345678901234567890");
    const p = fake.providerInterface();

    var buffer: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    var w_alloc = std.Io.Writer.Allocating.init(allocator);
    defer w_alloc.deinit();

    var cancel_src = try kernel.cancellation.CancellationTokenSource.init(allocator);
    defer cancel_src.deinit();
    cancel_src.cancel();

    try std.testing.expectError(provider.ProviderError.NetworkError, p.ask(allocator, "hi", &w_alloc.writer, &cancel_src.getToken()));
}

test "FakeProvider implements Provider interface correctly" {
    var fake = FakeProvider.init("Hello, world!");
    const p = fake.providerInterface();

    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    var w_alloc = std.Io.Writer.Allocating.init(allocator);
    defer w_alloc.deinit();

    var cancel_src = try kernel.cancellation.CancellationTokenSource.init(allocator);
    defer cancel_src.deinit();
    const token = cancel_src.getToken();

    try p.ask(allocator, "Say hi", &w_alloc.writer, &token);

    const out_items = w_alloc.writer.buffer[0..w_alloc.writer.end];
    try std.testing.expectEqualStrings("Hello, world!", out_items);

    const meta = p.metadata();
    try std.testing.expectEqualStrings("fake", meta.provider_name);
}
