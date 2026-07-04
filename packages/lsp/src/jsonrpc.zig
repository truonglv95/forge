const std = @import("std");

pub const EncodeError = error{OutOfMemory};

pub fn encodeMessage(allocator: std.mem.Allocator, payload: []const u8) EncodeError![]u8 {
    const header = try std.fmt.allocPrint(allocator, "Content-Length: {d}\r\n\r\n", .{payload.len});
    errdefer allocator.free(header);
    const message = try allocator.alloc(u8, header.len + payload.len);
    errdefer allocator.free(message);
    @memcpy(message[0..header.len], header);
    @memcpy(message[header.len..], payload);
    allocator.free(header);
    return message;
}

pub const ReadError = error{
    EndOfStream,
    InvalidHeader,
    InvalidContentLength,
    PayloadTooLarge,
    OutOfMemory,
};

pub fn readMessage(
    io: std.Io,
    file: std.Io.File,
    allocator: std.mem.Allocator,
    max_payload: usize,
) ReadError![]u8 {
    _ = io;
    return readMessageFd(file.handle, allocator, max_payload);
}

pub fn readMessageFd(
    fd: std.posix.fd_t,
    allocator: std.mem.Allocator,
    max_payload: usize,
) ReadError![]u8 {
    var header_buf: [512]u8 = undefined;
    var header_len: usize = 0;
    while (true) {
        if (header_len >= header_buf.len) return error.InvalidHeader;
        try readExact(fd, header_buf[header_len .. header_len + 1]);
        header_len += 1;
        if (header_len >= 4 and std.mem.eql(u8, header_buf[header_len - 4 .. header_len], "\r\n\r\n")) break;
    }

    const header = header_buf[0..header_len];
    const prefix = "Content-Length: ";
    if (!std.mem.startsWith(u8, header, prefix)) return error.InvalidHeader;
    const line_end = std.mem.indexOfScalar(u8, header, '\r') orelse return error.InvalidHeader;
    const len_str = std.mem.trim(u8, header[prefix.len..line_end], " \t");
    const payload_len = std.fmt.parseInt(usize, len_str, 10) catch return error.InvalidContentLength;
    if (payload_len > max_payload) return error.PayloadTooLarge;

    const payload = try allocator.alloc(u8, payload_len);
    errdefer allocator.free(payload);
    try readExact(fd, payload);
    return payload;
}

fn readExact(fd: std.posix.fd_t, buf: []u8) ReadError!void {
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.posix.read(fd, buf[total..]) catch return error.EndOfStream;
        if (n == 0) return error.EndOfStream;
        total += n;
    }
}

test "jsonrpc encodes content-length framing" {
    const allocator = std.testing.allocator;
    const payload = "{\"jsonrpc\":\"2.0\",\"id\":1}";
    const framed = try encodeMessage(allocator, payload);
    defer allocator.free(framed);
    try std.testing.expect(std.mem.startsWith(u8, framed, "Content-Length: "));
    try std.testing.expect(std.mem.endsWith(u8, framed, payload));
}
