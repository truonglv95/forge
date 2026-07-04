const std = @import("std");
const kernel = @import("forge-kernel");
const provider = @import("provider.zig");

pub const Options = struct {
    chunk_size: usize = 32,
    on_chunk: ?*const fn (?*anyopaque, []const u8) void = null,
    on_chunk_context: ?*anyopaque = null,
};

/// Invokes `on_chunk` for slices of `content` without writing to a writer.
pub fn emitChunks(
    content: []const u8,
    cancel_token: *const kernel.cancellation.CancellationToken,
    options: Options,
) provider.ProviderError!void {
    if (cancel_token.isCancelled()) return provider.ProviderError.NetworkError;

    var offset: usize = 0;
    while (offset < content.len) {
        if (cancel_token.isCancelled()) return provider.ProviderError.NetworkError;
        const end = @min(offset + options.chunk_size, content.len);
        if (options.on_chunk) |callback| callback(options.on_chunk_context, content[offset..end]);
        offset = end;
    }
}

/// Writes `content` to `writer` in chunks, checking cancellation between chunks.
pub fn writeChunks(
    content: []const u8,
    writer: *std.Io.Writer,
    cancel_token: *const kernel.cancellation.CancellationToken,
    options: Options,
) provider.ProviderError!void {
    if (cancel_token.isCancelled()) return provider.ProviderError.NetworkError;

    var offset: usize = 0;
    while (offset < content.len) {
        if (cancel_token.isCancelled()) return provider.ProviderError.NetworkError;
        const end = @min(offset + options.chunk_size, content.len);
        if (options.on_chunk) |callback| callback(options.on_chunk_context, content[offset..end]);
        writer.writeAll(content[offset..end]) catch return provider.ProviderError.NetworkError;
        offset = end;
    }
}

test "writeChunks streams full payload" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    var cancel_src = try kernel.cancellation.CancellationTokenSource.init(std.testing.allocator);
    defer cancel_src.deinit();

    try writeChunks("hello world", &writer, &cancel_src.getToken(), .{ .chunk_size = 4 });
    try std.testing.expectEqualStrings("hello world", writer.buffered());
}

test "writeChunks stops when cancelled" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    var cancel_src = try kernel.cancellation.CancellationTokenSource.init(std.testing.allocator);
    defer cancel_src.deinit();
    cancel_src.cancel();

    try std.testing.expectError(provider.ProviderError.NetworkError, writeChunks(
        "hello world",
        &writer,
        &cancel_src.getToken(),
        .{},
    ));
}

test "emitChunks handles long thought payloads" {
    var cancel_src = try kernel.cancellation.CancellationTokenSource.init(std.testing.allocator);
    defer cancel_src.deinit();

    var count: usize = 0;
    const Counter = struct {
        n: *usize,
        fn onChunk(ctx: ?*anyopaque, _: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.n.* += 1;
        }
    };
    var counter = Counter{ .n = &count };

    const long_text = "thought " ** 40;
    try emitChunks(long_text, &cancel_src.getToken(), .{
        .on_chunk = Counter.onChunk,
        .on_chunk_context = &counter,
        .chunk_size = 32,
    });
    try std.testing.expect(count > 1);
}
