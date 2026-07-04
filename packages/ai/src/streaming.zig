const std = @import("std");
const kernel = @import("forge-kernel");
const provider = @import("provider.zig");

pub const Options = struct {
    chunk_size: usize = 32,
};

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
